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

// A2A error types.


# Detail attached to every Error.
public type ErrorDetail record {|
    # Originating JSON-RPC code, preserved for diagnostics
    int code?;
    # Human-readable error message
    string message?;
    # Structured error details from the server
    json data?;
    json...;
|};

# Base type for every A2A protocol error. Distinct so that `is Error`
# reliably matches any of its subtypes, and each subtype below is in turn
# distinguishable from its siblings via `is`.
public type Error distinct error<ErrorDetail>;

# Each specific error derives from Error — adding a new one later means
# adding one line here, nothing else in the codebase changes.
public type TaskNotFoundError distinct Error;

public type TaskNotCancelableError distinct Error;

public type UnsupportedOperationError distinct Error;

public type ContentTypeNotSupportedError distinct Error;

public type InvalidAgentResponseError distinct Error;

public type VersionNotSupportedError distinct Error;

public type PushNotificationNotSupportedError distinct Error;

public type ExtendedAgentCardNotConfiguredError distinct Error;

public type ExtensionSupportRequiredError distinct Error;

# This library's catch-all, for failures that map to no A2A error type.
#
# Specification section 5.4 lists the canonical A2A error types and their
# bindings; there are nine, and the other nine types in this file are exactly
# those. `InternalError` is not one of them — it shares a name with
# JSON-RPC's standard `-32603`, but it is not that specifically, and its
# `code` here is whatever the failure carried: an HTTP status with no A2A
# error code behind it, a JSON-RPC standard code, or none at all.
#
# It covers three kinds of failure the specification's own taxonomy has no
# entry for:
#
# - a transport-level failure carrying no A2A error code
# - a malformed envelope that never reached an operation
# - a client-side precondition failure, caught before any request is sent —
#   the specification defines no error for these at all, since sections
#   3.3.2 and 5.4 both describe *server* behaviour
#
# A caller matching on a specific protocol condition should match one of the
# nine typed errors above; this one means "something failed that the protocol
# does not name".
public type InternalError distinct Error;

# Builds a client-side InvalidAgentResponseError with the same JSON-RPC
# code (-32006) `toA2AErrorFromRest` already uses for this case. Every
# "the agent's response doesn't parse into what this call expects" site in
# this library goes through this, rather than letting the underlying
# `cloneWithType`/`ensureType` failure propagate as a bare, untyped error.
#
# + message - what specifically failed to parse
# + return - a typed InvalidAgentResponseError
isolated function invalidAgentResponse(string message) returns InvalidAgentResponseError {
    return error InvalidAgentResponseError(message, message = message, code = -32006);
}

# Wraps a raw, untyped error (a connection failure from `ballerina/http`/
# `ballerina/grpc`, a mime-parsing failure, an unencodable parameter
# value, ...) into an InternalError, so no public method returns a
# bare `error` a caller can't pattern-match against. Idempotent: passes
# an already-typed Error straight through unchanged, so this is safe
# to call at every boundary between this library's internals and its
# public surface without needing to know in advance whether the error
# it's given has already been wrapped.
#
# Does not use Ballerina's built-in `cause` — confirmed empirically it
# isn't accepted once an error's detail type has named fields of its own
# (ErrorDetail's `message`/`code`/`data` are), only on the bare
# default `error` detail shape. The original error's own message is
# folded into the new one's instead, so the real failure reason is still
# visible to a caller/log, just not as a structurally separate cause.
#
# + e - the raw error to wrap, or an already-typed Error to pass through
# + return - e unchanged if it was already an Error, otherwise a new
#            InternalError carrying e's message
isolated function wrapTransportError(error e) returns Error {
    if e is Error {
        return e;
    }
    string msg = string `Transport-level failure: ${e.message()}`;
    return error InternalError(msg, message = msg);
}

# Maps a REST binding error response onto the same Error hierarchy the
# JSON-RPC binding maps onto, so callers handle errors identically
# regardless of which binding their Client negotiated. HTTP status alone
# is not sufficient to disambiguate — seven distinct A2A errors all return
# 400 — so the discriminator is the `reason` field of a
# google.rpc.ErrorInfo entry inside the error body's `details` array, per
# the reference a2a-python SDK's REST error-parsing shape.
#
# + statusCode - the HTTP status code the response carried
# + body - the parsed JSON error body, if any (absent for e.g. a stream
#          drop with no body available)
# + return - the corresponding typed Error, with detail.code synthesized
#            to the equivalent JSON-RPC code so a caller checking
#            detail.code sees identical values regardless of binding
isolated function toA2AErrorFromRest(int statusCode, json? body) returns Error {
    string? reason = extractRestErrorReason(body);
    string message = extractRestErrorMessage(body) ?: string `REST request failed with HTTP ${statusCode}`;
    json? data = extractRestErrorMetadata(body);

    if reason is string {
        match reason {
            "TASK_NOT_FOUND" => {
                return error TaskNotFoundError(message, message = message, code = -32001, data = data);
            }
            "TASK_NOT_CANCELABLE" => {
                return error TaskNotCancelableError(message, message = message, code = -32002, data = data);
            }
            "PUSH_NOTIFICATION_NOT_SUPPORTED" => {
                return error PushNotificationNotSupportedError(message, message = message, code = -32003, data = data);
            }
            "UNSUPPORTED_OPERATION" => {
                return error UnsupportedOperationError(message, message = message, code = -32004, data = data);
            }
            "CONTENT_TYPE_NOT_SUPPORTED" => {
                return error ContentTypeNotSupportedError(message, message = message, code = -32005, data = data);
            }
            "INVALID_AGENT_RESPONSE" => {
                return error InvalidAgentResponseError(message, message = message, code = -32006, data = data);
            }
            "EXTENDED_AGENT_CARD_NOT_CONFIGURED" => {
                return error ExtendedAgentCardNotConfiguredError(message, message = message, code = -32007, data = data);
            }
            "EXTENSION_SUPPORT_REQUIRED" => {
                return error ExtensionSupportRequiredError(message, message = message, code = -32008, data = data);
            }
            "VERSION_NOT_SUPPORTED" => {
                return error VersionNotSupportedError(message, message = message, code = -32009, data = data);
            }
            "INVALID_PARAMS" => {
                return error InternalError(message, message = message, code = -32602, data = data);
            }
            "INVALID_REQUEST" => {
                return error InternalError(message, message = message, code = -32600, data = data);
            }
            "METHOD_NOT_FOUND" => {
                return error InternalError(message, message = message, code = -32601, data = data);
            }
            "INTERNAL_ERROR" => {
                return error InternalError(message, message = message, code = -32603, data = data);
            }
        }
    }

    // No usable ErrorInfo reason — fall back on status code alone.
    if statusCode == 404 {
        return error TaskNotFoundError(message, message = message, code = -32001, data = data);
    }
    if statusCode >= 500 {
        return error InternalError(message, message = message, code = -32603, data = data);
    }
    return error InternalError(message, message = message, code = statusCode, data = data);
}

# Scans a REST error body's error.details array for the first
# google.rpc.ErrorInfo entry and returns its reason string, or () if the
# body has no usable ErrorInfo entry. json field access with an
# "@"-prefixed key ("@type") isn't valid dot-syntax, so this reads through
# a map<json> bracket index instead.
#
# + body - the parsed JSON error body, if any
# + return - the matching ErrorInfo entry as a map, or () if none is found
isolated function extractRestErrorDetail(json? body) returns map<json>? {
    if body is () {
        return ();
    }
    map<json>|error bodyMap = body.ensureType();
    if bodyMap is error {
        return ();
    }
    json? errObj = bodyMap["error"];
    if errObj is () {
        return ();
    }
    map<json>|error errMap = errObj.ensureType();
    if errMap is error {
        return ();
    }
    json? detailsJson = errMap["details"];
    if !(detailsJson is json[]) {
        return ();
    }
    foreach json detail in detailsJson {
        map<json>|error detailMap = detail.ensureType();
        if detailMap is map<json> {
            json? typeVal = detailMap["@type"];
            if typeVal is string && typeVal == "type.googleapis.com/google.rpc.ErrorInfo" {
                return detailMap;
            }
        }
    }
    return ();
}

isolated function extractRestErrorReason(json? body) returns string? {
    map<json>? detailMap = extractRestErrorDetail(body);
    if detailMap is () {
        return ();
    }
    json? reasonVal = detailMap["reason"];
    return reasonVal is string ? reasonVal : ();
}

isolated function extractRestErrorMessage(json? body) returns string? {
    if body is () {
        return ();
    }
    map<json>|error bodyMap = body.ensureType();
    if bodyMap is error {
        return ();
    }
    json? errObj = bodyMap["error"];
    if errObj is () {
        return ();
    }
    map<json>|error errMap = errObj.ensureType();
    if errMap is error {
        return ();
    }
    json? msg = errMap["message"];
    return msg is string ? msg : ();
}

isolated function extractRestErrorMetadata(json? body) returns json? {
    map<json>? detailMap = extractRestErrorDetail(body);
    return detailMap is () ? () : detailMap["metadata"];
}

# Builds the client-side rejection for a streaming call the held card says
# is unsupported. Carries the same UnsupportedOperationError type and JSON-RPC
# code (-32004) the server's own rejection would, so callers matching on
# `detail().code` see one case either way; the message says explicitly that
# this never reached the network, so a caller inspecting the error text (e.g.
# in logs) can still tell the two apart.
#
# + operation - the operation name, for the error text (e.g. "subscribeToTask")
# + return - a typed, client-side UnsupportedOperationError
isolated function streamingUnsupportedError(string operation) returns UnsupportedOperationError {
    string message = string `${operation}: AgentCard.capabilities.streaming is false - rejected client-side, no request sent`;
    return error UnsupportedOperationError(message, message = message, code = -32004);
}

# Builds the client-side rejection for a getExtendedAgentCard call the held
# AgentCard says the agent does not support.
#
# Specification section 3.3.4 requires exactly this: "If
# AgentCard.capabilities.extendedAgentCard is false or not present, attempts
# to call the Get Extended Agent Card operation MUST return
# UnsupportedOperationError." Sections 3.1.11 and 13.3 say the same, and
# nowhere does the specification sanction returning the public card instead
# -- section 3.1.11 defines the output as the extended card *when the
# operation is available*, not a substitute when it is not.
#
# + return - the typed rejection
isolated function extendedCardUnsupportedError() returns UnsupportedOperationError {
    string message = "getExtendedAgentCard: AgentCard.capabilities.extendedAgentCard is false "
        + "or not present - rejected client-side, no request sent";
    return error UnsupportedOperationError(message, message = message, code = -32004);
}

# Builds the client-side rejection for a push-notification-config call the
# held card says is unsupported. Same rationale as streamingUnsupportedError.
#
# + operation - the operation name, for the error text
# + return - a typed, client-side PushNotificationNotSupportedError
isolated function pushNotificationsUnsupportedError(string operation) returns PushNotificationNotSupportedError {
    string message = string `${operation}: AgentCard.capabilities.pushNotifications is false - rejected client-side, no request sent`;
    return error PushNotificationNotSupportedError(message, message = message, code = -32003);
}
