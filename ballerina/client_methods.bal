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

// The operation set every A2A client type implements, regardless of which
// transport binding it speaks.

# The client-side A2A operation set (specification section 9.4), declared
# once here and mixed into every client type in this module via `*ClientMethods;`,
# instead of repeating all eleven signatures four times.
#
# `JsonRpcClient`, `RestClient`, and `GrpcClient` each implement it over
# exactly one transport binding. `Client` implements it too, by resolving
# an Agent Card, picking the binding the card prefers, and delegating.
#
# **Not public, deliberately.** Ballerina object types are structurally
# typed: a caller who wants to write binding-agnostic code across two or
# more of this library's client types does not need this library to
# export a named interface for that — they can declare their own local
# object type covering whichever methods they actually use, and any of
# `Client`/`RestClient`/`JsonRpcClient`/`GrpcClient` satisfies it
# automatically, with no dependency on this type. Confirmed directly: a
# scratch package assigning a real `RestClient` to a locally-declared
# type with a matching `getTask` signature compiles with no reference to
# this type at all. Exporting it would only have saved a caller from
# writing that one-time local declaration themselves — not enabled
# anything otherwise impossible — and no real caller (internal test
# aside) has needed it. Revisit only if that changes: adding `public`
# back later is additive, not breaking; the reverse would not be.
#
# **Error contract: every method below returns a narrowed Error, never
# a bare `error`.** The `+ return` doc on each names the specific
# Error subtype(s) (errors.bal) a protocol-level failure produces (the
# agent rejected the request, or a capability check short-circuited it
# client-side) — but a caller that only checks for those named subtypes
# still sees every other failure as an Error too. A raw transport or
# decode error — a connection failure, a malformed response body, an
# unexpected shape `cloneWithType` rejects — comes from
# `ballerina/http`/`ballerina/grpc`/`ballerina/mime`, which return plain
# `error`, not this library's own type; each binding's implementation
# wraps that at the boundary via `wrapTransportError` (errors.bal) into
# an InternalError before it ever reaches a caller, the same way
# `fetchAgentCardBody`/`resolveAgentCard` (client.bal) already do. A
# caller that needs to tell a protocol failure apart from a transport
# failure still pattern-matches on the concrete type
# (`result is a2a:TaskNotFoundError`, etc.) — only the fallback case
# changed, from an untyped `error` to `a2a:InternalError`.
type ClientMethods isolated client object {

    # Sends a message to the remote agent.
    #
    # + request - The message and its send options
    # + return - A Task or a Message on success, or an error on failure
    isolated remote function sendMessage(SendMessageRequest request) returns Task|Message|Error;

    # Sends a message and receives updates as they happen.
    #
    # + request - The message and its send options
    # + return - A stream of StreamResponse values, or an error
    isolated remote function sendStreamingMessage(SendMessageRequest request)
        returns stream<StreamResponse, error?>|Error;

    # Retrieves the current state of a task.
    #
    # + request - The task identifier, and optionally how much history to include
    # + return - The current Task, or an error if unknown
    isolated remote function getTask(GetTaskRequest request) returns Task|Error;

    # Requests cancellation of an in-progress task.
    #
    # + request - The task identifier, and any additional context for the agent
    # + return - The updated Task, or an error
    isolated remote function cancelTask(CancelTaskRequest request) returns Task|Error;

    # Opens a stream on an existing task.
    #
    # + request - The task identifier
    # + return - A stream of StreamResponse values, or an error
    isolated remote function subscribeToTask(SubscribeToTaskRequest request)
        returns stream<StreamResponse, error?>|Error;

    # Lists tasks matching an optional filter, with cursor-based pagination.
    #
    # + request - Optional filter and pagination parameters; every field is
    #             optional, so this defaults to listing with the server's
    #             own defaults
    # + return - A page of matching tasks, or an error
    isolated remote function listTasks(ListTasksRequest request = {}) returns ListTasksResponse|Error;

    # Registers a webhook to receive updates for a task.
    #
    # Takes the configuration itself rather than a request wrapper: the
    # specification's CreateTaskPushNotificationConfig RPC is the one
    # operation with no dedicated request message.
    #
    # + request - The webhook configuration; its taskId identifies the task
    # + return - The created config as the server persisted it, or an error
    isolated remote function createTaskPushNotificationConfig(TaskPushNotificationConfig request)
        returns TaskPushNotificationConfig|Error;

    # Retrieves a previously registered push-notification webhook config.
    #
    # + request - The parent task id and the config's own id
    # + return - The config, or an error
    isolated remote function getTaskPushNotificationConfig(GetTaskPushNotificationConfigRequest request)
        returns TaskPushNotificationConfig|Error;

    # Lists all push-notification webhook configs registered for a task.
    #
    # + request - The parent task id, and optional pagination parameters
    # + return - A page of matching configs, or an error
    isolated remote function listTaskPushNotificationConfigs(ListTaskPushNotificationConfigsRequest request)
        returns ListTaskPushNotificationConfigsResponse|Error;

    # Deletes a push-notification webhook config. Idempotent per
    # specification section 3.1.10.
    #
    # + request - The parent task id and the config's own id
    # + return - nil on success, or an error
    isolated remote function deleteTaskPushNotificationConfig(DeleteTaskPushNotificationConfigRequest request)
        returns Error?;

    # Retrieves the agent's extended AgentCard.
    #
    # + request - Optional routing parameters; every field is optional, so
    #             this defaults to an empty request
    # + return - The extended AgentCard, or an error
    isolated remote function getExtendedAgentCard(GetExtendedAgentCardRequest request = {})
        returns AgentCard|Error;
};
