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

// The internal HTTP service the Listener attaches.
//
// It owns the A2A wire: it serves the Agent Card at the well-known path,
// routes the operation endpoints (both the bare and the /{tenant}-prefixed
// forms the proto's additional_bindings define), runs the capability and
// version gates, and turns an `a2a:Error` into the google.rpc.Status body the
// client decodes. The task lifecycle itself lives in `default_handler.bal`;
// this file is transport.
//
// A single catch-all resource matches every request and dispatches on the raw
// path. The A2A paths use literal colons (`/message:send`, `/tasks/{id}:cancel`)
// which are not ordinary path segments, so matching the raw path is simpler
// and more faithful than trying to express them as typed resource paths.
//
// This is also why operation handlers build `http:Response` directly instead
// of returning the `http:Ok|http:BadRequest|...` status-typed unions other
// listeners in this ecosystem use: that pattern relies on a typed resource
// signature per operation, which the colon-paths rule out here. `jsonResponse`
// and `toRestErrorResponse` are the substitute -- one place each that builds
// the response, rather than one return type per operation.

import ballerina/http;

# The A2A protocol version this server implements.
const A2A_PROTOCOL_VERSION = "1.0";

# The task-scoped path prefix every task operation's path starts with.
const TASKS_PATH_PREFIX = "/tasks/";

# The push-notification-config collection segment under a task's path.
const PUSH_NOTIFICATION_CONFIGS_SEGMENT = "/pushNotificationConfigs";

isolated service class DispatcherService {
    *http:Service;

    private final AgentCard & readonly card;
    private final DefaultHandler handler;

    isolated function init(AgentCard card, DefaultHandler handler) {
        self.card = card.cloneReadOnly();
        self.handler = handler;
    }

    isolated resource function get [string... path](http:Request req)
            returns http:Response|stream<http:SseEvent, error?> {
        return self.dispatch("GET", "/" + string:'join("/", ...path), req);
    }

    isolated resource function post [string... path](http:Request req)
            returns http:Response|stream<http:SseEvent, error?> {
        return self.dispatch("POST", "/" + string:'join("/", ...path), req);
    }

    isolated resource function delete [string... path](http:Request req)
            returns http:Response|stream<http:SseEvent, error?> {
        return self.dispatch("DELETE", "/" + string:'join("/", ...path), req);
    }

    # Routes one request to the operation its method and path name, applying
    # the tenant, version, and capability gates first.
    #
    # + method - The HTTP method
    # + rawPath - The request path with a leading slash, tenant prefix intact
    # + req - The HTTP request
    # + return - The response to send
    private isolated function dispatch(string method, string rawPath, http:Request req)
            returns http:Response|stream<http:SseEvent, error?> {
        // Discovery is unversioned and untenanted. The served card's
        // interface URL is filled from the Host the client reached us on —
        // the server knows its port but not its externally-visible host, so
        // the request that fetches the card is what reveals it. This is how a
        // client that resolves the card then gets a usable URL to call.
        if method == "GET" && rawPath == "/.well-known/agent-card.json" {
            http:Response cardResponse = new;
            cardResponse.setJsonPayload(self.cardForHost(req).toJson());
            return cardResponse;
        }

        Error? versionError = self.checkVersion(req);
        if versionError is Error {
            return toRestErrorResponse(versionError);
        }

        // Strip a leading /{tenant} segment. The tenant must match the card's
        // declared one; the untenanted form carries no tenant.
        [string, string?]|Error routed = self.stripTenant(rawPath);
        if routed is Error {
            return toRestErrorResponse(routed);
        }
        [string, string?] [path, tenant] = routed;

        http:Response|stream<http:SseEvent, error?>|Error result = self.route(method, path, tenant, req);
        if result is Error {
            return toRestErrorResponse(result);
        }
        return result;
    }

    # The served card with its HTTP+JSON interface URL filled from the
    # request's Host header.
    #
    # + req - The discovery request
    # + return - A copy of the card with a usable interface URL
    private isolated function cardForHost(http:Request req) returns AgentCard {
        string|http:HeaderNotFoundError host = req.getHeader("Host");
        if host !is string {
            return self.card;
        }
        // The held card is readonly, so round-trip through JSON for a fresh
        // mutable copy, then fill the HTTP+JSON interface's URL.
        // `deriveServedCard` put a single such entry there.
        AgentCard|error served = self.card.toJson().cloneWithType(AgentCard);
        if served is error {
            return self.card;
        }
        foreach int i in 0 ..< served.supportedInterfaces.length() {
            if served.supportedInterfaces[i].protocolBinding == HTTP_JSON {
                served.supportedInterfaces[i].url = string `http://${host}`;
            }
        }
        return served;
    }

    # Rejects a request whose A2A-Version header names anything but exactly
    # 1.0. An absent header means 0.3 (section 3.6.2), which this v1.0-only
    # server does not serve. Specification section 3.6.2 requires Major.Minor
    # to match exactly and gives no guarantee that a later 1.x minor stays
    # wire-compatible with 1.0 -- so "1.1" is exactly as unsafe to accept as
    # "2.0" or "0.3" is. Matches the client-side requireV1Interface check.
    #
    # + req - The HTTP request
    # + return - A VersionNotSupportedError when the version is unsupported
    private isolated function checkVersion(http:Request req) returns Error? {
        string|http:HeaderNotFoundError header = req.getHeader("A2A-Version");
        string version = header is string ? header : "0.3";
        if version != A2A_PROTOCOL_VERSION {
            string msg = string `A2A protocol version ${version} is not supported; `
                + string `this interface serves v1.0`;
            return error VersionNotSupportedError(msg, message = msg);
        }
        return;
    }

    # Splits an optional leading /{tenant} segment off the path.
    #
    # The proto gives every operation a /{tenant}-prefixed additional binding.
    # A prefixed request must carry the tenant the card declares, or it is
    # rejected; the bare form carries no tenant.
    #
    # + rawPath - The request path
    # + return - The path with any tenant prefix removed, and the tenant (or
    #            `()`); or an error if a tenant prefix does not match the card
    private isolated function stripTenant(string rawPath) returns [string, string?]|Error {
        // The known operation paths all begin with one of these.
        foreach string known in ["/message:", "/tasks", "/extendedAgentCard"] {
            if rawPath.startsWith(known) {
                return [rawPath, ()];
            }
        }
        // Otherwise the first segment is a tenant: /{tenant}/rest...
        int? secondSlash = rawPath.indexOf("/", 1);
        if secondSlash is int {
            string tenant = rawPath.substring(1, secondSlash);
            string rest = rawPath.substring(secondSlash);
            string? declared = declaredTenant(self.card);
            if declared is () || declared != tenant {
                string msg = string `request routed under tenant "${tenant}", which the agent does not serve`;
                return error InvalidAgentResponseError(msg, message = msg);
            }
            return [rest, tenant];
        }
        return [rawPath, ()];
    }

    # Dispatches a tenant-stripped path to its operation.
    #
    # The unary operations and the two streaming ones are wired in this
    # release; the push-config store and the extended card are added in
    # later changes, and an unmatched path is a 404-shaped InternalError.
    #
    # + method - The HTTP method
    # + path - The path with no tenant prefix
    # + tenant - The matched tenant, or `()`
    # + req - The HTTP request
    # + return - The response, or an error to serialise
    private isolated function route(string method, string path, string? tenant, http:Request req)
            returns http:Response|stream<http:SseEvent, error?>|Error {
        // The exact-match operations dispatch by [method, path] equality; the
        // rest below need startsWith/endsWith/includes on the path, which a
        // match pattern can't express, so they stay as guarded `if`s.
        match [method, path] {
            ["POST", "/message:send"] => {
                return self.onSendMessage(tenant, req);
            }
            ["POST", "/message:stream"] => {
                return self.onSendStreamingMessage(tenant, req);
            }
            ["GET", "/extendedAgentCard"] => {
                return jsonResponse((check self.handler.getExtendedAgentCard()).toJson());
            }
            ["GET", "/tasks"] => {
                ListTasksRequest filter = queryToListFilter(req);
                // TODO(owner scoping): () until per-request resolution is wired in.
                return jsonResponse((check self.handler.listTasks(filter, ())).toJson());
            }
        }

        if method == "POST" && path.startsWith(TASKS_PATH_PREFIX) && path.endsWith(":cancel") {
            string id = path.substring(TASKS_PATH_PREFIX.length(), path.length() - ":cancel".length());
            // TODO(owner scoping): () until per-request resolution is wired in.
            return jsonResponse((check self.handler.cancelTask({id}, ())).toJson());
        }
        // The proto's own annotation is GET, but the client falls back to
        // POST on a 404 -- a compat workaround for a non-reference server
        // that only registered POST here (mirroring the reference *client*,
        // which sends POST) -- and 404 is also what a genuinely-unknown
        // task's TaskNotFoundError carries. Accepting POST here too means
        // that fallback still reaches the real handler and surfaces the
        // correct typed error, rather than a second, unrelated 404 for "no
        // such route" masking the first.
        if (method == "GET" || method == "POST") && path.startsWith(TASKS_PATH_PREFIX) && path.endsWith(":subscribe") {
            string id = path.substring(TASKS_PATH_PREFIX.length(), path.length() - ":subscribe".length());
            return self.onSubscribeToTask(id);
        }
        if path.includes(PUSH_NOTIFICATION_CONFIGS_SEGMENT) {
            return self.onPushNotificationConfigs(method, path, req);
        }
        if method == "GET" && path.startsWith(TASKS_PATH_PREFIX) && !path.includes(":")
                && !path.includes(PUSH_NOTIFICATION_CONFIGS_SEGMENT) {
            string id = path.substring(TASKS_PATH_PREFIX.length());
            int? historyLength = queryInt(req, "historyLength");
            // TODO(owner scoping): () until per-request resolution is wired in.
            return jsonResponse((check self.handler.getTask({id, historyLength}, ())).toJson());
        }
        string msg = string `no A2A operation at ${method} ${path}`;
        return error InternalError(msg, message = msg, code = http:STATUS_NOT_FOUND);
    }

    # Handles POST /message:send: decode the request, run onMessage through
    # the default handler, and serialise the Task or Message it returns.
    #
    # + tenant - The matched tenant, or `()`
    # + req - The HTTP request
    # + return - The response, or an error
    private isolated function onSendMessage(string? tenant, http:Request req) returns http:Response|Error {
        json|error payload = req.getJsonPayload();
        if payload is error {
            return invalidAgentResponse(string `request body is not valid JSON: ${payload.message()}`);
        }
        SendMessageRequest|error request = payload.cloneWithType(SendMessageRequest);
        if request is error {
            return invalidAgentResponse(
                    string `request body did not match SendMessageRequest: ${request.message()}`);
        }
        // TODO(owner scoping): () until per-request resolution is wired in.
        Task|Message result = check self.handler.sendMessage(request, tenant, ());
        // The wire wraps the result in its oneof arm, matching what the client
        // decodes: {"task": ...} or {"message": ...}.
        string arm = result is Task ? "task" : "message";
        json|error wired = encodeRawBytesForWire(result.toJson());
        if wired is error {
            return wrapTransportError(wired);
        }
        return jsonResponse({[arm]: wired});
    }

    # Handles POST /message:stream: decode the request, run onMessage through
    # the default handler, and frame every event it produced as SSE.
    #
    # + tenant - The matched tenant, or `()`
    # + req - The HTTP request
    # + return - The SSE stream, or an error
    private isolated function onSendStreamingMessage(string? tenant, http:Request req)
            returns stream<http:SseEvent, error?>|Error {
        if !self.card.capabilities.streaming {
            return serverStreamingUnsupportedError("sendStreamingMessage");
        }
        json|error payload = req.getJsonPayload();
        if payload is error {
            return invalidAgentResponse(string `request body is not valid JSON: ${payload.message()}`);
        }
        SendMessageRequest|error request = payload.cloneWithType(SendMessageRequest);
        if request is error {
            return invalidAgentResponse(
                    string `request body did not match SendMessageRequest: ${request.message()}`);
        }
        // TODO(owner scoping): () until per-request resolution is wired in.
        StreamResponse[] events = check self.handler.sendStreamingMessage(request, tenant, ());
        return check eventsToSseStream(events);
    }

    # Handles GET /tasks/{id}:subscribe: the task's current state, as a
    # one-event SSE stream. See `DefaultHandler.subscribeToTask` for why this
    # release's stream is always exactly that one event.
    #
    # + id - The task id
    # + return - The SSE stream, or an error
    private isolated function onSubscribeToTask(string id) returns stream<http:SseEvent, error?>|Error {
        if !self.card.capabilities.streaming {
            return serverStreamingUnsupportedError("subscribeToTask");
        }
        // TODO(owner scoping): () until per-request resolution is wired in.
        StreamResponse[] events = check self.handler.subscribeToTask({id}, ());
        return check eventsToSseStream(events);
    }

    # Routes one of the four push-notification config operations, all under
    # `/tasks/{taskId}/pushNotificationConfigs[/{id}]`: POST (create) and GET
    # (list) on the collection path; GET (get) and DELETE (delete) on the
    # item path.
    #
    # + method - The HTTP method
    # + path - The path with no tenant prefix, already known to contain
    #          "/pushNotificationConfigs"
    # + req - The HTTP request
    # + return - The response, or an error to serialise
    private isolated function onPushNotificationConfigs(string method, string path, http:Request req)
            returns http:Response|Error {
        int marker = <int>path.indexOf(PUSH_NOTIFICATION_CONFIGS_SEGMENT);
        string taskId = path.substring(TASKS_PATH_PREFIX.length(), marker);
        string rest = path.substring(marker + PUSH_NOTIFICATION_CONFIGS_SEGMENT.length());

        if rest == "" && method == "POST" {
            return self.onCreateTaskPushNotificationConfig(taskId, req);
        }
        if rest == "" && method == "GET" {
            return self.onListTaskPushNotificationConfigs(taskId, req);
        }
        if rest.startsWith("/") && method == "GET" {
            return jsonResponse(
                    (check self.handler.getTaskPushNotificationConfig({taskId, id: rest.substring(1)})).toJson());
        }
        if rest.startsWith("/") && method == "DELETE" {
            check self.handler.deleteTaskPushNotificationConfig({taskId, id: rest.substring(1)});
            return jsonResponse({});
        }
        string msg = string `no A2A operation at ${method} ${path}`;
        return error InternalError(msg, message = msg, code = http:STATUS_NOT_FOUND);
    }

    # Handles POST /tasks/{taskId}/pushNotificationConfigs: decode the
    # config, stamp its `taskId` from the path, and register it.
    #
    # + taskId - The parent task id, from the path
    # + req - The HTTP request
    # + return - The stored config, or an error
    private isolated function onCreateTaskPushNotificationConfig(string taskId, http:Request req)
            returns http:Response|Error {
        json|error payload = req.getJsonPayload();
        if payload is error {
            return invalidAgentResponse(string `request body is not valid JSON: ${payload.message()}`);
        }
        map<json>|error asMap = payload.ensureType();
        if asMap is error {
            return invalidAgentResponse("request body is not a JSON object");
        }
        asMap["taskId"] = taskId;
        TaskPushNotificationConfig|error request = asMap.cloneWithType(TaskPushNotificationConfig);
        if request is error {
            return invalidAgentResponse(
                    string `request body did not match TaskPushNotificationConfig: ${request.message()}`);
        }
        return jsonResponse((check self.handler.createTaskPushNotificationConfig(request)).toJson());
    }

    # Handles GET /tasks/{taskId}/pushNotificationConfigs: list every config
    # registered for the task, with optional pagination query params.
    #
    # + taskId - The parent task id, from the path
    # + req - The HTTP request
    # + return - The page of configs, or an error
    private isolated function onListTaskPushNotificationConfigs(string taskId, http:Request req)
            returns http:Response|Error {
        ListTaskPushNotificationConfigsRequest request = {taskId};
        int? pageSize = queryInt(req, "pageSize");
        if pageSize is int {
            request.pageSize = pageSize;
        }
        string? pageToken = req.getQueryParamValue("pageToken");
        if pageToken is string {
            request.pageToken = pageToken;
        }
        return jsonResponse((check self.handler.listTaskPushNotificationConfigs(request)).toJson());
    }
}

# Builds the server-side rejection for a streaming operation called against
# a card that does not declare `capabilities.streaming`. Distinct from
# `operations.bal`'s client-side `streamingUnsupportedError`, which rejects
# before a request is even sent; this one is what a client sees on the wire
# when it sends one anyway.
#
# + operation - The operation name, for the message
# + return - The typed error
isolated function serverStreamingUnsupportedError(string operation) returns UnsupportedOperationError {
    string msg = string `${operation}: this agent's capabilities.streaming is false`;
    return error UnsupportedOperationError(msg, message = msg, code = -32004);
}

# Wraps one already-computed `StreamResponse` value into the oneof-envelope
# JSON shape the client's `decodeStreamResponseEnvelope` reads:
# `{"task": ...}`, `{"message": ...}`, `{"statusUpdate": ...}`, or
# `{"artifactUpdate": ...}`.
#
# + value - The event to wire-encode
# + return - The enveloped JSON, or an error if `encodeRawBytesForWire` failed
isolated function wireEnvelopeFor(StreamResponse value) returns json|error {
    string arm;
    if value is Task {
        arm = "task";
    } else if value is Message {
        arm = "message";
    } else if value is TaskStatusUpdateEvent {
        arm = "statusUpdate";
    } else {
        arm = "artifactUpdate";
    }
    json wired = check encodeRawBytesForWire(value.toJson());
    return {[arm]: wired};
}

# Frames a pre-computed `StreamResponse` list as an SSE event stream, in
# order. Used by both `sendStreamingMessage` and `subscribeToTask` -- this
# release computes the whole event sequence before the SSE response opens
# (see `DefaultHandler.sendStreamingMessage`), so there is nothing left to
# generate lazily: each event is wire-encoded up front and the resulting
# array is what a one-element array's `singleEventStream` does on the
# client side, just with more than one element.
#
# + events - The events to frame, in order
# + return - The SSE stream, or an error if any event failed to wire-encode
isolated function eventsToSseStream(StreamResponse[] events) returns stream<http:SseEvent, error?>|Error {
    http:SseEvent[] sseEvents = [];
    foreach StreamResponse event in events {
        json|error envelope = wireEnvelopeFor(event);
        if envelope is error {
            return wrapTransportError(envelope);
        }
        sseEvents.push({data: envelope.toJsonString()});
    }
    return sseEvents.toStream();
}

# Reads the tenant a card declares on its HTTP+JSON interface, or `()`.
#
# + card - The agent card
# + return - The declared tenant, or `()` if the interface declares none
isolated function declaredTenant(AgentCard card) returns string? {
    foreach AgentInterface iface in card.supportedInterfaces {
        if iface.protocolBinding == HTTP_JSON {
            return iface?.tenant;
        }
    }
    return;
}

# Builds a JSON 200 response.
#
# + body - The JSON body
# + return - The response
isolated function jsonResponse(json body) returns http:Response {
    http:Response response = new;
    response.setJsonPayload(body);
    return response;
}

# Reads an integer query parameter, or `()` if absent or unparseable.
#
# + req - The request
# + name - The parameter name
# + return - The integer value, or `()`
isolated function queryInt(http:Request req, string name) returns int? {
    string? raw = req.getQueryParamValue(name);
    if raw is () {
        return;
    }
    int|error parsed = int:fromString(raw);
    return parsed is int ? parsed : ();
}

# Builds a ListTasksRequest from the query string of a GET /tasks request.
#
# + req - The request
# + return - The filter
isolated function queryToListFilter(http:Request req) returns ListTasksRequest {
    ListTasksRequest filter = {};
    string? contextId = req.getQueryParamValue("contextId");
    if contextId is string {
        filter.contextId = contextId;
    }
    string? status = req.getQueryParamValue("status");
    if status is string {
        TaskState|error state = status.ensureType();
        if state is TaskState {
            filter.status = state;
        }
    }
    int? pageSize = queryInt(req, "pageSize");
    if pageSize is int {
        filter.pageSize = pageSize;
    }
    string? pageToken = req.getQueryParamValue("pageToken");
    if pageToken is string {
        filter.pageToken = pageToken;
    }
    int? historyLength = queryInt(req, "historyLength");
    if historyLength is int {
        filter.historyLength = historyLength;
    }
    string? after = req.getQueryParamValue("statusTimestampAfter");
    if after is string {
        filter.statusTimestampAfter = after;
    }
    string? includeArtifacts = req.getQueryParamValue("includeArtifacts");
    if includeArtifacts is string {
        filter.includeArtifacts = includeArtifacts == "true";
    }
    return filter;
}
