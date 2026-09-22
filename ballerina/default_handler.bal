// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// Runs the task lifecycle for an `a2a:Service`.
//
// This is the `DefaultRequestHandler` equivalent: the developer's
// `onMessage` is the only business logic, and this turns its result into the
// ten operations a client can call. sendMessage creates a task and drives it
// (or passes a direct Message straight back); getTask/cancelTask/listTasks
// read and mutate through the `TaskStore`.

import ballerina/time;
import ballerina/uuid;

isolated class DefaultHandler {
    private final Service agentService;
    private final TaskStore store;
    // Push-notification config storage: registered, never delivered to (see
    // decision in the server plan -- outbound webhook delivery is a later
    // release). Keyed by taskId, then by the config's own server-generated
    // id. In-memory only, like InMemoryTaskStore; not pluggable in this
    // release since there is no delivery mechanism yet for a durable store
    // to matter to.
    private map<map<TaskPushNotificationConfig>> pushConfigs = {};
    // The richer card `getExtendedAgentCard` returns, if the developer
    // configured one. `()` means the operation always answers
    // ExtendedAgentCardNotConfiguredError -- deriveServedCard already
    // reflects this in capabilities.extendedAgentCard.
    private final (AgentCard & readonly)? extendedCard;
    private final PushNotificationSender pushSender;
    private final TaskExecutionRegistry registry;

    isolated function init(Service agentService, TaskStore store, (AgentCard & readonly)? extendedCard,
            PushNotificationSender pushSender, TaskExecutionRegistry registry) {
        self.agentService = agentService;
        self.store = store;
        self.extendedCard = extendedCard;
        self.pushSender = pushSender;
        self.registry = registry;
    }

    # Handles sendMessage: create a task, run the developer's `onMessage`
    # against it, and return the finished task — or the direct `Message` the
    # agent returned instead.
    #
    # A client-supplied `contextId` is honoured; otherwise one is generated and
    # carried on the task, as section 3.4.1 requires.
    #
    # + request - The decoded send request
    # + tenant - The tenant the request was routed under, or `()`
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The finished Task or a direct Message, or an error
    isolated function sendMessage(SendMessageRequest request, string? tenant, string? owner) returns Task|Message|Error {
        check validateOutboundMessage(request.message);

        string contextId = request.message?.contextId ?: uuid:createType4AsString();
        string taskId = uuid:createType4AsString();

        // Seed the task as submitted before handing control to the agent, so a
        // concurrent getTask sees it exists.
        Task seed = {
            id: taskId,
            contextId,
            status: {state: TASK_STATE_SUBMITTED, timestamp: time:utcToString(time:utcNow())}
        };
        check self.store.put(seed, owner);

        // A client cannot name a taskId that doesn't exist yet, so the
        // spec's own registration channel for this case is inline on the
        // send request itself -- "leave unset in a sendMessage request"
        // doc-commented on TaskPushNotificationConfig.taskId. The task now
        // exists (just seeded above), so registering it here needs no
        // existence check, unlike createTaskPushNotificationConfig's own.
        TaskPushNotificationConfig? inlineConfig = request?.configuration?.taskPushNotificationConfig;
        if inlineConfig is TaskPushNotificationConfig {
            TaskPushNotificationConfig _ = self.registerPushConfig(taskId, inlineConfig);
        }

        EventBroadcaster? broadcaster = self.registry.acquire(taskId);
        if broadcaster is () {
            // Unreachable with today's always-fresh, random taskId; becomes
            // real once a future commit lets a client continue an existing
            // task -- a second concurrent message to one already being
            // driven is a clean rejection, not two TaskUpdaters racing.
            string msg = string `task ${taskId} is already being processed`;
            return error UnsupportedOperationError(msg, message = msg, code = -32004);
        }

        final RequestContext context = {
            message: request.message,
            tenant,
            owner,
            configuration: request?.configuration
        };
        final TaskUpdater updater = new (taskId, contextId, self.store, owner, seed, broadcaster);

        future<Task|Message|Error> f = start self.driveTask(taskId, owner, context.clone(), updater);
        Task|Message result = check self.awaitDriveTask(f);
        self.registry.release(taskId, true);
        if result is Task {
            self.notifyPushConfigs(taskId, result);
        }
        return result;
    }

    # Runs `onMessage` for one task, detached from the request that started
    # it -- so a slow agent never blocks the strand a separate
    # `subscribeToTask` call needs to attach to the same task's live events.
    #
    # A panic in agent code is trapped rather than left to propagate: with
    # `returnImmediately: true`, or once a subscriber is watching live,
    # there is no synchronous caller left to receive it if it escapes.
    # Both a trapped panic and `onMessage` returning an `Error` transition
    # the task to `TASK_STATE_FAILED` via the same `updater-&gt;failed(...)`
    # an agent itself would call, and forward that Error to whoever
    # eventually reads this call's result -- the only way a live or later
    # observer learns anything went wrong once execution is no longer
    # synchronous.
    #
    # + taskId - The task being driven
    # + owner - The caller's resolved owner scope, or `()`
    # + context - The message and request context to hand to `onMessage`
    # + updater - The bound updater; already carries the broadcaster and base
    # + return - The direct `Message`, the finished `Task`, or an `Error`
    private isolated function driveTask(string taskId, string? owner, RequestContext context, TaskUpdater updater)
            returns Task|Message|Error {
        Message|Error?|error direct = trap self.agentService->onMessage(context, updater);

        if direct is Message {
            // A direct reply: the seeded task is not part of the
            // conversation, so drop it and hand the Message back.
            check self.store.remove(taskId, owner);
            return direct;
        }

        Error? failure = ();
        if direct is Error {
            failure = direct;
        } else if direct is error {
            failure = wrapTransportError(direct);
        } else if !updater.touched() {
            failure = invalidAgentResponse(
                    string `onMessage returned without driving the task to a state for ${taskId}`);
        }
        if failure is Error {
            Message failMessage = {
                messageId: uuid:createType4AsString(),
                role: ROLE_AGENT,
                parts: [{text: failure.message()}]
            };
            // Best-effort: if even marking the task FAILED fails (e.g. a
            // concurrent cancelTask already moved it to a different
            // terminal state), the original failure is still what's
            // reported -- there is nothing more useful to do with a
            // second error here.
            Error? failTransitionResult = updater->failed(failMessage);
            if failTransitionResult is Error {
                // Deliberately not propagated; see comment above.
            }
            return failure;
        }

        return updater.currentTask();
    }

    # Normalizes `wait` on a `future&lt;Task|Message|Error&gt;`, which is
    # statically `Task|Message|Error|error` -- the trailing bare `error` arm
    # is the panic channel `wait` itself can surface (distinct from, and in
    # addition to, `driveTask`'s own internal `trap`), wrapped the same way
    # every other unnamed transport failure is.
    #
    # + f - The future to await
    # + return - The driven result, or a wrapped Error
    private isolated function awaitDriveTask(future<Task|Message|Error> f) returns Task|Message|Error {
        Task|Message|Error|error waited = wait f;
        if waited is Task {
            return waited;
        } else if waited is Message {
            return waited;
        } else if waited is Error {
            return waited;
        }
        // `waited` is a plain `error` here -- the panic channel `wait`
        // itself can surface. Every A2A spec type (Task, Message) is an
        // open record, so the compiler cannot narrow it out of the type
        // by elimination the way it would a closed type; the explicit
        // cast is what the module's own README documents for exactly
        // this situation.
        return wrapTransportError(<error>waited);
    }

    # Handles sendStreamingMessage: like `sendMessage`, but returns every
    # event `onMessage` produced, in generation order, for the caller to
    # frame as SSE.
    #
    # `onMessage` runs to completion before this returns -- there is no
    # concurrent task execution in this release, so the stream this produces
    # is a replay of what already happened, not a live feed. What the client
    # sees on the wire is identical either way: per specification 3.1.2, the
    # stream begins with the Task object (here, its just-seeded SUBMITTED
    # state) followed by the status/artifact events `onMessage` drove the
    # task through, or -- for a direct reply -- exactly one Message event.
    #
    # + request - The decoded send request
    # + tenant - The tenant the request was routed under, or `()`
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The events to stream, in order, or an error
    isolated function sendStreamingMessage(SendMessageRequest request, string? tenant, string? owner)
            returns StreamResponse[]|Error {
        check validateOutboundMessage(request.message);

        string contextId = request.message?.contextId ?: uuid:createType4AsString();
        string taskId = uuid:createType4AsString();

        Task seed = {
            id: taskId,
            contextId,
            status: {state: TASK_STATE_SUBMITTED, timestamp: time:utcToString(time:utcNow())}
        };
        check self.store.put(seed, owner);

        // See sendMessage's identical block: the task now exists, so an
        // inline config can be registered without an existence check.
        TaskPushNotificationConfig? inlineConfig = request?.configuration?.taskPushNotificationConfig;
        if inlineConfig is TaskPushNotificationConfig {
            TaskPushNotificationConfig _ = self.registerPushConfig(taskId, inlineConfig);
        }

        EventBroadcaster? broadcaster = self.registry.acquire(taskId);
        if broadcaster is () {
            // See sendMessage's identical branch.
            string msg = string `task ${taskId} is already being processed`;
            return error UnsupportedOperationError(msg, message = msg, code = -32004);
        }

        final RequestContext context = {
            message: request.message,
            tenant,
            owner,
            configuration: request?.configuration
        };
        final TaskUpdater updater = new (taskId, contextId, self.store, owner, seed, broadcaster);

        // TODO(live streaming): the array built below becomes a live read
        // from the broadcaster instead -- see the plan. Detached execution
        // itself, and driveTask's own untouched/error handling, already
        // apply here exactly as they do in sendMessage.
        future<Task|Message|Error> f = start self.driveTask(taskId, owner, context.clone(), updater);
        Task|Message result = check self.awaitDriveTask(f);
        self.registry.release(taskId, true);

        if result is Message {
            return [result];
        } else if result is Task {
            StreamResponse[] events = [seed];
            events.push(...updater.drainEvents());
            self.notifyPushConfigs(taskId, result);
            return events;
        }
        return invalidAgentResponse("driveTask returned neither a Task nor a Message");
    }

    # Handles subscribeToTask: the task's current state, as a one-event
    # stream.
    #
    # Per specification 3.1.6, the first event on a genuine subscribe is the
    # task's current state. This release has no live cross-request following
    # of a task still being driven by another in-flight call -- `onMessage`
    # always finishes inside the request that started it (see
    # `sendStreamingMessage`), so by the time a separate subscribeToTask
    # request can reach the server the task is already in the state that
    # request's own `sendMessage`/`sendStreamingMessage` call left it in, and
    # that snapshot is all there ever will be to see. The stream is therefore
    # always exactly one event, closing immediately after -- correct for a
    # task already terminal, and a documented scope boundary (not a bug) for
    # one still notionally in progress on another connection.
    #
    # + request - The task identifier
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The one-event stream, or a TaskNotFoundError
    isolated function subscribeToTask(SubscribeToTaskRequest request, string? owner) returns StreamResponse[]|Error {
        Task? task = check self.store.get(request.id, owner);
        if task is () {
            return taskNotFound(request.id);
        }
        return [task];
    }

    # Handles getTask.
    #
    # + request - The task identifier and optional history length
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The task, or a TaskNotFoundError
    isolated function getTask(GetTaskRequest request, string? owner) returns Task|Error {
        Task? task = check self.store.get(request.id, owner);
        if task is () {
            return taskNotFound(request.id);
        }
        int? historyLength = request?.historyLength;
        if historyLength is int {
            Message[]? history = task?.history;
            if history is Message[] && history.length() > historyLength {
                task.history = historyLength <= 0 ? []
                    : history.slice(history.length() - historyLength);
            }
        }
        return task;
    }

    # Handles cancelTask.
    #
    # A task already in a terminal state cannot be canceled (section 3.1.1), so
    # that is a TaskNotCancelableError.
    #
    # + request - The task identifier
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The canceled task, or an error
    isolated function cancelTask(CancelTaskRequest request, string? owner) returns Task|Error {
        Task? task = check self.store.get(request.id, owner);
        if task is () {
            return taskNotFound(request.id);
        }
        if isTerminalState(task.status.state) {
            string msg = string `task ${request.id} is in terminal state ${task.status.state} `
                + string `and cannot be canceled`;
            return error TaskNotCancelableError(msg, message = msg, code = -32002);
        }
        task.status = {state: TASK_STATE_CANCELED, timestamp: time:utcToString(time:utcNow())};
        check self.store.put(task, owner);
        self.notifyPushConfigs(request.id, task);
        return task;
    }

    # Handles listTasks.
    #
    # + request - The filter and pagination parameters
    # + owner - The caller's resolved owner scope, or `()`
    # + return - A page of tasks
    isolated function listTasks(ListTasksRequest request, string? owner) returns ListTasksResponse|Error {
        return self.store.list(request, owner);
    }

    # Handles createTaskPushNotificationConfig: registers a webhook config
    # against an existing task, assigning it a server-generated id.
    #
    # + request - The config to register; `taskId` must be set and name an
    #             existing task
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The stored config, with `id` filled in, or a
    #            TaskNotFoundError if `taskId` names no task visible to
    #            `owner`
    isolated function createTaskPushNotificationConfig(TaskPushNotificationConfig request, string? owner)
            returns TaskPushNotificationConfig|Error {
        string? taskId = request?.taskId;
        if taskId is () {
            string msg = "TaskPushNotificationConfig.taskId is required to register a config";
            return invalidAgentResponse(msg);
        }
        Task? task = check self.store.get(taskId, owner);
        if task is () {
            return taskNotFound(taskId);
        }
        return self.registerPushConfig(taskId, request);
    }

    # Registers a config against a task already known to exist, assigning
    # it a server-generated id. Shared by `createTaskPushNotificationConfig`
    # (after its own taskId-existence check) and `sendMessage`/
    # `sendStreamingMessage`'s inline `SendMessageConfiguration.taskPushNotificationConfig`
    # registration -- the seed `store.put` immediately above each call site
    # already establishes the task exists, so neither needs the check again.
    #
    # + taskId - The task's id
    # + config - The config to register
    # + return - The stored config, with `taskId` and `id` filled in
    isolated function registerPushConfig(string taskId, TaskPushNotificationConfig config)
            returns TaskPushNotificationConfig {
        TaskPushNotificationConfig stored = config.clone();
        stored.taskId = taskId;
        stored.id = uuid:createType4AsString();
        lock {
            map<TaskPushNotificationConfig> forTask = self.pushConfigs[taskId] ?: {};
            forTask[<string>stored.id] = stored.clone();
            self.pushConfigs[taskId] = forTask;
        }
        return stored;
    }

    # Handles getTaskPushNotificationConfig.
    #
    # A task not visible to `owner` is treated identically to an unknown
    # config on a known task -- both are `TaskNotFoundError`, so a caller
    # cannot distinguish "not your task" from "no such config" by response
    # shape, per specification section 13.1.
    #
    # + request - The parent task id and the config's own id
    # + owner - The caller's resolved owner scope, or `()`
    # + return - The config, or a TaskNotFoundError if either id is unknown,
    #            or the task is not visible to `owner`
    isolated function getTaskPushNotificationConfig(GetTaskPushNotificationConfigRequest request, string? owner)
            returns TaskPushNotificationConfig|Error {
        Task? task = check self.store.get(request.taskId, owner);
        if task is () {
            return taskPushNotificationConfigNotFound(request.taskId, request.id);
        }
        lock {
            map<TaskPushNotificationConfig>? forTask = self.pushConfigs[request.taskId];
            TaskPushNotificationConfig? config = forTask is map<TaskPushNotificationConfig>
                ? forTask[request.id] : ();
            if config is () {
                return taskPushNotificationConfigNotFound(request.taskId, request.id);
            }
            return config.clone();
        }
    }

    # Handles listTaskPushNotificationConfigs. No pagination cursor is
    # actually needed at realistic per-task config counts, so every result
    # is returned as one page.
    #
    # A task not visible to `owner` returns an empty page, matching this
    # operation's existing behavior for a genuinely unknown task -- neither
    # case is an error, and the two must stay indistinguishable per
    # specification section 13.1.
    #
    # + request - The parent task id
    # + owner - The caller's resolved owner scope, or `()`
    # + return - Every config registered for the task, or an empty page if
    #            the task is not visible to `owner`
    isolated function listTaskPushNotificationConfigs(ListTaskPushNotificationConfigsRequest request, string? owner)
            returns ListTaskPushNotificationConfigsResponse|Error {
        Task? task = check self.store.get(request.taskId, owner);
        if task is () {
            return {configs: [], nextPageToken: ""};
        }
        TaskPushNotificationConfig[] configs;
        lock {
            configs = (self.pushConfigs[request.taskId] ?: {}).toArray().clone();
        }
        return {configs, nextPageToken: ""};
    }

    # Handles deleteTaskPushNotificationConfig. Idempotent per specification
    # section 3.1.10: deleting an unknown config is not an error -- and, for
    # the same section 13.1 reasoning as `listTaskPushNotificationConfigs`,
    # neither is deleting on a task that exists but is not visible to
    # `owner`; both are a silent no-op, never distinguished from each other.
    #
    # + request - The parent task id and the config's own id
    # + owner - The caller's resolved owner scope, or `()`
    # + return - Nil; always succeeds
    isolated function deleteTaskPushNotificationConfig(DeleteTaskPushNotificationConfigRequest request,
            string? owner) returns Error? {
        Task? task = check self.store.get(request.taskId, owner);
        if task is () {
            return;
        }
        lock {
            map<TaskPushNotificationConfig>? forTask = self.pushConfigs[request.taskId];
            if forTask is map<TaskPushNotificationConfig> {
                _ = forTask.removeIfHasKey(request.id);
            }
        }
    }

    # Notifies every push-notification config registered for a task that it
    # reached a new state, fire-and-forget.
    #
    # Unconditional on the state reached -- not filtered to terminal states
    # -- matching every reference SDK read this session; a deliberate
    # choice, not an oversight. Unscoped by owner on purpose: dispatch fires
    # every config registered for the task regardless of which caller
    # registered it, the same way `a2a-java`'s dispatch read path is
    # separate from its owner-scoped one. The task itself already passed
    # its own owner check before this is ever called, so this is not a
    # visibility leak -- it is delivery, which was never owner-scoped to
    # begin with.
    #
    # + taskId - The task that changed
    # + task - Its state at the moment of this call
    isolated function notifyPushConfigs(string taskId, Task task) {
        map<TaskPushNotificationConfig> configs;
        lock {
            configs = (self.pushConfigs[taskId] ?: {}).clone();
        }
        foreach TaskPushNotificationConfig config in configs {
            Error? deliveryResult = self.pushSender.send(config, task);
            if deliveryResult is Error {
                // Fire-and-forget: a delivery failure must not fail the
                // operation that triggered it, so it is deliberately
                // dropped here rather than propagated.
            }
        }
    }

    # Handles getExtendedAgentCard.
    #
    # + return - The configured extended card, or
    #            ExtendedAgentCardNotConfiguredError if none was set up
    isolated function getExtendedAgentCard() returns AgentCard|Error {
        if self.extendedCard is AgentCard {
            return <AgentCard>self.extendedCard;
        }
        string msg = "no extended AgentCard is configured for this agent";
        return error ExtendedAgentCardNotConfiguredError(msg, message = msg, code = -32007);
    }
}

# Builds a TaskNotFoundError for an unknown task id.
#
# + id - The id that was not found
# + return - The typed error
isolated function taskNotFound(string id) returns TaskNotFoundError {
    string msg = string `no task with id ${id}`;
    return error TaskNotFoundError(msg, message = msg, code = -32001);
}

# Builds a TaskNotFoundError for an unknown push-notification config.
#
# The error taxonomy has no dedicated "config not found" type -- this is a
# task-scoped resource, same as the task itself, so TaskNotFoundError is the
# closest honest fit; the message says specifically what wasn't found.
#
# + taskId - The parent task id
# + id - The config id that was not found
# + return - The typed error
isolated function taskPushNotificationConfigNotFound(string taskId, string id) returns TaskNotFoundError {
    string msg = string `no push notification config with id ${id} for task ${taskId}`;
    return error TaskNotFoundError(msg, message = msg, code = -32001);
}
