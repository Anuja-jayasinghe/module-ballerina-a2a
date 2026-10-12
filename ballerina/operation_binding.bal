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
// A remote call on a service object compiles only through a `final` field of
// `self`, so the binding holds fields per operation. A service may define an
// operation with or without the optional `Context` parameter, so each
// operation has a field for each form. An operation the service does not
// define is filled with a stand-in that answers `UnsupportedOperationError`
// (or `PushNotificationNotSupportedError` for the push-notification
// operations), which is what the specification asks of a capability the agent
// does not offer.
//
// Whether a service defines an operation is read with `value:ensureType`: the
// `is` operator on a service object type does not compile on the current
// compiler (2201.13.5).

import ballerina/lang.value;

# What an agent that does not define an operation answers (with-context forms).
isolated service class UndefinedOperations {
    *SendMessageOperation;
    *SendStreamingMessageOperation;
    *SubscribeToTaskOperation;
    *GetTaskOperation;
    *ListTasksOperation;
    *CancelTaskOperation;
    *CreateTaskPushNotificationConfigOperation;
    *GetTaskPushNotificationConfigOperation;
    *ListTaskPushNotificationConfigsOperation;
    *DeleteTaskPushNotificationConfigOperation;
    *GetExtendedAgentCardOperation;
    *GetAgentCardOperation;

    remote isolated function onSendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        return operationUndefinedError("sendMessage");
    }

    remote isolated function onSendStreamingMessage(Context context, SendMessageRequest request) returns stream<StreamResponse, Error?>|Error {
        return serverStreamingUnsupportedError("sendStreamingMessage");
    }

    remote isolated function onSubscribeToTask(Context context, SubscribeToTaskRequest request) returns stream<StreamResponse, Error?>|Error {
        return serverStreamingUnsupportedError("subscribeToTask");
    }

    remote isolated function onGetTask(Context context, GetTaskRequest request) returns Task|Error {
        return operationUndefinedError("getTask");
    }

    remote isolated function onListTasks(Context context, ListTasksRequest request) returns ListTasksResponse|Error {
        return operationUndefinedError("listTasks");
    }

    remote isolated function onCancelTask(Context context, CancelTaskRequest request) returns Task|Error {
        return operationUndefinedError("cancelTask");
    }

    remote isolated function onCreateTaskPushNotificationConfig(Context context, TaskPushNotificationConfig request) returns TaskPushNotificationConfig|Error {
        return serverPushNotificationsUnsupportedError("createTaskPushNotificationConfig");
    }

    remote isolated function onGetTaskPushNotificationConfig(Context context, GetTaskPushNotificationConfigRequest request) returns TaskPushNotificationConfig|Error {
        return serverPushNotificationsUnsupportedError("getTaskPushNotificationConfig");
    }

    remote isolated function onListTaskPushNotificationConfigs(Context context, ListTaskPushNotificationConfigsRequest request) returns ListTaskPushNotificationConfigsResponse|Error {
        return serverPushNotificationsUnsupportedError("listTaskPushNotificationConfigs");
    }

    remote isolated function onDeleteTaskPushNotificationConfig(Context context, DeleteTaskPushNotificationConfigRequest request) returns Error? {
        return serverPushNotificationsUnsupportedError("deleteTaskPushNotificationConfig");
    }

    remote isolated function onGetExtendedAgentCard(Context context, GetExtendedAgentCardRequest request) returns AgentCard|Error {
        return extendedAgentCardUnsupportedError();
    }

    remote isolated function onGetAgentCard() returns AgentCard|Error {
        return operationUndefinedError("getAgentCard");
    }
}

isolated service class UndefinedPlainOperations {
    *SendMessagePlainOperation;
    *SendStreamingMessagePlainOperation;
    *SubscribeToTaskPlainOperation;
    *GetTaskPlainOperation;
    *ListTasksPlainOperation;
    *CancelTaskPlainOperation;
    *CreateTaskPushNotificationConfigPlainOperation;
    *GetTaskPushNotificationConfigPlainOperation;
    *ListTaskPushNotificationConfigsPlainOperation;
    *DeleteTaskPushNotificationConfigPlainOperation;
    *GetExtendedAgentCardPlainOperation;

    remote isolated function onSendMessage(SendMessageRequest request) returns Task|Message|Error {
        return operationUndefinedError("sendMessage");
    }

    remote isolated function onSendStreamingMessage(SendMessageRequest request) returns stream<StreamResponse, Error?>|Error {
        return serverStreamingUnsupportedError("sendStreamingMessage");
    }

    remote isolated function onSubscribeToTask(SubscribeToTaskRequest request) returns stream<StreamResponse, Error?>|Error {
        return serverStreamingUnsupportedError("subscribeToTask");
    }

    remote isolated function onGetTask(GetTaskRequest request) returns Task|Error {
        return operationUndefinedError("getTask");
    }

    remote isolated function onListTasks(ListTasksRequest request) returns ListTasksResponse|Error {
        return operationUndefinedError("listTasks");
    }

    remote isolated function onCancelTask(CancelTaskRequest request) returns Task|Error {
        return operationUndefinedError("cancelTask");
    }

    remote isolated function onCreateTaskPushNotificationConfig(TaskPushNotificationConfig request) returns TaskPushNotificationConfig|Error {
        return serverPushNotificationsUnsupportedError("createTaskPushNotificationConfig");
    }

    remote isolated function onGetTaskPushNotificationConfig(GetTaskPushNotificationConfigRequest request) returns TaskPushNotificationConfig|Error {
        return serverPushNotificationsUnsupportedError("getTaskPushNotificationConfig");
    }

    remote isolated function onListTaskPushNotificationConfigs(ListTaskPushNotificationConfigsRequest request) returns ListTaskPushNotificationConfigsResponse|Error {
        return serverPushNotificationsUnsupportedError("listTaskPushNotificationConfigs");
    }

    remote isolated function onDeleteTaskPushNotificationConfig(DeleteTaskPushNotificationConfigRequest request) returns Error? {
        return serverPushNotificationsUnsupportedError("deleteTaskPushNotificationConfig");
    }

    remote isolated function onGetExtendedAgentCard(GetExtendedAgentCardRequest request) returns AgentCard|Error {
        return extendedAgentCardUnsupportedError();
    }
}

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
# and a stand-in for the rest.
isolated class OperationBinding {
    private final SendMessageOperation sendMessageWithContext;
    private final SendMessagePlainOperation sendMessagePlain;
    private final boolean sendMessageUsesContext;
    private final SendStreamingMessageOperation sendStreamingMessageWithContext;
    private final SendStreamingMessagePlainOperation sendStreamingMessagePlain;
    private final boolean sendStreamingMessageUsesContext;
    private final SubscribeToTaskOperation subscribeToTaskWithContext;
    private final SubscribeToTaskPlainOperation subscribeToTaskPlain;
    private final boolean subscribeToTaskUsesContext;
    private final GetTaskOperation getTaskWithContext;
    private final GetTaskPlainOperation getTaskPlain;
    private final boolean getTaskUsesContext;
    private final ListTasksOperation listTasksWithContext;
    private final ListTasksPlainOperation listTasksPlain;
    private final boolean listTasksUsesContext;
    private final CancelTaskOperation cancelTaskWithContext;
    private final CancelTaskPlainOperation cancelTaskPlain;
    private final boolean cancelTaskUsesContext;
    private final CreateTaskPushNotificationConfigOperation createTaskPushNotificationConfigWithContext;
    private final CreateTaskPushNotificationConfigPlainOperation createTaskPushNotificationConfigPlain;
    private final boolean createTaskPushNotificationConfigUsesContext;
    private final GetTaskPushNotificationConfigOperation getTaskPushNotificationConfigWithContext;
    private final GetTaskPushNotificationConfigPlainOperation getTaskPushNotificationConfigPlain;
    private final boolean getTaskPushNotificationConfigUsesContext;
    private final ListTaskPushNotificationConfigsOperation listTaskPushNotificationConfigsWithContext;
    private final ListTaskPushNotificationConfigsPlainOperation listTaskPushNotificationConfigsPlain;
    private final boolean listTaskPushNotificationConfigsUsesContext;
    private final DeleteTaskPushNotificationConfigOperation deleteTaskPushNotificationConfigWithContext;
    private final DeleteTaskPushNotificationConfigPlainOperation deleteTaskPushNotificationConfigPlain;
    private final boolean deleteTaskPushNotificationConfigUsesContext;
    private final GetExtendedAgentCardOperation getExtendedAgentCardWithContext;
    private final GetExtendedAgentCardPlainOperation getExtendedAgentCardPlain;
    private final boolean getExtendedAgentCardUsesContext;
    private final GetAgentCardOperation getAgentCardOperation;
    // The names of the operations the service defines, in declaration order
    final readonly & string[] defined;

    # + agentService - The service being attached
    isolated function init(Service agentService) {
        UndefinedOperations withContextStand = new;
        UndefinedPlainOperations plainStand = new;
        string[] names = [];
        SendMessageOperation|error sendMessageFull = value:ensureType(agentService, SendMessageOperation);
        if sendMessageFull is SendMessageOperation {
            self.sendMessageWithContext = sendMessageFull;
            self.sendMessagePlain = plainStand;
            self.sendMessageUsesContext = true;
            names.push("onSendMessage");
        } else {
            self.sendMessageWithContext = withContextStand;
            SendMessagePlainOperation|error sendMessageShort = value:ensureType(agentService, SendMessagePlainOperation);
            if sendMessageShort is SendMessagePlainOperation {
                self.sendMessagePlain = sendMessageShort;
                names.push("onSendMessage");
            } else {
                self.sendMessagePlain = plainStand;
            }
            self.sendMessageUsesContext = false;
        }
        SendStreamingMessageOperation|error sendStreamingMessageFull = value:ensureType(agentService, SendStreamingMessageOperation);
        if sendStreamingMessageFull is SendStreamingMessageOperation {
            self.sendStreamingMessageWithContext = sendStreamingMessageFull;
            self.sendStreamingMessagePlain = plainStand;
            self.sendStreamingMessageUsesContext = true;
            names.push("onSendStreamingMessage");
        } else {
            self.sendStreamingMessageWithContext = withContextStand;
            SendStreamingMessagePlainOperation|error sendStreamingMessageShort = value:ensureType(agentService, SendStreamingMessagePlainOperation);
            if sendStreamingMessageShort is SendStreamingMessagePlainOperation {
                self.sendStreamingMessagePlain = sendStreamingMessageShort;
                names.push("onSendStreamingMessage");
            } else {
                self.sendStreamingMessagePlain = plainStand;
            }
            self.sendStreamingMessageUsesContext = false;
        }
        SubscribeToTaskOperation|error subscribeToTaskFull = value:ensureType(agentService, SubscribeToTaskOperation);
        if subscribeToTaskFull is SubscribeToTaskOperation {
            self.subscribeToTaskWithContext = subscribeToTaskFull;
            self.subscribeToTaskPlain = plainStand;
            self.subscribeToTaskUsesContext = true;
            names.push("onSubscribeToTask");
        } else {
            self.subscribeToTaskWithContext = withContextStand;
            SubscribeToTaskPlainOperation|error subscribeToTaskShort = value:ensureType(agentService, SubscribeToTaskPlainOperation);
            if subscribeToTaskShort is SubscribeToTaskPlainOperation {
                self.subscribeToTaskPlain = subscribeToTaskShort;
                names.push("onSubscribeToTask");
            } else {
                self.subscribeToTaskPlain = plainStand;
            }
            self.subscribeToTaskUsesContext = false;
        }
        GetTaskOperation|error getTaskFull = value:ensureType(agentService, GetTaskOperation);
        if getTaskFull is GetTaskOperation {
            self.getTaskWithContext = getTaskFull;
            self.getTaskPlain = plainStand;
            self.getTaskUsesContext = true;
            names.push("onGetTask");
        } else {
            self.getTaskWithContext = withContextStand;
            GetTaskPlainOperation|error getTaskShort = value:ensureType(agentService, GetTaskPlainOperation);
            if getTaskShort is GetTaskPlainOperation {
                self.getTaskPlain = getTaskShort;
                names.push("onGetTask");
            } else {
                self.getTaskPlain = plainStand;
            }
            self.getTaskUsesContext = false;
        }
        ListTasksOperation|error listTasksFull = value:ensureType(agentService, ListTasksOperation);
        if listTasksFull is ListTasksOperation {
            self.listTasksWithContext = listTasksFull;
            self.listTasksPlain = plainStand;
            self.listTasksUsesContext = true;
            names.push("onListTasks");
        } else {
            self.listTasksWithContext = withContextStand;
            ListTasksPlainOperation|error listTasksShort = value:ensureType(agentService, ListTasksPlainOperation);
            if listTasksShort is ListTasksPlainOperation {
                self.listTasksPlain = listTasksShort;
                names.push("onListTasks");
            } else {
                self.listTasksPlain = plainStand;
            }
            self.listTasksUsesContext = false;
        }
        CancelTaskOperation|error cancelTaskFull = value:ensureType(agentService, CancelTaskOperation);
        if cancelTaskFull is CancelTaskOperation {
            self.cancelTaskWithContext = cancelTaskFull;
            self.cancelTaskPlain = plainStand;
            self.cancelTaskUsesContext = true;
            names.push("onCancelTask");
        } else {
            self.cancelTaskWithContext = withContextStand;
            CancelTaskPlainOperation|error cancelTaskShort = value:ensureType(agentService, CancelTaskPlainOperation);
            if cancelTaskShort is CancelTaskPlainOperation {
                self.cancelTaskPlain = cancelTaskShort;
                names.push("onCancelTask");
            } else {
                self.cancelTaskPlain = plainStand;
            }
            self.cancelTaskUsesContext = false;
        }
        CreateTaskPushNotificationConfigOperation|error createTaskPushNotificationConfigFull = value:ensureType(agentService, CreateTaskPushNotificationConfigOperation);
        if createTaskPushNotificationConfigFull is CreateTaskPushNotificationConfigOperation {
            self.createTaskPushNotificationConfigWithContext = createTaskPushNotificationConfigFull;
            self.createTaskPushNotificationConfigPlain = plainStand;
            self.createTaskPushNotificationConfigUsesContext = true;
            names.push("onCreateTaskPushNotificationConfig");
        } else {
            self.createTaskPushNotificationConfigWithContext = withContextStand;
            CreateTaskPushNotificationConfigPlainOperation|error createTaskPushNotificationConfigShort = value:ensureType(agentService, CreateTaskPushNotificationConfigPlainOperation);
            if createTaskPushNotificationConfigShort is CreateTaskPushNotificationConfigPlainOperation {
                self.createTaskPushNotificationConfigPlain = createTaskPushNotificationConfigShort;
                names.push("onCreateTaskPushNotificationConfig");
            } else {
                self.createTaskPushNotificationConfigPlain = plainStand;
            }
            self.createTaskPushNotificationConfigUsesContext = false;
        }
        GetTaskPushNotificationConfigOperation|error getTaskPushNotificationConfigFull = value:ensureType(agentService, GetTaskPushNotificationConfigOperation);
        if getTaskPushNotificationConfigFull is GetTaskPushNotificationConfigOperation {
            self.getTaskPushNotificationConfigWithContext = getTaskPushNotificationConfigFull;
            self.getTaskPushNotificationConfigPlain = plainStand;
            self.getTaskPushNotificationConfigUsesContext = true;
            names.push("onGetTaskPushNotificationConfig");
        } else {
            self.getTaskPushNotificationConfigWithContext = withContextStand;
            GetTaskPushNotificationConfigPlainOperation|error getTaskPushNotificationConfigShort = value:ensureType(agentService, GetTaskPushNotificationConfigPlainOperation);
            if getTaskPushNotificationConfigShort is GetTaskPushNotificationConfigPlainOperation {
                self.getTaskPushNotificationConfigPlain = getTaskPushNotificationConfigShort;
                names.push("onGetTaskPushNotificationConfig");
            } else {
                self.getTaskPushNotificationConfigPlain = plainStand;
            }
            self.getTaskPushNotificationConfigUsesContext = false;
        }
        ListTaskPushNotificationConfigsOperation|error listTaskPushNotificationConfigsFull = value:ensureType(agentService, ListTaskPushNotificationConfigsOperation);
        if listTaskPushNotificationConfigsFull is ListTaskPushNotificationConfigsOperation {
            self.listTaskPushNotificationConfigsWithContext = listTaskPushNotificationConfigsFull;
            self.listTaskPushNotificationConfigsPlain = plainStand;
            self.listTaskPushNotificationConfigsUsesContext = true;
            names.push("onListTaskPushNotificationConfigs");
        } else {
            self.listTaskPushNotificationConfigsWithContext = withContextStand;
            ListTaskPushNotificationConfigsPlainOperation|error listTaskPushNotificationConfigsShort = value:ensureType(agentService, ListTaskPushNotificationConfigsPlainOperation);
            if listTaskPushNotificationConfigsShort is ListTaskPushNotificationConfigsPlainOperation {
                self.listTaskPushNotificationConfigsPlain = listTaskPushNotificationConfigsShort;
                names.push("onListTaskPushNotificationConfigs");
            } else {
                self.listTaskPushNotificationConfigsPlain = plainStand;
            }
            self.listTaskPushNotificationConfigsUsesContext = false;
        }
        DeleteTaskPushNotificationConfigOperation|error deleteTaskPushNotificationConfigFull = value:ensureType(agentService, DeleteTaskPushNotificationConfigOperation);
        if deleteTaskPushNotificationConfigFull is DeleteTaskPushNotificationConfigOperation {
            self.deleteTaskPushNotificationConfigWithContext = deleteTaskPushNotificationConfigFull;
            self.deleteTaskPushNotificationConfigPlain = plainStand;
            self.deleteTaskPushNotificationConfigUsesContext = true;
            names.push("onDeleteTaskPushNotificationConfig");
        } else {
            self.deleteTaskPushNotificationConfigWithContext = withContextStand;
            DeleteTaskPushNotificationConfigPlainOperation|error deleteTaskPushNotificationConfigShort = value:ensureType(agentService, DeleteTaskPushNotificationConfigPlainOperation);
            if deleteTaskPushNotificationConfigShort is DeleteTaskPushNotificationConfigPlainOperation {
                self.deleteTaskPushNotificationConfigPlain = deleteTaskPushNotificationConfigShort;
                names.push("onDeleteTaskPushNotificationConfig");
            } else {
                self.deleteTaskPushNotificationConfigPlain = plainStand;
            }
            self.deleteTaskPushNotificationConfigUsesContext = false;
        }
        GetExtendedAgentCardOperation|error getExtendedAgentCardFull = value:ensureType(agentService, GetExtendedAgentCardOperation);
        if getExtendedAgentCardFull is GetExtendedAgentCardOperation {
            self.getExtendedAgentCardWithContext = getExtendedAgentCardFull;
            self.getExtendedAgentCardPlain = plainStand;
            self.getExtendedAgentCardUsesContext = true;
            names.push("onGetExtendedAgentCard");
        } else {
            self.getExtendedAgentCardWithContext = withContextStand;
            GetExtendedAgentCardPlainOperation|error getExtendedAgentCardShort = value:ensureType(agentService, GetExtendedAgentCardPlainOperation);
            if getExtendedAgentCardShort is GetExtendedAgentCardPlainOperation {
                self.getExtendedAgentCardPlain = getExtendedAgentCardShort;
                names.push("onGetExtendedAgentCard");
            } else {
                self.getExtendedAgentCardPlain = plainStand;
            }
            self.getExtendedAgentCardUsesContext = false;
        }
        GetAgentCardOperation|error agentCardFound = value:ensureType(agentService, GetAgentCardOperation);
        if agentCardFound is GetAgentCardOperation {
            self.getAgentCardOperation = agentCardFound;
            names.push("onGetAgentCard");
        } else {
            self.getAgentCardOperation = withContextStand;
        }
        self.defined = names.cloneReadOnly();
    }

    # + operationName - A remote function name such as `onGetTask`
    # + return - Whether the service defines it
    isolated function isDefined(string operationName) returns boolean => self.defined.indexOf(operationName) is int;

    isolated function sendMessage(Context context, SendMessageRequest request) returns Task|Message|Error {
        if self.sendMessageUsesContext {
            return self.sendMessageWithContext->onSendMessage(context, request);
        }
        return self.sendMessagePlain->onSendMessage(request);
    }

    isolated function sendStreamingMessage(Context context, SendMessageRequest request) returns stream<StreamResponse, Error?>|Error {
        if self.sendStreamingMessageUsesContext {
            return self.sendStreamingMessageWithContext->onSendStreamingMessage(context, request);
        }
        return self.sendStreamingMessagePlain->onSendStreamingMessage(request);
    }

    isolated function subscribeToTask(Context context, SubscribeToTaskRequest request) returns stream<StreamResponse, Error?>|Error {
        if self.subscribeToTaskUsesContext {
            return self.subscribeToTaskWithContext->onSubscribeToTask(context, request);
        }
        return self.subscribeToTaskPlain->onSubscribeToTask(request);
    }

    isolated function getTask(Context context, GetTaskRequest request) returns Task|Error {
        if self.getTaskUsesContext {
            return self.getTaskWithContext->onGetTask(context, request);
        }
        return self.getTaskPlain->onGetTask(request);
    }

    isolated function listTasks(Context context, ListTasksRequest request) returns ListTasksResponse|Error {
        if self.listTasksUsesContext {
            return self.listTasksWithContext->onListTasks(context, request);
        }
        return self.listTasksPlain->onListTasks(request);
    }

    isolated function cancelTask(Context context, CancelTaskRequest request) returns Task|Error {
        if self.cancelTaskUsesContext {
            return self.cancelTaskWithContext->onCancelTask(context, request);
        }
        return self.cancelTaskPlain->onCancelTask(request);
    }

    isolated function createTaskPushNotificationConfig(Context context, TaskPushNotificationConfig request) returns TaskPushNotificationConfig|Error {
        if self.createTaskPushNotificationConfigUsesContext {
            return self.createTaskPushNotificationConfigWithContext->onCreateTaskPushNotificationConfig(context, request);
        }
        return self.createTaskPushNotificationConfigPlain->onCreateTaskPushNotificationConfig(request);
    }

    isolated function getTaskPushNotificationConfig(Context context, GetTaskPushNotificationConfigRequest request) returns TaskPushNotificationConfig|Error {
        if self.getTaskPushNotificationConfigUsesContext {
            return self.getTaskPushNotificationConfigWithContext->onGetTaskPushNotificationConfig(context, request);
        }
        return self.getTaskPushNotificationConfigPlain->onGetTaskPushNotificationConfig(request);
    }

    isolated function listTaskPushNotificationConfigs(Context context, ListTaskPushNotificationConfigsRequest request) returns ListTaskPushNotificationConfigsResponse|Error {
        if self.listTaskPushNotificationConfigsUsesContext {
            return self.listTaskPushNotificationConfigsWithContext->onListTaskPushNotificationConfigs(context, request);
        }
        return self.listTaskPushNotificationConfigsPlain->onListTaskPushNotificationConfigs(request);
    }

    isolated function deleteTaskPushNotificationConfig(Context context, DeleteTaskPushNotificationConfigRequest request) returns Error? {
        if self.deleteTaskPushNotificationConfigUsesContext {
            return self.deleteTaskPushNotificationConfigWithContext->onDeleteTaskPushNotificationConfig(context, request);
        }
        return self.deleteTaskPushNotificationConfigPlain->onDeleteTaskPushNotificationConfig(request);
    }

    isolated function getExtendedAgentCard(Context context, GetExtendedAgentCardRequest request) returns AgentCard|Error {
        if self.getExtendedAgentCardUsesContext {
            return self.getExtendedAgentCardWithContext->onGetExtendedAgentCard(context, request);
        }
        return self.getExtendedAgentCardPlain->onGetExtendedAgentCard(request);
    }

    isolated function getAgentCard() returns AgentCard|Error {
        return self.getAgentCardOperation->onGetAgentCard();
    }
}
