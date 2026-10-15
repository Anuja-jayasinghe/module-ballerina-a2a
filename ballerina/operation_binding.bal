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


// Which of the A2A operations a service defines, and a way to call them.
//
// A service defines an operation by declaring the resource function that
// operation is served at. The listener's own dispatcher owns the wire, so it
// reads the service's resources once when the service is attached and calls
// them through the native invoker; an operation the service does not define
// answers `UnsupportedOperationError` (or `PushNotificationNotSupportedError`
// for the push-notification operations), which is what the specification asks
// of a capability the agent does not offer.
//
// The names below, such as `onGetTask`, are this package's internal names for
// the operations; the service itself declares resources, not functions with
// these names.

# Where each operation lives in a service: the resource's accessor and its
# path, with `*` for a path parameter.
type ResourceRoute record {|
    # The resource's accessor, lower case
    string accessor;
    # The resource's path, with `*` for a path parameter
    string path;
|};

final readonly & map<ResourceRoute> OPERATION_ROUTES = {
    "onSendMessage": {accessor: "post", path: "message:send"},
    "onSendStreamingMessage": {accessor: "post", path: "message:stream"},
    "onSubscribeToTask": {accessor: "get", path: "tasks/*/subscribe"},
    "onGetTask": {accessor: "get", path: "tasks/*"},
    "onListTasks": {accessor: "get", path: "tasks"},
    "onCancelTask": {accessor: "post", path: "tasks/*/cancel"},
    "onCreateTaskPushNotificationConfig": {accessor: "post", path: "tasks/*/pushNotificationConfigs"},
    "onGetTaskPushNotificationConfig": {accessor: "get", path: "tasks/*/pushNotificationConfigs/*"},
    "onListTaskPushNotificationConfigs": {accessor: "get", path: "tasks/*/pushNotificationConfigs"},
    "onDeleteTaskPushNotificationConfig": {accessor: "delete", path: "tasks/*/pushNotificationConfigs/*"},
    "onGetExtendedAgentCard": {accessor: "get", path: "extendedAgentCard"},
    "onGetAgentCard": {accessor: "get", path: "agentCard"}
};

# The remote function each operation is served at when the service is attached
# to a listener whose binding addresses operations by method name (JSON-RPC).
final readonly & map<string> OPERATION_REMOTE_NAMES = {
    "onSendMessage": "sendMessage",
    "onSendStreamingMessage": "sendStreamingMessage",
    "onSubscribeToTask": "subscribeToTask",
    "onGetTask": "getTask",
    "onListTasks": "listTasks",
    "onCancelTask": "cancelTask",
    "onCreateTaskPushNotificationConfig": "createTaskPushNotificationConfig",
    "onGetTaskPushNotificationConfig": "getTaskPushNotificationConfig",
    "onListTaskPushNotificationConfigs": "listTaskPushNotificationConfigs",
    "onDeleteTaskPushNotificationConfig": "deleteTaskPushNotificationConfig",
    "onGetExtendedAgentCard": "getExtendedAgentCard",
    "onGetAgentCard": "getAgentCard"
};

# The error for an operation the service does not define.
#
# + operation - The operation's name
# + return - The error
isolated function operationUndefinedError(string operation) returns UnsupportedOperationError {
    string msg = string `${operation}: this agent does not support the operation`;
    return error UnsupportedOperationError(msg, message = msg, code = -32004);
}

# The error for the extended card when the service does not define it.
#
# + return - The error
isolated function extendedAgentCardUnsupportedError() returns UnsupportedOperationError {
    string msg = "capabilities.extendedAgentCard is false: no extended AgentCard is configured for this agent";
    return error UnsupportedOperationError(msg, message = msg, code = -32004);
}

# An attached service, with every A2A operation callable: the ones it defines,
# and an error answer for the rest.
#
# A service defines an operation as a `resource` function (HTTP+JSON, where an
# operation is a verb and a path) or as a `remote` function (JSON-RPC, where it
# is a method name); the binding is built for one or the other.
isolated class OperationBinding {
    private final Service agentService;
    private final boolean byMethodName;
    // The names of the operations the service defines, in table order
    final readonly & string[] defined;

    # + agentService - The service being attached
    # + byMethodName - Whether the operations are `remote` functions rather than resources
    isolated function init(Service agentService, boolean byMethodName = false) {
        self.agentService = agentService;
        self.byMethodName = byMethodName;
        string[] declared = (byMethodName ? describeRemoteFunctions(agentService) : describeResources(agentService))
            .'map(entry => entry.endsWith(" +context")
                ? entry.substring(0, entry.length() - " +context".length())
                : entry);
        string[] names = [];
        foreach string operation in OPERATION_ROUTES.keys() {
            if declared.indexOf(declarationFor(byMethodName, operation)) is int {
                names.push(operation);
            }
        }
        self.defined = names.cloneReadOnly();
    }

    # + operation - An operation's internal name such as `onGetTask`
    # + return - How the service declares it: `get tasks/*` for a resource,
    #            `getTask` for a remote function
    isolated function declarationOf(string operation) returns string => declarationFor(self.byMethodName, operation);

    # + operationName - An operation's internal name such as `onGetTask`
    # + return - Whether the service defines it
    isolated function isDefined(string operationName) returns boolean => self.defined.indexOf(operationName) is int;

    isolated function sendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("onSendMessage", [], context, request);
        return <Task|Message>result;
    }

    isolated function sendStreamingMessage(Context context, SendMessageRequest request)
            returns stream<StreamResponse, Error?>|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("onSendStreamingMessage", [], context, request);
        return <stream<StreamResponse, Error?>>result;
    }

    isolated function subscribeToTask(Context context, SubscribeToTaskRequest request)
            returns stream<StreamResponse, Error?>|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("onSubscribeToTask", [request.id], context, request);
        return <stream<StreamResponse, Error?>>result;
    }

    isolated function getTask(Context context, GetTaskRequest request) returns Task|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("onGetTask", [request.id], context, request);
        return <Task>result;
    }

    isolated function listTasks(Context context, ListTasksRequest request) returns ListTasksResponse|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("onListTasks", [], context, request);
        return <ListTasksResponse>result;
    }

    isolated function cancelTask(Context context, CancelTaskRequest request) returns Task|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("onCancelTask", [request.id], context, request);
        return <Task>result;
    }

    isolated function createTaskPushNotificationConfig(Context context, TaskPushNotificationConfig request)
            returns TaskPushNotificationConfig|Error {
        anydata|stream<StreamResponse, Error?> result =
            check self.run("onCreateTaskPushNotificationConfig", [request.taskId ?: ""], context, request);
        return <TaskPushNotificationConfig>result;
    }

    isolated function getTaskPushNotificationConfig(Context context, GetTaskPushNotificationConfigRequest request)
            returns TaskPushNotificationConfig|Error {
        anydata|stream<StreamResponse, Error?> result =
            check self.run("onGetTaskPushNotificationConfig", [request.taskId, request.id], context, request);
        return <TaskPushNotificationConfig>result;
    }

    isolated function listTaskPushNotificationConfigs(Context context, ListTaskPushNotificationConfigsRequest request)
            returns ListTaskPushNotificationConfigsResponse|Error {
        anydata|stream<StreamResponse, Error?> result =
            check self.run("onListTaskPushNotificationConfigs", [request.taskId], context, request);
        return <ListTaskPushNotificationConfigsResponse>result;
    }

    isolated function deleteTaskPushNotificationConfig(Context context, DeleteTaskPushNotificationConfigRequest request)
            returns Error? {
        _ = check self.run("onDeleteTaskPushNotificationConfig", [request.taskId, request.id], context, request);
    }

    isolated function getExtendedAgentCard(Context context, GetExtendedAgentCardRequest request)
            returns AgentCard|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("onGetExtendedAgentCard", [], context, request);
        return <AgentCard>result;
    }

    isolated function getAgentCard() returns AgentCard|Error {
        anydata|stream<StreamResponse, Error?> result = check self.run("onGetAgentCard", [], {headers: {}}, ());
        return <AgentCard>result;
    }

    # Calls the resource an operation is served at.
    #
    # + operation - The operation's internal name
    # + pathParams - The values of the resource's path parameters, in order
    # + context - The caller's context, passed when the resource declares it
    # + request - The request record, or `()` for a resource that takes none
    # + return - What the resource returned, or the error it returned
    private isolated function run(string operation, string[] pathParams, Context context, anydata request)
            returns anydata|stream<StreamResponse, Error?>|Error {
        if !self.isDefined(operation) {
            return self.undefinedError(operation);
        }
        anydata|stream<StreamResponse, Error?>|error result;
        if self.byMethodName {
            result = invokeRemoteFunction(self.agentService, OPERATION_REMOTE_NAMES.get(operation), context, request);
        } else {
            ResourceRoute route = OPERATION_ROUTES.get(operation);
            result = invokeResource(self.agentService, route.accessor, route.path, pathParams, context, request);
        }
        if result is Error {
            return result;
        }
        if result is error {
            string msg = string `${operation}: ${result.message()}`;
            return error InternalError(msg, message = msg);
        }
        return result;
    }

    private isolated function undefinedError(string operation) returns Error {
        match operation {
            "onSendStreamingMessage"|"onSubscribeToTask" => {
                return serverStreamingUnsupportedError(operation);
            }
            "onCreateTaskPushNotificationConfig"|"onGetTaskPushNotificationConfig"|
            "onListTaskPushNotificationConfigs"|"onDeleteTaskPushNotificationConfig" => {
                return serverPushNotificationsUnsupportedError(operation);
            }
            "onGetExtendedAgentCard" => {
                return extendedAgentCardUnsupportedError();
            }
        }
        return operationUndefinedError(operation);
    }
}

# How a service declares an operation.
#
# + byMethodName - Whether the binding addresses operations by method name
# + operation - The operation's internal name
# + return - `get tasks/*` for a resource, `getTask` for a remote function
isolated function declarationFor(boolean byMethodName, string operation) returns string {
    if byMethodName {
        return OPERATION_REMOTE_NAMES.get(operation);
    }
    ResourceRoute route = OPERATION_ROUTES.get(operation);
    return string `${route.accessor} ${route.path}`;
}
