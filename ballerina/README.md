## Overview

This module provides a Ballerina client and server for the [Agent2Agent (A2A) protocol](https://a2a-protocol.org/latest/specification/) v1.0, an open protocol for communication between independent AI agents.

A2A lets an agent discover what another agent can do, delegate work to it, and follow that work as it progresses. An agent publishes an Agent Card describing its skills, transports, and authentication requirements; a client reads that card and talks to the agent over the transport it declares.

It includes capabilities for:

1. **Connecting to an agent** – Discover an agent from its Agent Card and open a client against the transport it declares.
2. **Delegating work** – Send a message and receive either a direct reply or a long-running task to follow.
3. **Following progress** – Stream updates as they happen, or register a webhook and be called back.
4. **Authenticating** – Satisfy the security schemes an agent declares, per skill where they differ.
5. **Serving an agent** – Implement one method and publish it as an A2A agent, with the task lifecycle, streaming, and discovery handled for you.

The specification defines three transport bindings. This module implements **HTTP+JSON**, for both the client and the server; a card declaring only JSON-RPC or gRPC is rejected when the client is constructed, rather than at the first call.

## 1. Connecting to an agent

`HttpClient` is the type to reach for. Give it an agent's base URL and it fetches the Agent Card from the well-known endpoint, confirms the agent serves HTTP+JSON, and connects.

```ballerina
import ballerina/a2a;

final a2a:HttpClient agent = check new ("https://agent.example.com");
```

Construction is where a mismatch surfaces: an unreachable agent, a card that does not parse, or a card offering no binding this module speaks all fail here rather than on the first operation.

An `HttpClient` is cheap to construct and needs no teardown — there is deliberately no `close`. Prefer one long-lived client per agent over one per request.

This release implements HTTP+JSON only. When JSON-RPC and gRPC bindings land, a transport-agnostic `Client` that reads the card and picks a binding will join `HttpClient`; client code written against the operations will carry over unchanged.

### 1.1 Connecting from an already-resolved card

When you have already fetched the card — to inspect its skills before deciding to call it — hand it over directly and it is not fetched twice:

```ballerina
a2a:AgentCard card = check a2a:resolveAgentCard("https://agent.example.com");
final a2a:HttpClient agent = check new (card);
```

## 2. Delegating work

Every operation takes a single request record, matching the specification's own request messages. Optional fields are omitted rather than passed as nil.

`sendMessage` returns either a `Task` — work the agent has accepted and will continue — or a `Message`, a direct conversational reply with no task behind it:

```ballerina
public function main() returns error? {
    a2a:Task|a2a:Message reply = check agent->sendMessage({
        message: {
            messageId: "msg-1",
            role: a2a:ROLE_USER,
            parts: [{text: "What is the weather in Colombo?"}]
        }
    });

    if reply is a2a:Task {
        io:println("task ", reply.id, " is ", reply.status.state);
    } else if reply is a2a:Message {
        io:println("direct reply: ", reply.parts);
    }
}
```

> **Note:** Match each arm explicitly rather than relying on `else` to narrow. Every specification type in this module is an open record, so `else` after `is a2a:Task` leaves the value typed as the full union — the compiler will reject a field access there.

### 2.1 Message parts

A `Message` carries one or more parts. Exactly one of `text`, `raw`, `url`, or `data` is set on each — the variant is determined by which field is present, not by a discriminator field:

```ballerina
a2a:Message msg = {
    messageId: "msg-2",
    role: a2a:ROLE_USER,
    parts: [
        {text: "Summarise this report."},
        {raw: check io:fileReadBytes("report.pdf"), mediaType: "application/pdf"}
    ]
};
```

`raw` is `byte[]` in Ballerina and base64 on the wire; the conversion happens for you in both directions.

### 2.2 Following a task

`getTask` retrieves a task's current state. `historyLength` bounds how much conversation history comes back with it:

```ballerina
a2a:Task task = check agent->getTask({id: "task-1", historyLength: 10});
```

`cancelTask` asks the agent to stop. An agent that has already finished, or that does not allow cancellation, answers with `TaskNotCancelableError`:

```ballerina
a2a:Task canceled = check agent->cancelTask({id: "task-1"});
```

`listTasks` pages through tasks with a cursor. Every filter field is optional:

```ballerina
a2a:ListTasksResponse page = check agent->listTasks({
    status: a2a:TASK_STATE_WORKING,
    pageSize: 20
});

while page.nextPageToken != "" {
    page = check agent->listTasks({pageSize: 20, pageToken: page.nextPageToken});
}
```

## 3. Following progress

### 3.1 Streaming

`sendStreamingMessage` and `subscribeToTask` return a `stream<StreamResponse, error?>`. Each event is a `Task`, a `Message`, a `TaskStatusUpdateEvent`, or a `TaskArtifactUpdateEvent`. The stream closes on a terminal task state:

```ballerina
stream<a2a:StreamResponse, error?> events =
    check agent->sendStreamingMessage({message: msg});

check from a2a:StreamResponse event in events
    do {
        if event is a2a:TaskStatusUpdateEvent {
            io:println("state: ", event.status.state);
        } else if event is a2a:TaskArtifactUpdateEvent {
            io:println("artifact: ", event.artifact.artifactId);
        }
    };
```

`subscribeToTask` attaches to a task that is already running:

```ballerina
stream<a2a:StreamResponse, error?> events = check agent->subscribeToTask({id: "task-1"});
```

Pass `maxReconnectAttempts` to have a dropped connection resubscribe automatically:

```ballerina
final a2a:HttpClient agent = check new ("https://agent.example.com", maxReconnectAttempts = 3);
```

Per specification section 3.1.6 a resubscription replays the task's current state, so no event is lost across a reconnect — only possibly repeated. Callers already have to tolerate duplicate and out-of-order status updates, so this adds no new burden.

When the Agent Card says the agent does not support streaming, `sendStreamingMessage` degrades to a single unary call wrapped as a one-event stream instead of opening a connection the server would reject. `subscribeToTask` has no unary equivalent, so it fails with `UnsupportedOperationError`.

### 3.2 Push notifications

Rather than holding a stream open, register a webhook and let the agent call you back:

```ballerina
a2a:TaskPushNotificationConfig config = check agent->createTaskPushNotificationConfig({
    taskId: "task-1",
    url: "https://client.example.com/webhooks/a2a"
});
```

The server assigns the config an `id`, which is what the other three operations address it by. It is optional on the record, since a caller does not supply one when creating:

```ballerina
a2a:ListTaskPushNotificationConfigsResponse configs =
    check agent->listTaskPushNotificationConfigs({taskId: "task-1"});

string? configId = config?.id;
if configId is string {
    check agent->deleteTaskPushNotificationConfig({taskId: "task-1", id: configId});
}
```

Deletion is idempotent per specification section 3.1.10.

## 4. Authenticating

### 4.1 Standard transport authentication

OAuth2, JWT, mutual TLS, and HTTP basic or bearer are configured through `clientConfig`, which is a standard `http:ClientConfiguration`. Token exchange and refresh are handled by `ballerina/oauth2` and `ballerina/jwt` as usual:

```ballerina
final a2a:HttpClient agent = check new ("https://agent.example.com", clientConfig = {
    auth: {
        tokenUrl: "https://auth.example.com/oauth2/token",
        clientId: "...",
        clientSecret: "..."
    }
});
```

### 4.2 Credentials by security-scheme name

An agent can declare several schemes, and a client may hold a different credential for each — two bearer tokens on one agent, say, which a single `headers` map cannot express. For schemes that reduce to one header value, supply a `CredentialProvider`. It is consulted per request and keyed by the scheme name the Agent Card uses:

```ballerina
final a2a:InMemoryCredentialStore store = new ({
    "staffAuth": "eyJhbGciOi...",
    "apiKeyAuth": "sk-..."
});

final a2a:HttpClient agent = check new ("https://agent.example.com", credentials = store);
```

Implement `CredentialProvider` yourself to source credentials from wherever they actually live — a vault, a config file, a per-session store. Returning `()` is normal and not an error: the request is sent without that credential and the agent decides how to respond.

### 4.3 Skill-level requirements

A skill can require more than the agent as a whole does. `AgentSkill.securityRequirements` carries what a given skill asks for, and an empty list means it inherits the card's:

```ballerina
foreach a2a:AgentSkill skill in card.skills {
    if skill.id == "adjust-payroll" {
        io:println(skill.securityRequirements);
    }
}
```

When an agent needs authorization it cannot obtain itself, it parks the task in `TASK_STATE_AUTH_REQUIRED` and attaches a status message explaining what it needs (specification section 7.6):

```ballerina
if task.status.state == a2a:TASK_STATE_AUTH_REQUIRED {
    a2a:Message? prompt = task.status?.message;
    // surface the prompt to whoever can satisfy it, then resume
}
```

## 5. Inspecting a card

`resolveAgentCard` fetches and parses a card without constructing a client — useful for inspecting an agent's skills before deciding to call it:

```ballerina
a2a:AgentCard card = check a2a:resolveAgentCard("https://agent.example.com");
foreach a2a:AgentSkill skill in card.skills {
    io:println(skill.id, ": ", skill.description);
}
```

A card may carry `signatures` (specification section 8.4). They are parsed onto the card but not verified: section 8.4.3's procedure needs a public key only you can supply. Verifying a signature also has to run over the raw body rather than a parsed record, since a record carries defaults the signer never sent; raw-body signature verification is out of scope for this release.

### 5.1 The extended Agent Card

An agent may publish a fuller card to authenticated callers — additional skills, or detail withheld from the public one:

```ballerina
a2a:AgentCard extended = check agent->getExtendedAgentCard();
```

When the held card declares no extended-card support this fails with `UnsupportedOperationError` rather than silently handing back the public card you already had, as specification section 3.3.4 requires.

## 6. Errors

Every operation returns a narrowed `Error`. The nine error types of specification section 5.4 are each a distinct subtype, so a caller matches on the condition rather than on a code:

```ballerina
a2a:Task|a2a:Error result = agent->getTask({id: "task-1"});

if result is a2a:TaskNotFoundError {
    // the agent does not know this task
} else if result is a2a:Error {
    io:println(result.message());
}
```

The nine are `TaskNotFoundError`, `TaskNotCancelableError`, `UnsupportedOperationError`, `ContentTypeNotSupportedError`, `InvalidAgentResponseError`, `VersionNotSupportedError`, `PushNotificationNotSupportedError`, `ExtendedAgentCardNotConfiguredError`, and `ExtensionSupportRequiredError`.

Anything the protocol does not name — a dropped connection, a malformed body, a response that does not match its declared shape, or a precondition this client checks before sending — surfaces as `InternalError`. No operation returns a bare, unmatchable `error`.

## 7. Serving an Agent

```ballerina
import ballerina/a2a;
import ballerina/io;

listener a2a:Listener agent = new (9090, agentCard = {
    name: "Weather Agent",
    description: "Answers weather questions",
    version: "1.0.0",
    skills: [{id: "forecast", name: "Forecast", description: "Multi-day forecasts", tags: ["weather"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
});

isolated service class WeatherAgent {
    *a2a:Service;

    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        check updater->working();
        check updater->addArtifact([{text: "Sunny, 22°C"}]);
        check updater->complete();
        return ();
    }
}

function init() returns error? {
    check agent.attach(new WeatherAgent());
    io:println("Weather Agent listening on :9090");
}
```

Declare the listener at module level: a listener declared inside `main` does not keep the program alive. `capabilities` and `supportedInterfaces` on the card are placeholders; the listener replaces both with what it actually serves, so the published card can never advertise something the server does not do.

One method, `onMessage`, is the entire agent. The listener runs the rest of the protocol around it: `getTask`, `cancelTask` and `listTasks` over the task `onMessage` created; `sendStreamingMessage` and `subscribeToTask` as Server-Sent Events; the push-notification configuration operations; the well-known discovery endpoint; and version and capability gating. Errors are serialized exactly as the client half of this module decodes them, so this module's `HttpClient` can be pointed at its own `Listener`. Only HTTP+JSON at protocol version 1.0 is served in this release.

### 7.1 Driving a task

`a2a:TaskUpdater` moves a long-running task through its states from inside `onMessage`:

```ballerina
check updater->working();
check updater->addArtifact([{text: "partial result"}]);
check updater->requireInput(promptMessage);
check updater->complete();
```

`requireInput` pauses the task at `TASK_STATE_INPUT_REQUIRED`; a later message continuing the same task (see [section 7.2](#72-live-streaming-and-continuing-a-task)) runs `onMessage` again. Every call is persisted through the attached `a2a:TaskStore`. `requireAuth` is the same shape as `requireInput`, for a task that needs the caller to authorize.

`onMessage` runs detached from the request that started it, so a slow or long-running agent never blocks a separate `subscribeToTask` call from attaching to the same task's events as they happen. A panic in `onMessage` is caught and transitions the task to `TASK_STATE_FAILED` with the panic's message, the same as returning an `a2a:Error` does -- neither crashes the server or strands the task at whatever state it was left in.

### 7.2 Live streaming and continuing a task

`sendStreamingMessage` and `subscribeToTask` both return a live stream: events arrive as `onMessage` produces them, not replayed after the fact. Two callers following the same task -- a `sendStreamingMessage` caller and a later `subscribeToTask` caller, or several `subscribeToTask` callers -- each see every event from the point they attached, in the same order; closing one stream does not affect another (specification section 3.5.2). `subscribeToTask` on a task already in a terminal state is `UnsupportedOperationError`, not a snapshot -- there is nothing further it could ever stream (specification section 3.1.6).

A client continues an existing, non-terminal task by setting `message.taskId` on a later `sendMessage`/`sendStreamingMessage` call:

```ballerina
a2a:Task|a2a:Message reply = check agent->sendMessage({
    message: {
        messageId: "msg-2",
        role: a2a:ROLE_USER,
        taskId: pausedTask.id,
        contextId: pausedTask.contextId,
        parts: [{text: "here is the information you asked for"}]
    }
});
```

`onMessage` runs again against the same task, with the continuing message appended to its `history`. An unrecognized `taskId` is `TaskNotFoundError` -- a client cannot name a new task into existence this way (specification section 3.4.2); a `contextId` that disagrees with the task's own is rejected; a task already terminal cannot be continued (`UnsupportedOperationError`), the same rejection a second concurrent message to a task still being driven gets. Any non-terminal state can be continued, not only `TASK_STATE_INPUT_REQUIRED`/`TASK_STATE_AUTH_REQUIRED`.

`sendMessage`'s default behavior is unchanged: it blocks until the task reaches a terminal or interrupted state, or `onMessage` replies with a direct `a2a:Message`. Set `configuration.returnImmediately: true` to instead get the task back as soon as it exists, without waiting:

```ballerina
a2a:Task submitted = <a2a:Task>check agent->sendMessage({
    message: {messageId: "msg-1", role: a2a:ROLE_USER, parts: [{text: "start this"}]},
    configuration: {returnImmediately: true}
});
```

`onMessage` keeps running detached either way. This removes the implicit backpressure a blocking `sendMessage` gave for free -- every concurrent task used to hold a worker for its full duration -- so a deployment expecting many concurrent long-running tasks under `returnImmediately: true` should plan capacity accordingly. `returnImmediately` has no effect on `sendStreamingMessage`, which already runs detached and streams live regardless (specification's own text); if `onMessage` replies with a direct `a2a:Message` under `returnImmediately: true`, the caller already holds the task's id from the immediate-return snapshot, so the task completes with that `a2a:Message` as its final `status.message` instead of the task disappearing as if it never existed.

`streamIdleTimeout` on `ListenerConfiguration` (default 300 seconds) bounds how long a live stream may sit with no event before the server ends it -- the backstop for a client that disconnects without the transport surfacing it as a clean close.

### 7.3 Task storage

```ballerina
listener a2a:Listener agent = new (9090, agentCard = card, taskStore = new MyDatabaseTaskStore());
```

`a2a:InMemoryTaskStore` is the default, and its tasks do not survive a restart. Implement `a2a:TaskStore` (`put`, `get`, `list`, `remove`) to back an agent with real storage. `list` must sort by status timestamp, newest first, and omit `artifacts` unless asked.

### 7.4 The extended Agent Card

```ballerina
listener a2a:Listener agent = new (9090, agentCard = publicCard, extendedAgentCard = richerCard);
```

Left unset, `capabilities.extendedAgentCard` is `false` and a request for it fails with `UnsupportedOperationError`. Configuring one flips the capability on and serves the card from `GET /extendedAgentCard`.

Specification section 13.3 requires this operation specifically to require authentication — more pointedly than the general punt in [section 7.6](#76-task-ownership-and-authorization-scoping): an extended card exists to reveal information the *public* card deliberately doesn't, so an unauthenticated deployment of this endpoint defeats its own purpose, not just the general authorization scoping other operations lose without a resolver. This listener has no request-time authentication mechanism of its own — same as every other operation — so putting one in front of `GET /extendedAgentCard` specifically (not just gating who can *see* which tasks, which `TaskOwnerResolver` already does) is the deploying operator's responsibility.

### 7.5 Push notifications

An agent can register, read, list and remove a task's webhook configuration, and this listener actually calls it: whenever a task it drives reaches a new state — including cancellation — every webhook registered for that task gets a POST of the task's current state as a `StreamResponse` — `{"task": {...}}`, the same shape a stream carries (specification section 4.3.3), with media type `application/a2a+json`. Delivery is fire-and-forget: a webhook that is unreachable or errors does not fail the operation that triggered it.

A client registers a webhook one of two ways. Inline, attached to a `sendMessage`/`sendStreamingMessage` call — the only channel that works before a task's id is even known, since a config normally has to name an existing `taskId`:

```ballerina
a2a:Task|a2a:Message reply = check agent->sendMessage({
    message: {messageId: "msg-1", role: a2a:ROLE_USER, parts: [{text: "..."}]},
    configuration: {
        taskPushNotificationConfig: {url: "https://client.example.com/webhooks/a2a"}
    }
});
```

Or explicitly, once a `taskId` is already known — the register/read/list/remove operations from [section 3.2](#32-push-notifications):

```ballerina
a2a:TaskPushNotificationConfig config = check agent->createTaskPushNotificationConfig({
    taskId: "task-1",
    url: "https://client.example.com/webhooks/a2a"
});
```

`config.token`, if set, is echoed back as the `X-A2A-Notification-Token` header on every delivery, for correlation. `config.authentication`, if set, becomes a standard `Authorization: <scheme> <credentials>` header on the outbound call.

Delivery uses `a2a:HttpPushNotificationSender` by default, an HTTP POST with a configurable timeout. It rejects a webhook URL that is not `http`/`https`, or whose host is a loopback, link-local, private (RFC 1918), carrier-grade-NAT, or otherwise non-public address — specification section 13.2's SSRF-protection obligation — before ever connecting:

```ballerina
listener a2a:Listener agent = new (9090, agentCard = card,
    pushSender = new a2a:HttpPushNotificationSender({validateUrl: false, timeout: 5}));
```

`validateUrl: false` is the escape hatch a deployment with a legitimately internal webhook host needs. The check is by URL form, not by resolving the hostname — a name that only resolves to a private address at connect time (DNS rebinding) is not caught; supply your own `a2a:PushNotificationSender` to close that gap with whatever resolution your deployment trusts.

Streaming and push notifications are always *implemented* by this listener, but each is only *advertised* — and accepted — when its `ListenerConfiguration` flag is left at its `true` default:

```ballerina
listener a2a:Listener agent = new (9090, agentCard = card,
    streamingCapability = false, pushNotificationsCapability = false);
```

Set one `false` when a deployment deliberately wants to withhold that capability — no outbound network access for webhooks, an operator policy against it, whatever the reason. The served card then declares `capabilities.streaming`/`capabilities.pushNotifications` as `false`, and the corresponding operations are rejected server-side (`UnsupportedOperationError` / `PushNotificationNotSupportedError`) exactly as if this listener had never implemented them — never a card that quietly claims something the server then refuses.

### 7.6 Task ownership and authorization scoping

Specification section 13.1 requires that "clients can only access authorized tasks." By default this listener does not enforce that — every task is visible to every caller, in one shared pool. Supply a `TaskOwnerResolver` to change that:

```ballerina
isolated class BearerOwnerResolver {
    *a2a:TaskOwnerResolver;

    public isolated function resolveOwner(http:Request req) returns string?|a2a:Error {
        // Resolve identity however your deployment actually authenticates a
        // caller -- a bearer token's subject claim, an mTLS principal, an
        // API key lookup. This example assumes something upstream already
        // verified the token; a resolver that trusts an unverified header
        // is not a security boundary.
        string|http:HeaderNotFoundError subject = req.getHeader("X-Verified-Subject");
        return subject is string ? subject : ();
    }
}

listener a2a:Listener agent = new (9090, agentCard = card, ownerResolver = new BearerOwnerResolver());
```

Once configured, `getTask`, `cancelTask`, `listTasks`, `subscribeToTask`, and the four push-notification config operations all become owner-scoped: a task, or a task's push configs, created under one resolved owner are invisible to every other owner — indistinguishable from not existing at all, per the same section's requirement that a server "MUST NOT reveal the existence of resources the client is not authorized to access." `TaskUpdater` stamps every write with the owner the task was created under, so an agent's own driven updates stay in the right scope automatically.

`()` — an unauthenticated caller, or simply no resolver configured — is its own scope, not a wildcard: every caller a resolver maps to `()` shares one pool, isolated from every named owner but not from each other. A resolver alone does not make an agent safe against anonymous traffic; pair it with real inbound authentication, which is deployment policy this module does not prescribe.
