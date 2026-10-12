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


// What a developer implements to serve an A2A agent.
//
// An agent is an `a2a:Service` attached to an `a2a:HttpListener` at a path that
// names the protocol binding (`service /rest on listener`). The service carries
// the agent card and defines the A2A operations it supports as `remote`
// functions; the listener asks the service which ones it defines when the
// service is attached, and answers `UnsupportedOperationError` for the others.
// Every operation can be written by hand or delegated to an
// `a2a:DefaultHandler`, which runs the task lifecycle around an
// `a2a:AgentExecutor`.

# An A2A agent: a service that defines some of the A2A operations.
#
# The type itself requires nothing. Which operations a service supports is
# decided by the `remote` functions it defines, named `onSendMessage`,
# `onSendStreamingMessage`, `onSubscribeToTask`, `onGetTask`, `onListTasks`,
# `onCancelTask`, `onCreateTaskPushNotificationConfig`,
# `onGetTaskPushNotificationConfig`, `onListTaskPushNotificationConfigs`,
# `onDeleteTaskPushNotificationConfig` and `onGetExtendedAgentCard`. Each takes
# the operation's request record, preceded by an `a2a:Context` if the service
# wants to know who is calling; the context is optional. A service must
# define `onSendMessage`; the streaming operations (`onSendStreamingMessage`
# with `onSubscribeToTask`) and the four push-notification operations are each
# all-or-nothing, because the agent card advertises them as one capability.
#
# The agent card comes from `@a2a:ServiceConfig` or from an optional
# `onGetAgentCard` function, not both.
public type Service distinct isolated service object {
};

# Per-service configuration, given with `@a2a:ServiceConfig`.
public type ServiceConfiguration record {|
    # The agent card. `capabilities` and `supportedInterfaces` are derived by
    # the listener from the operations the service defines and the path it is
    # attached at, so pass `capabilities: {}` and `supportedInterfaces: []`.
    #
    # Annotation values must be constants. To build the card from
    # configuration, define `onGetAgentCard` instead and omit the annotation.
    AgentCard agentCard;
|};

# Gives an `a2a:Service` its agent card, on a `service` declaration or a `service class`.
public annotation ServiceConfiguration ServiceConfig on service, class;

# The A2A operations, as the object types a service is checked against when it
# is attached. Package-private: a service is only ever asked whether it defines
# a whole operation with exactly one of these two signatures. Every operation
# takes the request record; the `Context` is optional and, when a service wants
# it, comes first.

type SendMessageOperation isolated service object {
    remote isolated function onSendMessage(Context context, SendMessageRequest request) returns Task|Message|Error;
};

type SendMessagePlainOperation isolated service object {
    remote isolated function onSendMessage(SendMessageRequest request) returns Task|Message|Error;
};

type SendStreamingMessageOperation isolated service object {
    remote isolated function onSendStreamingMessage(Context context, SendMessageRequest request) returns stream<StreamResponse, Error?>|Error;
};

type SendStreamingMessagePlainOperation isolated service object {
    remote isolated function onSendStreamingMessage(SendMessageRequest request) returns stream<StreamResponse, Error?>|Error;
};

type SubscribeToTaskOperation isolated service object {
    remote isolated function onSubscribeToTask(Context context, SubscribeToTaskRequest request) returns stream<StreamResponse, Error?>|Error;
};

type SubscribeToTaskPlainOperation isolated service object {
    remote isolated function onSubscribeToTask(SubscribeToTaskRequest request) returns stream<StreamResponse, Error?>|Error;
};

type GetTaskOperation isolated service object {
    remote isolated function onGetTask(Context context, GetTaskRequest request) returns Task|Error;
};

type GetTaskPlainOperation isolated service object {
    remote isolated function onGetTask(GetTaskRequest request) returns Task|Error;
};

type ListTasksOperation isolated service object {
    remote isolated function onListTasks(Context context, ListTasksRequest request) returns ListTasksResponse|Error;
};

type ListTasksPlainOperation isolated service object {
    remote isolated function onListTasks(ListTasksRequest request) returns ListTasksResponse|Error;
};

type CancelTaskOperation isolated service object {
    remote isolated function onCancelTask(Context context, CancelTaskRequest request) returns Task|Error;
};

type CancelTaskPlainOperation isolated service object {
    remote isolated function onCancelTask(CancelTaskRequest request) returns Task|Error;
};

type CreateTaskPushNotificationConfigOperation isolated service object {
    remote isolated function onCreateTaskPushNotificationConfig(Context context, TaskPushNotificationConfig request) returns TaskPushNotificationConfig|Error;
};

type CreateTaskPushNotificationConfigPlainOperation isolated service object {
    remote isolated function onCreateTaskPushNotificationConfig(TaskPushNotificationConfig request) returns TaskPushNotificationConfig|Error;
};

type GetTaskPushNotificationConfigOperation isolated service object {
    remote isolated function onGetTaskPushNotificationConfig(Context context, GetTaskPushNotificationConfigRequest request) returns TaskPushNotificationConfig|Error;
};

type GetTaskPushNotificationConfigPlainOperation isolated service object {
    remote isolated function onGetTaskPushNotificationConfig(GetTaskPushNotificationConfigRequest request) returns TaskPushNotificationConfig|Error;
};

type ListTaskPushNotificationConfigsOperation isolated service object {
    remote isolated function onListTaskPushNotificationConfigs(Context context, ListTaskPushNotificationConfigsRequest request) returns ListTaskPushNotificationConfigsResponse|Error;
};

type ListTaskPushNotificationConfigsPlainOperation isolated service object {
    remote isolated function onListTaskPushNotificationConfigs(ListTaskPushNotificationConfigsRequest request) returns ListTaskPushNotificationConfigsResponse|Error;
};

type DeleteTaskPushNotificationConfigOperation isolated service object {
    remote isolated function onDeleteTaskPushNotificationConfig(Context context, DeleteTaskPushNotificationConfigRequest request) returns Error?;
};

type DeleteTaskPushNotificationConfigPlainOperation isolated service object {
    remote isolated function onDeleteTaskPushNotificationConfig(DeleteTaskPushNotificationConfigRequest request) returns Error?;
};

type GetExtendedAgentCardOperation isolated service object {
    remote isolated function onGetExtendedAgentCard(Context context, GetExtendedAgentCardRequest request) returns AgentCard|Error;
};

type GetExtendedAgentCardPlainOperation isolated service object {
    remote isolated function onGetExtendedAgentCard(GetExtendedAgentCardRequest request) returns AgentCard|Error;
};

type GetAgentCardOperation isolated service object {
    remote isolated function onGetAgentCard() returns AgentCard|Error;
};

# The inbound message and the context of the request that delivered it.
#
# Passed to `a2a:AgentExecutor.execute`. Holds the message the client sent, the
# effective tenant the request was routed under (if any), the caller's
# resolved owner scope, and any `configuration` the client attached.
public type RequestContext record {|
    # The message the client sent
    Message message;
    # The tenant segment the request arrived under, if any
    string tenant?;
    # The caller's resolved owner scope; unset when no
    # `a2a:TaskOwnerResolver` is configured, or the resolver itself returned
    # `()`. Not an authentication result -- unset is its own scope, shared by
    # every unscoped caller, not a wildcard.
    string owner?;
    # The send configuration the client attached, if any
    SendMessageConfiguration configuration?;
|};
