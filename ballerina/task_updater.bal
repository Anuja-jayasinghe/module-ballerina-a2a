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

import ballerina/time;
import ballerina/uuid;

# Drives one task through its lifecycle from inside `a2a:Service.onMessage`.
#
# The library hands the developer a `TaskUpdater` already bound to a freshly
# created task. Each method advances the task's state and persists it through
# the store, so a client polling `getTask` sees the progression. `addArtifact`
# accumulates output; the terminal calls — `complete`, `failed`, `reject` —
# and the interrupted calls — `requireInput`, `requireAuth` — set the final or
# paused state.
#
# The task id and context id are read-only, so the developer can echo them
# back to the client without reaching into the store.
public isolated client class TaskUpdater {
    private final string taskId;
    private final string contextId;
    private final TaskStore store;
    private final string? owner;
    private final EventBroadcaster broadcaster;
    private Artifact[] artifacts = [];
    // The task's last-written state -- empty artifacts/history for a new
    // task, or a continuation's already-accumulated state. Updated after
    // every successful write, so the next one carries the same
    // history/metadata forward instead of silently dropping them, and so
    // the final value is available without a separate store read.
    private Task base;
    // Whether onMessage has driven the task through this updater at least
    // once. `false` when onMessage returns a direct Message without
    // touching the updater -- exactly what distinguishes "one Message
    // event, nothing else" from "the agent never drove this task at all."
    private boolean touchedFlag = false;
    // Whether the task's current (pre-transition) state has been broadcast
    // yet. Emitted lazily, on the agent's first real touch of the updater
    // -- not eagerly at construction -- so a direct-Message reply's stream
    // is exactly the one Message event specification section 3.1.2
    // requires, never a spurious Task first.
    private boolean seedEmitted = false;
    // Every transition and artifact, in call order -- what
    // `sendStreamingMessage` replays as the stream body once `onMessage`
    // returns. Recorded regardless of whether this call turns out to be
    // streaming; the unary path simply never reads it. Package-private:
    // an `onMessage` author drives the updater, they don't read its history.
    // TODO(live streaming): retired once sendStreamingMessage reads live
    // from the broadcaster instead of draining this after the fact.
    private StreamResponse[] events = [];

    # Binds an updater to a task. Called by the library, not by agent code.
    #
    # + taskId - The task's server-generated id
    # + contextId - The task's context id
    # + store - The store the task lives in
    # + owner - The resolved owner scope every write is stamped and checked
    #           against, or `()`
    # + base - The task's current state -- empty artifacts/history for a new
    #          task, or a continuation's already-accumulated state
    # + broadcaster - Where every transition and artifact is pushed live, for
    #                 `sendStreamingMessage`/`subscribeToTask` subscribers
    isolated function init(string taskId, string contextId, TaskStore store, string? owner, Task base,
            EventBroadcaster broadcaster) {
        self.taskId = taskId;
        self.contextId = contextId;
        self.store = store;
        self.owner = owner;
        self.base = base.clone();
        // A continuation's already-accumulated artifacts compose with
        // whatever this invocation adds, rather than being silently
        // replaced by them.
        self.artifacts = base?.artifacts is Artifact[] ? (<Artifact[]>base?.artifacts).clone() : [];
        self.broadcaster = broadcaster;
    }

    # The task's server-generated id.
    #
    # + return - The id
    public isolated function getTaskId() returns string => self.taskId;

    # The task's context id.
    #
    # + return - The context id
    public isolated function getContextId() returns string => self.contextId;

    # Moves the task to `TASK_STATE_WORKING`.
    #
    # + message - An optional status message to attach
    # + return - An `a2a:Error` if the update could not be stored
    isolated remote function working(Message? message = ()) returns Error? {
        return self.transition(TASK_STATE_WORKING, message);
    }

    # Appends an artifact to the task's output.
    #
    # + parts - The parts of the artifact; at least one is required
    # + name - An optional human-readable label
    # + return - An `a2a:Error` if `parts` is empty
    isolated remote function addArtifact(Part[] parts, string? name = ()) returns Error? {
        check requireNonEmpty("Artifact.parts", parts.length(), false);
        Artifact artifact = {artifactId: uuid:createType4AsString(), parts};
        if name is string {
            artifact.name = name;
        }
        // Delivered whole, not chunked -- this API takes the complete parts
        // array in one call, so every artifact is its own first-and-last
        // chunk. A future incremental-append API would set append/lastChunk
        // per call instead.
        TaskArtifactUpdateEvent event = {
            taskId: self.taskId,
            contextId: self.contextId,
            artifact: artifact.clone(),
            append: false,
            lastChunk: true
        };
        Task? seed = ();
        lock {
            if !self.seedEmitted {
                self.seedEmitted = true;
                seed = self.base.clone();
            }
            self.touchedFlag = true;
            self.artifacts.push(artifact.clone());
            self.events.push(event.clone());
        }
        if seed is Task {
            self.broadcaster.push(seed);
        }
        self.broadcaster.push(event);
        return;
    }

    # Completes the task successfully: `TASK_STATE_COMPLETED`.
    #
    # + message - An optional final status message
    # + return - An `a2a:Error` if the update could not be stored
    isolated remote function complete(Message? message = ()) returns Error? {
        return self.transition(TASK_STATE_COMPLETED, message);
    }

    # Fails the task: `TASK_STATE_FAILED`.
    #
    # + message - An optional status message describing the failure
    # + return - An `a2a:Error` if the update could not be stored
    isolated remote function failed(Message? message = ()) returns Error? {
        return self.transition(TASK_STATE_FAILED, message);
    }

    # Rejects the task: `TASK_STATE_REJECTED`. The agent declined to perform it.
    #
    # + message - An optional status message describing the rejection
    # + return - An `a2a:Error` if the update could not be stored
    isolated remote function reject(Message? message = ()) returns Error? {
        return self.transition(TASK_STATE_REJECTED, message);
    }

    # Pauses the task awaiting client input: `TASK_STATE_INPUT_REQUIRED`.
    #
    # + message - The prompt describing what input is needed
    # + return - An `a2a:Error` if the update could not be stored
    isolated remote function requireInput(Message message) returns Error? {
        return self.transition(TASK_STATE_INPUT_REQUIRED, message);
    }

    # Pauses the task awaiting authorization: `TASK_STATE_AUTH_REQUIRED`.
    #
    # + message - The prompt describing what authorization is needed
    # + return - An `a2a:Error` if the update could not be stored
    isolated remote function requireAuth(Message message) returns Error? {
        return self.transition(TASK_STATE_AUTH_REQUIRED, message);
    }

    # Writes the task at the given state, carrying the artifacts
    # accumulated so far and the task's `history`/`metadata` forward, and
    # stamps the status timestamp. Broadcasts the resulting
    # `TaskStatusUpdateEvent` live to `sendStreamingMessage`/
    # `subscribeToTask` subscribers -- only once the store write actually
    # succeeds, never before: broadcasting first could hand subscribers a
    # phantom event for a transition a concurrent `cancelTask` then
    # rejects.
    #
    # + state - The state to move to
    # + message - An optional status message
    # + return - An `a2a:Error` if the store rejected the transition
    private isolated function transition(TaskState state, Message? message) returns Error? {
        TaskStatus status = {state, timestamp: time:utcToString(time:utcNow())};
        if message is Message {
            status.message = message;
        }
        Task task;
        Artifact[] accumulated;
        lock {
            task = self.base.clone();
            accumulated = self.artifacts.clone();
        }
        task.status = status;
        if accumulated.length() > 0 {
            task.artifacts = accumulated;
        }
        Error? putResult = self.store.put(task, self.owner);
        if putResult is Error {
            return putResult;
        }

        TaskStatusUpdateEvent event = {taskId: self.taskId, contextId: self.contextId, status};
        Task? seed = ();
        lock {
            if !self.seedEmitted {
                self.seedEmitted = true;
                seed = self.base.clone();
            }
            self.touchedFlag = true;
            self.base = task.clone();
            self.events.push(event.clone());
        }
        if seed is Task {
            self.broadcaster.push(seed);
        }
        self.broadcaster.push(event);
    }

    # Whether `onMessage` has driven this task through the updater at
    # least once -- `false` only when `onMessage` returns a direct
    # `Message` without ever calling a remote method on this updater.
    #
    # Package-private -- `sendMessage`/`sendStreamingMessage` use this to
    # tell "the agent never drove the task" apart from "the agent drove it
    # to a state that happens to look unfinished."
    #
    # + return - Whether the updater was used
    isolated function touched() returns boolean {
        lock {
            return self.touchedFlag;
        }
    }

    # The task's current state -- the last value written via `transition`,
    # or the original `base` if `onMessage` never touched the updater.
    #
    # Package-private -- read after `onMessage` returns, when a caller
    # needs the final task without a separate store read (e.g. after a
    # direct `Message` reply, when the store copy was already removed).
    #
    # + return - The current task state
    isolated function currentTask() returns Task {
        lock {
            return self.base.clone();
        }
    }

    # The events recorded so far, in call order: one `TaskArtifactUpdateEvent`
    # per `addArtifact` call and one `TaskStatusUpdateEvent` per transition
    # call, interleaved exactly as the `onMessage` author made them.
    #
    # Package-private -- `sendStreamingMessage` reads this after `onMessage`
    # returns to build the stream body; an `onMessage` author has no reason
    # to read their own updater's history back.
    #
    # TODO(live streaming): retired once `sendStreamingMessage` reads live
    # from the broadcaster instead of draining this after the fact.
    #
    # + return - The recorded events
    isolated function drainEvents() returns StreamResponse[] {
        lock {
            return self.events.clone();
        }
    }
}
