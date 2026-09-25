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

// The server's outbound error serialization: the inverse of the client's
// `toA2AErrorFromRest`. An `a2a:Error` becomes an HTTP status plus a
// `google.rpc.Status` body carrying an `ErrorInfo.reason`, which is exactly
// the shape the client decodes -- so a client of this library and this
// library's server agree on the wire by construction.

import ballerina/http;

# The HTTP status and google.rpc reason for one A2A error type.
type ErrorBinding record {|
    # The HTTP status code to respond with
    int status;
    # The google.rpc ErrorInfo reason string
    string reason;
|};

# Maps each Error subtype to its HTTP status and ErrorInfo.reason, per
# [specification section 11.6](https://a2a-protocol.org/latest/specification/#116-error-handling). The reasons are the same strings
# `toA2AErrorFromRest` decodes; keeping the two in one module is what makes
# the round trip symmetrical.
#
# + err - The error to classify
# + return - The status and reason to serialise it as
isolated function errorBindingFor(Error err) returns ErrorBinding {
    if err is TaskNotFoundError {
        return {status: http:STATUS_NOT_FOUND, reason: "TASK_NOT_FOUND"};
    }
    if err is TaskNotCancelableError {
        return {status: http:STATUS_BAD_REQUEST, reason: "TASK_NOT_CANCELABLE"};
    }
    if err is PushNotificationNotSupportedError {
        return {status: http:STATUS_BAD_REQUEST, reason: "PUSH_NOTIFICATION_NOT_SUPPORTED"};
    }
    if err is UnsupportedOperationError {
        return {status: http:STATUS_BAD_REQUEST, reason: "UNSUPPORTED_OPERATION"};
    }
    if err is ContentTypeNotSupportedError {
        return {status: http:STATUS_BAD_REQUEST, reason: "CONTENT_TYPE_NOT_SUPPORTED"};
    }
    if err is InvalidAgentResponseError {
        // Per [specification section 5.4](https://a2a-protocol.org/latest/specification/#54-error-code-mappings)'s error-code mapping table: the
        // only two entries that aren't 400 are TaskNotFoundError (404,
        // above) and this one -- the agent's own response was the
        // problem, not the client's request.
        return {status: http:STATUS_INTERNAL_SERVER_ERROR, reason: "INVALID_AGENT_RESPONSE"};
    }
    if err is ExtendedAgentCardNotConfiguredError {
        // Per the same table: this is the server's own configuration --
        // no extended card was set up -- not the absence of a resource
        // named by the request.
        return {status: http:STATUS_BAD_REQUEST, reason: "EXTENDED_AGENT_CARD_NOT_CONFIGURED"};
    }
    if err is ExtensionSupportRequiredError {
        return {status: http:STATUS_BAD_REQUEST, reason: "EXTENSION_SUPPORT_REQUIRED"};
    }
    if err is VersionNotSupportedError {
        return {status: http:STATUS_BAD_REQUEST, reason: "VERSION_NOT_SUPPORTED"};
    }
    // InternalError is also how this library carries the standard JSON-RPC
    // "the request itself was bad" codes (see `invalidRequest`); those are the
    // caller's fault, so they are a 400 with their own reason, not a 500.
    int? code = err.detail()?.code;
    if code == -32600 {
        return {status: http:STATUS_BAD_REQUEST, reason: "INVALID_REQUEST"};
    }
    if code == -32602 {
        return {status: http:STATUS_BAD_REQUEST, reason: "INVALID_PARAMS"};
    }
    // Anything else the protocol does not name.
    return {status: http:STATUS_INTERNAL_SERVER_ERROR, reason: "INTERNAL_ERROR"};
}

# Builds the `google.rpc.Status` body for an `a2a:Error`: the shape both
# `toRestErrorResponse` (a plain HTTP error response) and the SSE
# framing layer's `event: error` frame (a mid-stream failure, framed as
# data rather than an HTTP status) carry identically -- the client's
# `extractRestErrorReason`/`extractRestErrorMessage` read either the same
# way.
#
# + err - The error to serialise
# + return - The body, keyed the same regardless of transport
isolated function restErrorBody(Error err) returns json {
    ErrorBinding binding = errorBindingFor(err);
    map<json> errorInfo = {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "reason": binding.reason,
        "domain": "a2a-protocol.org"
    };
    ErrorDetail detail = err.detail();
    json? data = detail?.data;
    if data != () {
        errorInfo["metadata"] = data;
    }
    return {
        "error": {
            "code": binding.status,
            "message": err.message(),
            "details": [errorInfo]
        }
    };
}

# Serialises an `a2a:Error` into an `http:Response`: the mapped status and a
# `google.rpc.Status` body with an `ErrorInfo` entry in `details`.
#
# The body shape matches what `extractRestErrorReason`/`extractRestErrorMessage`
# on the client side read, so a round trip preserves the error type.
#
# + err - The error to serialise
# + return - The HTTP response carrying it
isolated function toRestErrorResponse(Error err) returns http:Response {
    http:Response response = new;
    response.statusCode = errorBindingFor(err).status;
    response.setJsonPayload(restErrorBody(err), CONTENT_TYPE_A2A_JSON);
    return response;
}
