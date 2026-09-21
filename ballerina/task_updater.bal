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
    private Artifact[] artifacts = [];
    // Every transition and artifact, in call order -- what
    // `sendStreamingMessage` replays as the stream body once `onMessage`
    // returns. Recorded regardless of whether this call turns out to be
    // streaming; the unary path simply never reads it. Package-private:
    // an `onMessage` author drives the updater, they don't read its history.
    private StreamResponse[] events = [];

    # Binds an updater to a task. Called by the library, not by agent code.
    #
    # + taskId - The task's server-generated id
    # + contextId - The task's context id
    # + store - The store the task lives in
    isolated function init(string taskId, string contextId, TaskStore store) {
        self.taskId = taskId;
        self.contextId = contextId;
        self.store = store;
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
        lock {
            self.artifacts.push(artifact.clone());
            self.events.push(event.clone());
        }
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

    # Writes the task at the given state, carrying the artifacts accumulated
    # so far, and stamps the status timestamp. Also records a
    # `TaskStatusUpdateEvent` for `sendStreamingMessage` to replay.
    #
    # + state - The state to move to
    # + message - An optional status message
    # + return - An `a2a:Error` if the store rejected the transition
    private isolated function transition(TaskState state, Message? message) returns Error? {
        TaskStatus status = {state, timestamp: time:utcToString(time:utcNow())};
        if message is Message {
            status.message = message;
        }
        Task task = {id: self.taskId, contextId: self.contextId, status};
        TaskStatusUpdateEvent event = {taskId: self.taskId, contextId: self.contextId, status};
        Artifact[] accumulated;
        lock {
            accumulated = self.artifacts.clone();
            self.events.push(event.clone());
        }
        if accumulated.length() > 0 {
            task.artifacts = accumulated;
        }
        return self.store.put(task);
    }

    # The events recorded so far, in call order: one `TaskArtifactUpdateEvent`
    # per `addArtifact` call and one `TaskStatusUpdateEvent` per transition
    # call, interleaved exactly as the `onMessage` author made them.
    #
    # Package-private -- `sendStreamingMessage` reads this after `onMessage`
    # returns to build the stream body; an `onMessage` author has no reason
    # to read their own updater's history back.
    #
    # + return - The recorded events
    isolated function drainEvents() returns StreamResponse[] {
        lock {
            return self.events.clone();
        }
    }
}
