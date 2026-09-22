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

// The server's strongest single check: this library's own Client driving
// this library's own Listener, in one process. If the two halves disagree on
// any part of the wire, this fails.
//
// One listener for the whole suite (a port cannot host two), started in
// @test:BeforeSuite and stopped in @test:AfterSuite.

import ballerina/http;
import ballerina/test;

const int SERVER_TEST_PORT = 19234;
final string serverUrl = string `http://localhost:${SERVER_TEST_PORT}`;

listener Listener echoListener = new (SERVER_TEST_PORT, agentCard = {
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    // Placeholders: the listener derives both from what it serves.
    capabilities: {},
    supportedInterfaces: []
});

// A second listener, on its own port, configured with an extended card --
// separate from echoListener so that one's own extendedAgentCard:false
// round trip (the common case: no extended card configured) stays
// unambiguous. Both listeners are attached to instances of the same
// EchoAgent; only the configuration differs.
const int EXTENDED_CARD_TEST_PORT = 19235;
final string extendedCardServerUrl = string `http://localhost:${EXTENDED_CARD_TEST_PORT}`;

listener Listener extendedCardListener = new (EXTENDED_CARD_TEST_PORT, agentCard = {
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
}, extendedAgentCard = {
    name: "Echo Agent (extended)",
    description: "Echoes its input -- extended card reveals an internal-only skill",
    version: "1.0.0",
    skills: [
        {id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]},
        {id: "debug", name: "Debug", description: "Internal-only diagnostics", tags: ["internal"]}
    ],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
});

// A minimal agent: echoes the inbound text back as a completed task's
// artifact, unless the text is "ping", which gets a direct Message reply.
isolated service class EchoAgent {
    *Service;

    isolated remote function onMessage(RequestContext context, TaskUpdater updater)
            returns Message|Error? {
        string text = "";
        foreach Part part in context.message.parts {
            string? t = part?.text;
            if t is string {
                text += t;
            }
        }
        if text == "ping" {
            return {messageId: "reply-1", role: ROLE_AGENT, parts: [{text: "pong"}]};
        }
        check updater->working();
        check updater->addArtifact([{text: string `echo: ${text}`}]);
        check updater->complete();
        return;
    }
}

@test:BeforeSuite
function startEchoServer() returns error? {
    check echoListener.attach(new EchoAgent());
    check extendedCardListener.attach(new EchoAgent());
}

isolated function echoClient() returns HttpClient|error => new (serverUrl);

@test:Config {}
function testServerServesAgentCardForClientDiscovery() returns error? {
    AgentCard card = check resolveAgentCard(serverUrl);
    test:assertEquals(card.name, "Echo Agent");
    test:assertEquals(card.supportedInterfaces.length(), 1);
    test:assertEquals(card.supportedInterfaces[0].protocolBinding, "HTTP+JSON",
            "the served card must declare the HTTP+JSON interface");
    test:assertEquals(card.supportedInterfaces[0].protocolVersion, "1.0");
    test:assertTrue(card.capabilities.streaming,
            "streaming is wired, so the derived card must claim it");
}

@test:Config {}
function testServerRoundTripSendMessageReturnsTask() returns error? {
    Client c = check echoClient();
    Task|Message reply = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(reply is Task, "a non-ping message must come back as a completed task");
    Task task = <Task>reply;
    test:assertEquals(task.status.state, TASK_STATE_COMPLETED);
    Artifact[] artifacts = task.artifacts ?: [];
    test:assertEquals(artifacts.length(), 1);
    test:assertEquals(artifacts[0].parts[0]?.text, "echo: hello");
}

@test:Config {}
function testServerRoundTripDirectMessageReply() returns error? {
    Client c = check echoClient();
    Task|Message reply = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "ping"}]}
    });
    test:assertTrue(reply is Message, "\"ping\" must come back as a direct Message, not a Task");
    test:assertEquals((<Message>reply).parts[0]?.text, "pong");
}

@test:Config {}
function testServerRoundTripGetTask() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "remember me"}]}
    });
    Task fetched = check c->getTask({id: created.id});
    test:assertEquals(fetched.id, created.id, "getTask must return the task sendMessage created");
    test:assertEquals(fetched.status.state, TASK_STATE_COMPLETED);
}

@test:Config {}
function testServerRoundTripGetUnknownTaskIsTyped() returns error? {
    Client c = check echoClient();
    Task|Error result = c->getTask({id: "does-not-exist"});
    test:assertTrue(result is TaskNotFoundError,
            "an unknown task must round-trip as a2a:TaskNotFoundError through the google.rpc.Status body");
}

@test:Config {}
function testServerRoundTripCancelTask() returns error? {
    Client c = check echoClient();
    // The echo agent completes synchronously, so the task is already terminal;
    // canceling it must be refused as TaskNotCancelableError.
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "done fast"}]}
    });
    Task|Error canceled = c->cancelTask({id: created.id});
    test:assertTrue(canceled is TaskNotCancelableError,
            "a completed task cannot be canceled; the server must say so");
}

@test:Config {}
function testServerRoundTripSendStreamingMessage() returns error? {
    Client c = check echoClient();
    stream<StreamResponse, error?> events = check c->sendStreamingMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "stream me"}]}
    });

    StreamResponse first = check expectStreamValue(events);
    test:assertTrue(first is Task, "the first event must be the newly created task");
    test:assertEquals((<Task>first).status.state, TASK_STATE_SUBMITTED);
    string taskId = (<Task>first).id;

    StreamResponse second = check expectStreamValue(events);
    test:assertTrue(second is TaskStatusUpdateEvent, "the second event must be the WORKING status");
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_WORKING);
    test:assertEquals((<TaskStatusUpdateEvent>second).taskId, taskId);

    StreamResponse third = check expectStreamValue(events);
    test:assertTrue(third is TaskArtifactUpdateEvent, "the third event must be the echoed artifact");
    test:assertEquals((<TaskArtifactUpdateEvent>third).artifact.parts[0]?.text, "echo: stream me");
    test:assertTrue((<TaskArtifactUpdateEvent>third).lastChunk,
            "a whole-artifact addArtifact call is its own last chunk");

    StreamResponse fourth = check expectStreamValue(events);
    test:assertTrue(fourth is TaskStatusUpdateEvent, "the fourth event must be the COMPLETED status");
    test:assertEquals((<TaskStatusUpdateEvent>fourth).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? fifth = events.next();
    test:assertTrue(fifth is (), "the stream must close after the terminal status");
}

@test:Config {}
function testServerRoundTripSendStreamingMessageDirectReply() returns error? {
    Client c = check echoClient();
    stream<StreamResponse, error?> events = check c->sendStreamingMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "ping"}]}
    });

    StreamResponse first = check expectStreamValue(events);
    test:assertTrue(first is Message, "a direct reply must be the stream's one and only event");
    test:assertEquals((<Message>first).parts[0]?.text, "pong");

    record {| StreamResponse value; |}|error? second = events.next();
    test:assertTrue(second is (), "the stream must close immediately after the one Message event");
}

@test:Config {}
function testServerRoundTripSubscribeToTask() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "subscribe me"}]}
    });

    stream<StreamResponse, error?> events = check c->subscribeToTask({id: created.id});
    StreamResponse first = check expectStreamValue(events);
    test:assertTrue(first is Task, "subscribeToTask's first event must be the task's current state");
    test:assertEquals((<Task>first).id, created.id);
    test:assertEquals((<Task>first).status.state, TASK_STATE_COMPLETED);

    record {| StreamResponse value; |}|error? second = events.next();
    test:assertTrue(second is (),
            "the echo agent always finishes inside its own sendMessage call, so a subsequent " +
            "subscribeToTask only ever sees a terminal snapshot and the stream closes immediately");
}

@test:Config {}
function testServerRoundTripSubscribeToUnknownTaskIsTyped() returns error? {
    Client c = check echoClient();
    stream<StreamResponse, error?>|Error result = c->subscribeToTask({id: "does-not-exist"});
    test:assertTrue(result is TaskNotFoundError,
            "an unknown task must round-trip as a2a:TaskNotFoundError through the google.rpc.Status body");
}

isolated function expectStreamValue(stream<StreamResponse, error?> events) returns StreamResponse|error {
    record {| StreamResponse value; |}|error? result = events.next();
    if result is error {
        return result;
    }
    if result is () {
        return error("expected a value but the stream ended");
    }
    return result.value;
}

@test:Config {}
function testServerRoundTripListTasks() returns error? {
    Client c = check echoClient();
    Task|Message _ = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "one"}]}
    });
    Task|Message _ = check c->sendMessage({
        message: {messageId: "m2", role: ROLE_USER, parts: [{text: "two"}]}
    });
    ListTasksResponse page = check c->listTasks({pageSize: 10});
    test:assertTrue(page.totalSize >= 2, "listTasks must see the tasks that were created");
    test:assertEquals(page.nextPageToken, "", "a full page must end with an empty nextPageToken");
}

// ---- extended Agent Card ------------------------------------------------

@test:Config {}
function testServerRoundTripGetExtendedAgentCardWhenNotConfigured() returns error? {
    // echoListener has no extendedAgentCard configured, so its served card
    // declares capabilities.extendedAgentCard: false, and the Client refuses
    // client-side rather than sending a request the server would also
    // refuse -- specification section 3.3.4's MUST-fail is honoured on both
    // sides of the wire, just at different points.
    Client c = check echoClient();
    AgentCard|Error result = c->getExtendedAgentCard();
    test:assertTrue(result is UnsupportedOperationError,
            "a card declaring no extended-card support must refuse client-side, not send a doomed request");
}

@test:Config {}
function testServerRoundTripGetExtendedAgentCardWhenConfigured() returns error? {
    HttpClient c = check new (extendedCardServerUrl);
    AgentCard extended = check c->getExtendedAgentCard();
    test:assertEquals(extended.name, "Echo Agent (extended)");
    test:assertEquals(extended.skills.length(), 2, "the extended card reveals the internal-only skill too");
}

@test:Config {}
function testDefaultHandlerGetExtendedAgentCardFailsWhenNoneConfigured() returns error? {
    // Direct unit test, not a wire round trip: deriveServedCard ties
    // capabilities.extendedAgentCard to whether a card was configured, so
    // this error can never actually reach a Client through echoListener's
    // own wiring (the capability would already be false, and the Client
    // would have refused client-side, per the test above). The branch is
    // still real code for a future server built directly against
    // DefaultHandler without that same coupling, so it is exercised
    // directly here rather than left untested.
    TaskStore store = new InMemoryTaskStore();
    DefaultHandler handler = new (new EchoAgent(), store, ());
    AgentCard|Error result = handler.getExtendedAgentCard();
    test:assertTrue(result is ExtendedAgentCardNotConfiguredError,
            "no extended card configured must fail this specific way, not just any error");
}

// ---- push-notification config CRUD --------------------------------------
//
// capabilities.pushNotifications is always false in this release (config is
// stored, never delivered -- see deriveServedCard), so HttpClient
// refuse these four operations client-side, the same self-gate exercised
// above for the extended card. That is exactly the point of the capability
// staying false: a caller using this library's own client cannot even try
// to rely on delivery that will never happen. Proving the operations
// genuinely work server-side -- which they do, for any caller willing to
// speak the wire directly -- needs a plain http:Client instead.

isolated function pushConfigHttpClient() returns http:Client|error => new (serverUrl);

@test:Config {}
function testServerRoundTripPushNotificationConfigCrud() returns error? {
    http:Client raw = check pushConfigHttpClient();
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "needs a webhook"}]}
    });

    map<string> headers = {"A2A-Version": "1.0", "Content-Type": "application/json"};

    // Create.
    json createBody = {"url": "https://example.com/webhook", "token": "corr-1"};
    json createResult = check raw->post(
            string `/tasks/${created.id}/pushNotificationConfigs`, createBody, headers);
    TaskPushNotificationConfig config = check createResult.cloneWithType(TaskPushNotificationConfig);
    test:assertEquals(config.url, "https://example.com/webhook");
    string? configId = config?.id;
    test:assertTrue(configId is string, "the server must assign a config id on create");
    string id = <string>configId;

    // Get.
    json getResult = check raw->get(
            string `/tasks/${created.id}/pushNotificationConfigs/${id}`, headers);
    TaskPushNotificationConfig fetched = check getResult.cloneWithType(TaskPushNotificationConfig);
    test:assertEquals(fetched.id, id);
    test:assertEquals(fetched.token, "corr-1");

    // List.
    json listResult = check raw->get(
            string `/tasks/${created.id}/pushNotificationConfigs`, headers);
    ListTaskPushNotificationConfigsResponse page =
        check listResult.cloneWithType(ListTaskPushNotificationConfigsResponse);
    TaskPushNotificationConfig[] configs = page.configs ?: [];
    test:assertEquals(configs.length(), 1, "the config just created must show up in the list");
    test:assertEquals(configs[0].id, id);

    // Delete.
    json _ = check raw->delete(
            string `/tasks/${created.id}/pushNotificationConfigs/${id}`, headers = headers);

    // Get after delete: gone.
    http:Response afterDelete = check raw->get(
            string `/tasks/${created.id}/pushNotificationConfigs/${id}`, headers);
    test:assertEquals(afterDelete.statusCode, http:STATUS_NOT_FOUND,
            "the config must genuinely be gone after delete");

    // Delete again: idempotent, not an error, per specification 3.1.10.
    http:Response secondDelete = check raw->delete(
            string `/tasks/${created.id}/pushNotificationConfigs/${id}`, headers = headers);
    test:assertEquals(secondDelete.statusCode, http:STATUS_OK,
            "deleting an already-deleted config must succeed, not error");
}

@test:Config {}
function testServerRoundTripCreatePushNotificationConfigForUnknownTaskIsTyped() returns error? {
    http:Client raw = check pushConfigHttpClient();
    map<string> headers = {"A2A-Version": "1.0", "Content-Type": "application/json"};
    json body = {"url": "https://example.com/webhook"};
    http:Response resp = check raw->post(
            "/tasks/does-not-exist/pushNotificationConfigs", body, headers);
    test:assertEquals(resp.statusCode, http:STATUS_NOT_FOUND,
            "registering a config against an unknown task must be rejected, not silently accepted");
}

// ---- task-owner scoping --------------------------------------------------
//
// A third listener, on its own port, configured with a TaskOwnerResolver
// that reads a test-only "X-Test-Owner" header -- separate from echoListener
// so that its own unscoped (no resolver configured) round trip stays
// unambiguous. Proves scoping actually holds over the real HTTP wire, not
// just at the TaskStore unit level.

isolated class HeaderOwnerResolver {
    *TaskOwnerResolver;

    public isolated function resolveOwner(http:Request req) returns string?|Error {
        string|http:HeaderNotFoundError header = req.getHeader("X-Test-Owner");
        return header is string ? header : ();
    }
}

const int OWNER_SCOPED_TEST_PORT = 19236;
final string ownerScopedServerUrl = string `http://localhost:${OWNER_SCOPED_TEST_PORT}`;

listener Listener ownerScopedListener = new (OWNER_SCOPED_TEST_PORT, agentCard = {
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
}, ownerResolver = new HeaderOwnerResolver());

@test:BeforeSuite
function startOwnerScopedServer() returns error? {
    check ownerScopedListener.attach(new EchoAgent());
}

isolated function ownerScopedRawClient() returns http:Client|error => new (ownerScopedServerUrl);

isolated function sendAsOwner(http:Client raw, string owner, string text) returns Task|error {
    map<string> headers = {"A2A-Version": "1.0", "Content-Type": "application/json", "X-Test-Owner": owner};
    json body = {
        "message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": text}]}
    };
    json result = check raw->post("/message:send", body, headers);
    map<json> envelope = check result.ensureType();
    json? taskJson = envelope["task"];
    if taskJson is () {
        return error("expected a task in the response envelope");
    }
    return taskJson.cloneWithType(Task);
}

isolated function httpClientAs(string owner) returns HttpClient|error =>
    new (ownerScopedServerUrl, headers = {"X-Test-Owner": owner});

@test:Config {}
function testOwnerScopedGetTaskHiddenFromDifferentOwner() returns error? {
    http:Client raw = check ownerScopedRawClient();
    Task created = check sendAsOwner(raw, "alice", "alice's task");

    HttpClient aliceClient = check httpClientAs("alice");
    Task fetchedByAlice = check aliceClient->getTask({id: created.id});
    test:assertEquals(fetchedByAlice.id, created.id, "the owner must be able to fetch their own task");

    HttpClient bobClient = check httpClientAs("bob");
    Task|Error fetchedByBob = bobClient->getTask({id: created.id});
    test:assertTrue(fetchedByBob is TaskNotFoundError,
            "a different owner must see TaskNotFoundError, not the task or a distinct 'forbidden' error");
}

@test:Config {}
function testOwnerScopedCancelAndSubscribeHiddenFromDifferentOwner() returns error? {
    http:Client raw = check ownerScopedRawClient();
    Task created = check sendAsOwner(raw, "alice", "cancel and subscribe me");

    HttpClient bobClient = check httpClientAs("bob");

    Task|Error canceled = bobClient->cancelTask({id: created.id});
    test:assertTrue(canceled is TaskNotFoundError,
            "cancelTask on another owner's task must be TaskNotFoundError, same as an unknown id");

    stream<StreamResponse, error?>|Error subscribed = bobClient->subscribeToTask({id: created.id});
    test:assertTrue(subscribed is TaskNotFoundError,
            "subscribeToTask on another owner's task must be TaskNotFoundError, same as an unknown id");
}

@test:Config {}
function testOwnerScopedListTasksShowsOnlyOwnTasks() returns error? {
    http:Client raw = check ownerScopedRawClient();
    Task _ = check sendAsOwner(raw, "alice-list", "alice item one");
    Task _ = check sendAsOwner(raw, "alice-list", "alice item two");
    Task _ = check sendAsOwner(raw, "bob-list", "bob item one");

    HttpClient aliceClient = check httpClientAs("alice-list");
    ListTasksResponse aliceView = check aliceClient->listTasks({pageSize: 10});
    test:assertEquals(aliceView.totalSize, 2, "alice must see exactly her own two tasks, not bob's");
}

@test:Config {}
function testOwnerScopedPushNotificationConfigAsymmetry() returns error? {
    http:Client alice = check ownerScopedRawClient();
    Task created = check sendAsOwner(alice, "push-alice", "needs a webhook, owned");

    map<string> aliceHeaders = {"A2A-Version": "1.0", "Content-Type": "application/json", "X-Test-Owner": "push-alice"};
    map<string> bobHeaders = {"A2A-Version": "1.0", "Content-Type": "application/json", "X-Test-Owner": "push-bob"};

    json createBody = {"url": "https://example.com/webhook"};
    json createResult = check alice->post(
            string `/tasks/${created.id}/pushNotificationConfigs`, createBody, aliceHeaders);
    TaskPushNotificationConfig config = check createResult.cloneWithType(TaskPushNotificationConfig);
    string id = <string>config.id;

    // Bob creating a config against alice's task: TaskNotFoundError, same as
    // an unknown task -- create already checked task existence before this
    // feature, and now it also checks visibility.
    http:Response bobCreate = check alice->post(
            string `/tasks/${created.id}/pushNotificationConfigs`, createBody, bobHeaders);
    test:assertEquals(bobCreate.statusCode, http:STATUS_NOT_FOUND,
            "creating a config against a task not visible to the caller must be rejected");

    // Bob getting alice's config: TaskNotFoundError -- get previously did no
    // task-visibility check at all, so this closes a real gap, not just a
    // consistency nicety.
    http:Response bobGet = check alice->get(
            string `/tasks/${created.id}/pushNotificationConfigs/${id}`, bobHeaders);
    test:assertEquals(bobGet.statusCode, http:STATUS_NOT_FOUND,
            "getting a config on a task not visible to the caller must be rejected");

    // Bob listing alice's task's configs: empty page, not an error --
    // matches the existing behavior for a genuinely unknown task, so bob
    // cannot distinguish "not yours" from "doesn't exist" by response shape.
    json bobListResult = check alice->get(
            string `/tasks/${created.id}/pushNotificationConfigs`, bobHeaders);
    ListTaskPushNotificationConfigsResponse bobList =
        check bobListResult.cloneWithType(ListTaskPushNotificationConfigsResponse);
    test:assertEquals((bobList.configs ?: []).length(), 0,
            "listing configs on a task not visible to the caller must return an empty page, not an error");

    // Bob deleting alice's config: silent 200 no-op, not an error and not a
    // real deletion -- matches the existing idempotent-delete behavior for
    // an unknown config.
    http:Response bobDelete = check alice->delete(
            string `/tasks/${created.id}/pushNotificationConfigs/${id}`, headers = bobHeaders);
    test:assertEquals(bobDelete.statusCode, http:STATUS_OK,
            "deleting a config on a task not visible to the caller must silently succeed, not error");

    // The config must genuinely still exist for alice: bob's delete did nothing.
    json aliceGetAfter = check alice->get(
            string `/tasks/${created.id}/pushNotificationConfigs/${id}`, aliceHeaders);
    TaskPushNotificationConfig stillThere = check aliceGetAfter.cloneWithType(TaskPushNotificationConfig);
    test:assertEquals(stillThere.id, id, "bob's no-op delete must not have actually removed alice's config");
}

@test:AfterSuite
function stopEchoServer() returns error? {
    check echoListener.gracefulStop();
    check extendedCardListener.gracefulStop();
    check ownerScopedListener.gracefulStop();
}
