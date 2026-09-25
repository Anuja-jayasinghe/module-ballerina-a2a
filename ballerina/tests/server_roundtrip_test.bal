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
import ballerina/lang.runtime;
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
// artifact, with a handful of trigger texts for the checkpoints live
// streaming and error handling need to test deterministically:
// - "ping": a direct Message reply, no task at all.
// - "ask": pauses at TASK_STATE_INPUT_REQUIRED, for continuation tests.
// - "boom": onMessage returns an a2a:Error directly.
// - "panic": onMessage panics, for driveTask's own `trap` to catch.
// - "paced:<key>": blocks at each of three checkpoints on the Gate
//   registered under <key> (see testutil.bal's registerGate), for
//   deterministic live-streaming and multi-subscriber fan-out tests.
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
        if text == "ask" {
            check updater->working();
            check updater->requireInput({
                messageId: "ask-1",
                role: ROLE_AGENT,
                parts: [{text: "need more information"}]
            });
            return;
        }
        if text == "boom" {
            string msg = "agent exploded";
            return error InternalError(msg, message = msg);
        }
        if text == "panic" {
            panic error("agent panicked");
        }
        if text.startsWith("paced:") {
            Gate? gate = gateFor(text.substring(6));
            if gate is Gate {
                gate.awaitStep(1);
                check updater->working();
                gate.awaitStep(2);
                check updater->addArtifact([{text: "paced artifact"}]);
                gate.awaitStep(3);
                check updater->complete();
            }
            return;
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
function testServerServesAgentCardWithCachingHeaders() returns error? {
    // Specification 8.6.1: Agent Card endpoints SHOULD carry Cache-Control
    // and ETag response headers.
    http:Client raw = check new (serverUrl);
    http:Response resp = check raw->get("/.well-known/agent-card.json");
    string cacheControl = check resp.getHeader("Cache-Control");
    test:assertTrue(cacheControl.includes("max-age="), "the Agent Card response must declare a max-age");
    string etag = check resp.getHeader("ETag");
    test:assertTrue(etag.length() > 0, "the Agent Card response must carry an ETag");
}

@test:Config {}
function testServerResponsesUseA2AJsonContentType() returns error? {
    // Specification 11.1: application/a2a+json SHOULD be used for
    // requests and responses. Checked on both a plain JSON response and
    // an error response, since they're built through different code
    // paths (jsonResponse/cardHttpResponse vs. toRestErrorResponse).
    http:Client raw = check new (serverUrl);
    http:Response cardResp = check raw->get("/.well-known/agent-card.json");
    test:assertEquals(cardResp.getContentType(), "application/a2a+json");

    http:Response errorResp = check raw->get("/tasks/does-not-exist", {"A2A-Version": "1.0"});
    test:assertEquals(errorResp.getContentType(), "application/a2a+json");
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
function testServerRoundTripContinueUnknownTaskIsTyped() returns error? {
    // Per specification 3.4.2, a client cannot name a task into existence --
    // message.taskId naming an id the server has never seen is
    // TaskNotFoundError, not "create a new task with this id".
    Client c = check echoClient();
    Task|Message|Error result = c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, taskId: "does-not-exist", parts: [{text: "hello"}]}
    });
    test:assertTrue(result is TaskNotFoundError,
            "an unrecognized message.taskId must be TaskNotFoundError");
}

@test:Config {}
function testServerRoundTripContinueTerminalTaskIsRejected() returns error? {
    // The echo agent always finishes synchronously, so by the time this
    // test's own continuation attempt reaches the server, the task it
    // names is already TASK_STATE_COMPLETED -- specification 3.1.1
    // forbids sending it a further message.
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    Task|Message|Error result = c->sendMessage({
        message: {
            messageId: "m2",
            role: ROLE_USER,
            taskId: created.id,
            contextId: created.contextId,
            parts: [{text: "again"}]
        }
    });
    test:assertTrue(result is UnsupportedOperationError,
            "a message continuing an already-terminal task must be UnsupportedOperationError");
}

@test:Config {}
function testServerRoundTripContinueMismatchedContextIdIsRejected() returns error? {
    // Per specification 3.4.3, a message whose contextId disagrees with
    // the task it names by taskId must be rejected outright, not silently
    // reconciled either way.
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    Task|Message|Error result = c->sendMessage({
        message: {
            messageId: "m2",
            role: ROLE_USER,
            taskId: created.id,
            contextId: "a-different-context-entirely",
            parts: [{text: "again"}]
        }
    });
    test:assertTrue(result is InvalidAgentResponseError,
            "a message.contextId that disagrees with the continued task's own must be rejected");
}

@test:Config {}
function testServerRoundTripReturnImmediatelyHandsBackBeforeCompletion() returns error? {
    Client c = check echoClient();
    Task|Message reply = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]},
        configuration: {returnImmediately: true}
    });
    test:assertTrue(reply is Task, "returnImmediately must still hand back the task, not wait for a reply");
    Task submitted = <Task>reply;
    test:assertEquals(submitted.status.state, TASK_STATE_SUBMITTED,
            "the caller must see the task before the (fast, detached) echo agent has driven it further");

    // driveTask keeps running detached; poll until it lands where a
    // blocking sendMessage would have returned it synchronously.
    Task finished = check pollUntilTerminal(c, submitted.id);
    test:assertEquals(finished.status.state, TASK_STATE_COMPLETED);
    Artifact[] artifacts = finished.artifacts ?: [];
    test:assertEquals(artifacts.length(), 1);
    test:assertEquals(artifacts[0].parts[0]?.text, "echo: hello");
}

@test:Config {}
function testServerRoundTripReturnImmediatelyCompletesDirectMessageReply() returns error? {
    // Per this server's resolution of a gap the specification leaves
    // open: once the caller already holds a task id from the
    // immediate-return snapshot, a direct Message reply can no longer
    // make the task disappear as if it never existed -- it completes the
    // task with the Message as its final status.message instead.
    Client c = check echoClient();
    Task|Message reply = check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "ping"}]},
        configuration: {returnImmediately: true}
    });
    test:assertTrue(reply is Task, "returnImmediately always hands back a Task, even for a direct-reply agent");
    Task submitted = <Task>reply;

    Task finished = check pollUntilTerminal(c, submitted.id);
    test:assertEquals(finished.status.state, TASK_STATE_COMPLETED);
    Message? statusMessage = finished.status?.message;
    test:assertTrue(statusMessage is Message, "the direct Message reply must land as status.message");
    test:assertEquals((<Message>statusMessage).parts[0]?.text, "pong");
}

# Polls getTask until the task reaches a terminal state, or fails the test
# after a generous bound -- the echo agent's own work is near-instant, so a
# real hang here means driveTask never ran at all, not a slow agent.
#
# + c - The client to poll through
# + taskId - The task to poll
# + return - The task, once terminal
isolated function pollUntilTerminal(Client c, string taskId) returns Task|error {
    foreach int _ in 0 ..< 100 {
        Task task = check c->getTask({id: taskId});
        if isTerminalState(task.status.state) {
            return task;
        }
        runtime:sleep(0.05);
    }
    return error("task did not reach a terminal state in time");
}

@test:Config {}
function testServerRoundTripContinuePausedTaskSucceeds() returns error? {
    // The happy path: "ask" pauses at TASK_STATE_INPUT_REQUIRED with no
    // driver left running (onMessage already returned), so continuing it
    // is a clean, non-racing acquire.
    Client c = check echoClient();
    Task paused = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "ask"}]}
    });
    test:assertEquals(paused.status.state, TASK_STATE_INPUT_REQUIRED);

    Task|Message reply = check c->sendMessage({
        message: {
            messageId: "m2",
            role: ROLE_USER,
            taskId: paused.id,
            contextId: paused.contextId,
            parts: [{text: "here is more information"}]
        }
    });
    test:assertTrue(reply is Task, "continuing the paused task must drive it, not reply directly");
    Task completed = <Task>reply;
    test:assertEquals(completed.id, paused.id, "continuation must drive the SAME task, not mint a new one");
    test:assertEquals(completed.status.state, TASK_STATE_COMPLETED,
            "the continuation text isn't a trigger, so the echo agent completes it normally");

    Message[] history = completed?.history ?: [];
    test:assertEquals(history.length(), 1, "the continuation message must be appended to the task's history");
    test:assertEquals(history[0].messageId, "m2");
}

@test:Config {}
function testServerRoundTripAgentErrorFailsTask() returns error? {
    Client c = check echoClient();
    Task submitted = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "boom"}]},
        configuration: {returnImmediately: true}
    });
    Task finished = check pollUntilTerminal(c, submitted.id);
    test:assertEquals(finished.status.state, TASK_STATE_FAILED,
            "an agent-returned Error must transition the task to FAILED");
    Message? statusMessage = finished.status?.message;
    test:assertTrue(statusMessage is Message, "the failure must be recorded as the task's status message");
    test:assertEquals((<Message>statusMessage).parts[0]?.text, "agent exploded");
}

@test:Config {}
function testServerRoundTripAgentPanicFailsTask() returns error? {
    Client c = check echoClient();
    Task submitted = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "panic"}]},
        configuration: {returnImmediately: true}
    });
    Task finished = check pollUntilTerminal(c, submitted.id);
    test:assertEquals(finished.status.state, TASK_STATE_FAILED,
            "a panic in agent code must be trapped and transition the task to FAILED, not crash the server");
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
function testServerRoundTripErrorStatusCodesMatchSpecTable() returns error? {
    // The typed Client decodes purely by ErrorInfo.reason, so it cannot
    // catch a wrong HTTP status on its own -- these go around it with a
    // raw http:Client to check the wire status directly, per
    // specification section 5.4's error-code mapping table.
    map<string> headers = {"A2A-Version": "1.0"};
    http:Client raw = check new (serverUrl);

    Task created = <Task>check (check echoClient())->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "already done"}]}
    });
    http:Response cancelResponse = check raw->post(string `/tasks/${created.id}:cancel`, (), headers);
    test:assertEquals(cancelResponse.statusCode, http:STATUS_BAD_REQUEST,
            "TaskNotCancelableError must be 400 Bad Request per the spec's error table");

    // echoListener never configures an extended card, so
    // capabilities.extendedAgentCard reads false and this is
    // UnsupportedOperationError (see getExtendedAgentCard's own doc) --
    // still 400, not 404, either way.
    http:Response cardResponse = check raw->get("/extendedAgentCard", headers);
    test:assertEquals(cardResponse.statusCode, http:STATUS_BAD_REQUEST,
            "an unconfigured extended card's rejection must be 400, not 404 -- it's the server's own " +
            "configuration, not a missing resource the request named");
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
    // Per specification 3.1.6, a task already in a terminal state cannot
    // be subscribed to. The echo agent always finishes inside its own
    // sendMessage call, so by the time this test's own subscribeToTask
    // request reaches the server, the task it names is already
    // TASK_STATE_COMPLETED -- exactly the case this rejects.
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "subscribe me"}]}
    });

    stream<StreamResponse, error?>|Error result = c->subscribeToTask({id: created.id});
    test:assertTrue(result is UnsupportedOperationError,
            "subscribeToTask on an already-terminal task must be a2a:UnsupportedOperationError, " +
            "not a one-event snapshot");
}

@test:Config {}
function testServerRoundTripSubscribeToUnknownTaskIsTyped() returns error? {
    Client c = check echoClient();
    stream<StreamResponse, error?>|Error result = c->subscribeToTask({id: "does-not-exist"});
    test:assertTrue(result is TaskNotFoundError,
            "an unknown task must round-trip as a2a:TaskNotFoundError through the google.rpc.Status body");
}

@test:Config {}
function testServerRoundTripMultiSubscriberFanOut() returns error? {
    // The real proof of specification 3.5.2: two concurrent streams
    // following one in-flight task must see the same further events, in
    // the same order, deterministically -- not by runtime:sleep timing
    // luck. EchoAgent's "paced:<key>" trigger blocks at each of its three
    // checkpoints on the Gate registered under <key>, so this test decides
    // exactly when each event broadcasts.
    Client c = check echoClient();
    Gate gate = new;
    string key = "fanout-1";
    registerGate(key, gate);

    // sendStreamingMessage's own client call blocks until the server's
    // response begins, which here means until the agent's first
    // checkpoint releases -- so step 1 is opened concurrently, on its own
    // strand, rather than after the call returns.
    future<()> _ = start gate.advanceTo(1);
    stream<StreamResponse, error?> primary = check c->sendStreamingMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "paced:" + key}]}
    });

    StreamResponse primarySeed = check expectStreamValue(primary);
    test:assertTrue(primarySeed is Task, "the first event must be the lazily-emitted seed Task");
    string taskId = (<Task>primarySeed).id;
    StreamResponse primaryWorking = check expectStreamValue(primary);
    test:assertTrue(primaryWorking is TaskStatusUpdateEvent);
    test:assertEquals((<TaskStatusUpdateEvent>primaryWorking).status.state, TASK_STATE_WORKING);

    // A second subscriber attaches only now -- after the task already
    // exists and is WORKING, mid-drive -- and must still see every
    // further event the first subscriber does, identically and in the
    // same order.
    stream<StreamResponse, error?> secondary = check c->subscribeToTask({id: taskId});
    StreamResponse secondarySnapshot = check expectStreamValue(secondary);
    test:assertTrue(secondarySnapshot is Task, "a late subscriber's first event is the task's current snapshot");
    test:assertEquals((<Task>secondarySnapshot).status.state, TASK_STATE_WORKING);

    gate.advanceTo(2);
    StreamResponse primaryArtifact = check expectStreamValue(primary);
    StreamResponse secondaryArtifact = check expectStreamValue(secondary);
    test:assertTrue(primaryArtifact is TaskArtifactUpdateEvent);
    test:assertTrue(secondaryArtifact is TaskArtifactUpdateEvent);
    test:assertEquals((<TaskArtifactUpdateEvent>primaryArtifact).artifact.artifactId,
            (<TaskArtifactUpdateEvent>secondaryArtifact).artifact.artifactId,
            "both subscribers must see the identical artifact event");

    gate.advanceTo(3);
    StreamResponse primaryDone = check expectStreamValue(primary);
    StreamResponse secondaryDone = check expectStreamValue(secondary);
    test:assertTrue(primaryDone is TaskStatusUpdateEvent);
    test:assertTrue(secondaryDone is TaskStatusUpdateEvent);
    test:assertEquals((<TaskStatusUpdateEvent>primaryDone).status.state, TASK_STATE_COMPLETED);
    test:assertEquals((<TaskStatusUpdateEvent>secondaryDone).status.state, TASK_STATE_COMPLETED);

    // Both streams must end now: the task is terminal, so the broadcaster
    // closed -- closing one stream must not affect the other.
    record {| StreamResponse value; |}|error? primaryEnd = primary.next();
    record {| StreamResponse value; |}|error? secondaryEnd = secondary.next();
    test:assertTrue(primaryEnd is (), "the primary stream must close once the task completes");
    test:assertTrue(secondaryEnd is (), "the secondary stream must close once the task completes");
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
    // Far larger than however many tasks the other tests sharing this server
    // have created, so this page holds all of them.
    ListTasksResponse page = check c->listTasks({pageSize: 1000});
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
    // this request never actually reaches a Client through echoListener's
    // own wiring -- the Client already refuses client-side with the same
    // UnsupportedOperationError this asserts, per the test above. The
    // branch is still real code for a future server built directly
    // against DefaultHandler without that same coupling, so it is
    // exercised directly here rather than left untested.
    TaskStore store = new InMemoryTaskStore();
    DefaultHandler handler = new (new EchoAgent(), store, (), new HttpPushNotificationSender(), new, 300);
    AgentCard|Error result = handler.getExtendedAgentCard();
    test:assertTrue(result is UnsupportedOperationError,
            "capabilities.extendedAgentCard false must be UnsupportedOperationError per specification 3.3.4, " +
            "not ExtendedAgentCardNotConfiguredError -- that's reserved for capability true but still unconfigured, " +
            "a state this listener's own deriveServedCard never lets happen");
}

// ---- push-notification config CRUD --------------------------------------
//
// capabilities.pushNotifications is true since delivery landed, so the
// library's own Client no longer self-gates these four operations -- unlike
// the extended-card self-gate above, which is exercised on purpose. Using
// the typed Client here, rather than a raw http:Client, is the stronger
// assertion: it proves a real caller of this library, not just a caller
// willing to speak the wire directly, can drive the whole CRUD cycle.

@test:Config {}
function testServerRoundTripPushNotificationConfigCrud() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "needs a webhook"}]}
    });

    // Create.
    TaskPushNotificationConfig config = check c->createTaskPushNotificationConfig({
        taskId: created.id,
        url: "https://example.com/webhook",
        token: "corr-1"
    });
    test:assertEquals(config.url, "https://example.com/webhook");
    string? configId = config?.id;
    test:assertTrue(configId is string, "the server must assign a config id on create");
    string id = <string>configId;

    // Get.
    TaskPushNotificationConfig fetched = check c->getTaskPushNotificationConfig({taskId: created.id, id});
    test:assertEquals(fetched.id, id);
    test:assertEquals(fetched.token, "corr-1");

    // List.
    ListTaskPushNotificationConfigsResponse page =
        check c->listTaskPushNotificationConfigs({taskId: created.id});
    TaskPushNotificationConfig[] configs = page.configs ?: [];
    test:assertEquals(configs.length(), 1, "the config just created must show up in the list");
    test:assertEquals(configs[0].id, id);

    // Delete.
    check c->deleteTaskPushNotificationConfig({taskId: created.id, id});

    // Get after delete: gone.
    TaskPushNotificationConfig|Error afterDelete = c->getTaskPushNotificationConfig({taskId: created.id, id});
    test:assertTrue(afterDelete is TaskNotFoundError, "the config must genuinely be gone after delete");

    // Delete again: idempotent, not an error, per specification 3.1.10.
    check c->deleteTaskPushNotificationConfig({taskId: created.id, id});
}

@test:Config {}
function testServerRoundTripCreatePushNotificationConfigForUnknownTaskIsTyped() returns error? {
    Client c = check echoClient();
    TaskPushNotificationConfig|Error result =
        c->createTaskPushNotificationConfig({taskId: "does-not-exist", url: "https://example.com/webhook"});
    test:assertTrue(result is TaskNotFoundError,
            "registering a config against an unknown task must be rejected, not silently accepted");
}

// A config's id is the caller's to choose: a webhook registered as "my-cfg"
// must come back, and be fetchable and deletable, as "my-cfg". Only an unset
// (or empty) id is the server's to assign.
@test:Config {}
function testServerRoundTripPushNotificationConfigKeepsTheCallersOwnId() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m-cfg-id", role: ROLE_USER, parts: [{text: "needs webhooks"}]}
    });

    TaskPushNotificationConfig mine = check c->createTaskPushNotificationConfig({
        taskId: created.id, url: "https://example.com/a", id: "my-cfg", token: "first"
    });
    test:assertEquals(mine.id, "my-cfg", "the id the caller chose must be kept, not replaced");
    TaskPushNotificationConfig fetched = check c->getTaskPushNotificationConfig({taskId: created.id, id: "my-cfg"});
    test:assertEquals(fetched.token, "first");

    // Same id again on the same task replaces the earlier config.
    _ = check c->createTaskPushNotificationConfig({
        taskId: created.id, url: "https://example.com/b", id: "my-cfg", token: "second"
    });
    TaskPushNotificationConfig replaced = check c->getTaskPushNotificationConfig({taskId: created.id, id: "my-cfg"});
    test:assertEquals(replaced.token, "second", "registering the same id twice must replace, not duplicate");

    // No id, and an empty id, both mean "server, choose one".
    TaskPushNotificationConfig assigned = check c->createTaskPushNotificationConfig(
            {taskId: created.id, url: "https://example.com/c"});
    string? assignedId = assigned?.id;
    test:assertTrue(assignedId is string && assignedId != "" && assignedId != "my-cfg");
    TaskPushNotificationConfig fromEmpty = check c->createTaskPushNotificationConfig(
            {taskId: created.id, url: "https://example.com/d", id: ""});
    string? emptyBecame = fromEmpty?.id;
    test:assertTrue(emptyBecame is string && emptyBecame != "", "an empty id must be treated as unset");

    ListTaskPushNotificationConfigsResponse page = check c->listTaskPushNotificationConfigs({taskId: created.id});
    test:assertEquals((page.configs ?: []).length(), 3, "my-cfg (replaced once), plus the two assigned ones");

    check c->deleteTaskPushNotificationConfig({taskId: created.id, id: "my-cfg"});
    TaskPushNotificationConfig|Error gone = c->getTaskPushNotificationConfig({taskId: created.id, id: "my-cfg"});
    test:assertTrue(gone is TaskNotFoundError, "delete must work under the caller's own id");
}

// The id is a URL path segment, so one containing "/" could never be fetched
// again. It is a bad request (400), rejected before any task is created.
@test:Config {}
function testServerRoundTripPushNotificationConfigIdWithASlashIsRejected() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m-cfg-slash", role: ROLE_USER, parts: [{text: "needs a webhook"}]}
    });

    TaskPushNotificationConfig|Error viaCreate = c->createTaskPushNotificationConfig(
            {taskId: created.id, url: "https://example.com/a", id: "a/b"});
    test:assertTrue(viaCreate is InternalError && viaCreate.detail()?.code == -32600,
            "an unusable id must be an invalid-request error, not accepted");

    ListTasksResponse listedBefore = check c->listTasks();
    int before = listedBefore.totalSize;
    Task|Message|Error viaSend = c->sendMessage({
        message: {messageId: "m-cfg-slash-2", role: ROLE_USER, parts: [{text: "x"}]},
        configuration: {taskPushNotificationConfig: {url: "https://example.com/a", id: "a/b"}}
    });
    test:assertTrue(viaSend is InternalError && viaSend.detail()?.code == -32600);
    ListTasksResponse listedAfter = check c->listTasks();
    test:assertEquals(listedAfter.totalSize, before,
            "the bad id must be rejected before a task is created, not leave an orphan one behind");
}

// The same registration through the send request itself.
@test:Config {}
function testServerRoundTripInlinePushNotificationConfigKeepsTheCallersOwnId() returns error? {
    Client c = check echoClient();
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m-inline-id", role: ROLE_USER, parts: [{text: "inline webhook"}]},
        configuration: {taskPushNotificationConfig: {url: "https://example.com/a", id: "inline-cfg"}}
    });
    TaskPushNotificationConfig fetched = check c->getTaskPushNotificationConfig(
            {taskId: created.id, id: "inline-cfg"});
    test:assertEquals(fetched.url, "https://example.com/a");
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

// ---- push-notification delivery ------------------------------------------
//
// A fourth listener, on its own port, configured with a pushSender whose
// validateUrl is off -- this test's own webhook receiver (push_sender_test.bal's
// webhookReceiver) is itself on localhost, which HttpPushNotificationSender's
// default SSRF validation correctly rejects; that rejection is proven
// separately in push_sender_test.bal. This section proves delivery actually
// fires end to end, over the real wire, covering both registration channels.

const int PUSH_NOTIFICATION_TEST_PORT = 19238;
final string pushNotificationServerUrl = string `http://localhost:${PUSH_NOTIFICATION_TEST_PORT}`;
final string testWebhookUrl = string `http://localhost:${PUSH_SENDER_TEST_PORT}/webhook/receiver`;

listener Listener pushNotificationListener = new (PUSH_NOTIFICATION_TEST_PORT, agentCard = {
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
}, pushSender = new HttpPushNotificationSender({validateUrl: false}));

// Completes normally, except for:
// - "pause": leaves the task at TASK_STATE_WORKING -- non-terminal, so
//   cancelTask can legally act on it.
// - "hold:<key>": works, then blocks on the Gate registered under <key>, then
//   tries one more write and simply finishes whether or not it was accepted --
//   what an agent does when it does not check the result of every update. A
//   test cancels the task while the agent is held, so that write is refused.
isolated service class PushNotificationAgent {
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
        check updater->working();
        if text == "pause" {
            return ();
        }
        if text.startsWith("hold:") {
            Gate? gate = gateFor(text.substring(5));
            if gate is Gate {
                gate.awaitStep(1);
                Error? refused = updater->working();
                gate.advanceTo(refused is Error ? 2 : 3);
            }
            return ();
        }
        check updater->addArtifact([{text: string `echo: ${text}`}]);
        check updater->complete();
        return;
    }
}

@test:BeforeSuite
function startPushNotificationServer() returns error? {
    check pushNotificationListener.attach(new PushNotificationAgent());
}

@test:Config {}
function testServerRoundTripPushNotificationDeliveryOnCompletion() returns error? {
    HttpClient c = check new (pushNotificationServerUrl);
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "notify me"}]},
        configuration: {taskPushNotificationConfig: {url: testWebhookUrl}}
    });
    test:assertEquals(created.status.state, TASK_STATE_COMPLETED);

    CapturedWebhookCall? call = takeLastWebhookCall();
    test:assertTrue(call is CapturedWebhookCall,
            "the webhook registered inline on the sendMessage request must have been called");
    CapturedWebhookCall received = <CapturedWebhookCall>call;
    map<json> task = check webhookTask(received);
    test:assertEquals(task["id"], created.id);
    map<json> status = check task["status"].ensureType();
    test:assertEquals(status["state"], "TASK_STATE_COMPLETED");
}

// Polls until the task in `contextId` reaches `want`, and returns its id.
isolated function awaitTaskInState(HttpClient c, string contextId, TaskState want) returns string|error {
    foreach int _ in 0 ..< 250 {
        ListTasksResponse page = check c->listTasks({contextId});
        foreach Task t in page.tasks {
            if t.status.state == want {
                return t.id;
            }
        }
        runtime:sleep(0.02);
    }
    return error(string `no task in context ${contextId} reached ${want}`);
}

// A task canceled while its agent code is still running: cancelTask has
// already announced CANCELED, the store refuses the agent's later writes, and
// the agent -- which does not check every update -- simply finishes. Neither
// what a blocking sendMessage reports nor what the webhooks receive may then
// go back to the state the agent last reached (WORKING): the caller must see
// CANCELED, and the webhook must have received exactly one notification, the
// CANCELED one.
@test:Config {}
function testServerRoundTripCancelDuringABlockingSendReportsCanceledAndNotifiesOnce() returns error? {
    HttpClient c = check new (pushNotificationServerUrl);
    Gate gate = new;
    registerGate("hold-blocking", gate);
    _ = takeWebhookHistory();

    string contextId = "ctx-hold-blocking";
    future<Task|Message|Error> sent = start c->sendMessage({
        message: {messageId: "hold-b", contextId, role: ROLE_USER, parts: [{text: "hold:hold-blocking"}]},
        configuration: {taskPushNotificationConfig: {url: testWebhookUrl}}
    });
    string taskId = check awaitTaskInState(c, contextId, TASK_STATE_WORKING);

    Task canceled = check c->cancelTask({id: taskId});
    test:assertEquals(canceled.status.state, TASK_STATE_CANCELED);

    gate.advanceTo(1);
    gate.awaitStep(2);
    Task|Message reply = check wait sent;
    test:assertTrue(reply is Task, "the blocking send must still return a task");
    Task returned = <Task>reply;
    test:assertEquals(returned.status.state, TASK_STATE_CANCELED,
            "the caller must be told the real state, not the WORKING the agent last reached");

    CapturedWebhookCall[] calls = takeWebhookHistory();
    test:assertEquals(calls.length(), 1, "cancelTask already notified; the agent finishing must not notify again");
    map<json> task = check webhookTask(calls[0]);
    map<json> status = check task["status"].ensureType();
    test:assertEquals(status["state"], "TASK_STATE_CANCELED");
}

// The same race on the detached path (returnImmediately), where nothing waits
// on the drive: the webhook must still receive one CANCELED and nothing after.
@test:Config {}
function testServerRoundTripCancelDuringADetachedDriveNeverSendsAStaleWebhook() returns error? {
    HttpClient c = check new (pushNotificationServerUrl);
    Gate gate = new;
    registerGate("hold-detached", gate);
    _ = takeWebhookHistory();

    string contextId = "ctx-hold-detached";
    Task seeded = <Task>check c->sendMessage({
        message: {messageId: "hold-d", contextId, role: ROLE_USER, parts: [{text: "hold:hold-detached"}]},
        configuration: {returnImmediately: true, taskPushNotificationConfig: {url: testWebhookUrl}}
    });
    _ = check awaitTaskInState(c, contextId, TASK_STATE_WORKING);

    Task canceled = check c->cancelTask({id: seeded.id});
    test:assertEquals(canceled.status.state, TASK_STATE_CANCELED);

    gate.advanceTo(1);
    gate.awaitStep(2);
    // The drive's own follow-up runs just after onMessage returns; a stale
    // notification, if the bug were present, would follow within moments.
    runtime:sleep(0.5);

    CapturedWebhookCall[] calls = takeWebhookHistory();
    test:assertEquals(calls.length(), 1, "exactly the one notification cancelTask sent");
    map<json> task = check webhookTask(calls[0]);
    map<json> status = check task["status"].ensureType();
    test:assertEquals(status["state"], "TASK_STATE_CANCELED");
    Task stored = check c->getTask({id: seeded.id});
    test:assertEquals(stored.status.state, TASK_STATE_CANCELED, "and the stored state stays canceled");
}

@test:Config {}
function testServerRoundTripCancelClosesLiveSubscriberStream() returns error? {
    // "pause" leaves the task genuinely parked at TASK_STATE_WORKING with
    // no driver left running (onMessage already returned) -- a
    // deterministic, non-racing way to get a non-terminal task a live
    // subscriber can attach to and this test can then cancel out from
    // under it.
    HttpClient c = check new (pushNotificationServerUrl);
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m3", role: ROLE_USER, parts: [{text: "pause"}]}
    });
    test:assertEquals(created.status.state, TASK_STATE_WORKING);

    stream<StreamResponse, error?> events = check c->subscribeToTask({id: created.id});
    StreamResponse first = check expectStreamValue(events);
    test:assertTrue(first is Task, "subscribeToTask's first event must be the task's current state");
    test:assertEquals((<Task>first).status.state, TASK_STATE_WORKING);

    Task canceled = check c->cancelTask({id: created.id});
    test:assertEquals(canceled.status.state, TASK_STATE_CANCELED);

    StreamResponse second = check expectStreamValue(events);
    test:assertTrue(second is TaskStatusUpdateEvent,
            "the live subscriber must see the CANCELED transition as its own event");
    test:assertEquals((<TaskStatusUpdateEvent>second).status.state, TASK_STATE_CANCELED);

    record {| StreamResponse value; |}|error? third = events.next();
    test:assertTrue(third is (), "the stream must close once the task is canceled, not hang open");
}

@test:Config {}
function testServerRoundTripPushNotificationDeliveryOnCancel() returns error? {
    HttpClient c = check new (pushNotificationServerUrl);
    Task created = <Task>check c->sendMessage({
        message: {messageId: "m2", role: ROLE_USER, parts: [{text: "pause"}]}
    });
    test:assertEquals(created.status.state, TASK_STATE_WORKING,
            "the pausing branch must leave the task non-terminal");

    // Registered explicitly, after the task already exists -- the other
    // registration channel from the inline one exercised above.
    TaskPushNotificationConfig _ = check c->createTaskPushNotificationConfig({taskId: created.id, url: testWebhookUrl});

    Task canceled = check c->cancelTask({id: created.id});
    test:assertEquals(canceled.status.state, TASK_STATE_CANCELED);

    CapturedWebhookCall? call = takeLastWebhookCall();
    test:assertTrue(call is CapturedWebhookCall, "cancelTask must also notify registered webhooks");
    CapturedWebhookCall received = <CapturedWebhookCall>call;
    map<json> canceledTask = check webhookTask(received);
    map<json> canceledStatus = check canceledTask["status"].ensureType();
    test:assertEquals(canceledStatus["state"], "TASK_STATE_CANCELED");
}

// This module's own SecurityRequirement type is internally flat
// (v0.3-shaped, see security_scheme_codec.bal's own doc), but the actual
// A2A v1.0 wire shape wraps each requirement's scheme map under
// "schemes", with each scope list itself wrapped as StringList's
// {"list": [...]}. A separate listener, since none of the others above
// set securityRequirements on their card.

const int SECURITY_REQUIREMENTS_TEST_PORT = 19239;
final string securityRequirementsServerUrl = string `http://localhost:${SECURITY_REQUIREMENTS_TEST_PORT}`;

listener Listener securityRequirementsListener = new (SECURITY_REQUIREMENTS_TEST_PORT, agentCard = {
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: [],
    securitySchemes: {
        "bearerAuth": <HttpAuthSecurityScheme>{scheme: "bearer", bearerFormat: "JWT"}
    },
    securityRequirements: [{"bearerAuth": ["read", "write"]}, {"bearerAuth": []}]
});

@test:BeforeSuite
function startSecurityRequirementsServer() returns error? {
    check securityRequirementsListener.attach(new EchoAgent());
}

@test:Config {}
function testServerRoundTripSecurityRequirementsServedInV10WireShape() returns error? {
    // A raw http:Client, not this module's own tolerant Client, is the
    // only way to catch a server that got the encode direction wrong --
    // this module's own Client's parseSecurityRequirements already
    // accepts both the flat and the wrapped shape.
    http:Client raw = check new (securityRequirementsServerUrl);
    json card = check raw->get("/.well-known/agent-card.json");
    map<json> cardMap = check card.ensureType();
    json[] requirements = check cardMap["securityRequirements"].ensureType();
    test:assertEquals(requirements.length(), 2);

    map<json> nonEmpty = check requirements[0].ensureType();
    map<json> nonEmptySchemes = check nonEmpty["schemes"].ensureType();
    map<json> nonEmptyEntry = check nonEmptySchemes["bearerAuth"].ensureType();
    string[] scopes = check nonEmptyEntry["list"].cloneWithType();
    test:assertEquals(scopes, ["read", "write"],
            "a non-empty scope list must be wrapped as {\"list\": [...]}, the v1.0 StringList shape");

    map<json> empty = check requirements[1].ensureType();
    map<json> emptySchemes = check empty["schemes"].ensureType();
    map<json> emptyEntry = check emptySchemes["bearerAuth"].ensureType();
    string[] emptyScopes = check emptyEntry["list"].cloneWithType();
    test:assertEquals(emptyScopes, [],
            "an empty scope list must still be a wrapped, empty StringList, not a bare []");
}

// Per specification 3.3.4/4.6.3: a client that has not declared support
// (via the A2A-Extensions header) for an extension the card marks
// required: true must be refused, not silently served as if the
// extension didn't apply. A separate listener, since none of the others
// above declare any extensions.

const int EXTENSIONS_TEST_PORT = 19240;
final string extensionsServerUrl = string `http://localhost:${EXTENSIONS_TEST_PORT}`;
const string REQUIRED_EXTENSION_URI = "https://example.com/extensions/geolocation/v1";

listener Listener extensionsListener = new (EXTENSIONS_TEST_PORT, agentCard = {
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {
        extensions: [
            {uri: REQUIRED_EXTENSION_URI, description: "Location-based search", required: true},
            {uri: "https://standards.org/extensions/citations/v1", description: "Citations", required: false}
        ]
    },
    supportedInterfaces: []
});

@test:BeforeSuite
function startExtensionsServer() returns error? {
    check extensionsListener.attach(new EchoAgent());
}

@test:Config {}
function testServerRoundTripRequiredExtensionRejectsUndeclaredClient() returns error? {
    HttpClient c = check new (extensionsServerUrl);
    Task|Message|Error result = c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(result is ExtensionSupportRequiredError,
            "a client that never declared the required extension must be refused");
}

@test:Config {}
function testServerRoundTripRequiredExtensionAcceptsDeclaredClient() returns error? {
    // The card also declares a second, non-required extension this
    // client never declares support for -- only required: true is
    // enforced, so that alone must not block the request either.
    HttpClient c = check new (extensionsServerUrl, requestedExtensions = [REQUIRED_EXTENSION_URI]);
    Task|Message|Error result = c->sendMessage({
        message: {messageId: "m1", role: ROLE_USER, parts: [{text: "hello"}]}
    });
    test:assertTrue(result is Task, "declaring the required extension must let the request through normally");
}

// A deployment can deliberately withhold a capability this listener
// otherwise always implements -- e.g. no outbound network access for
// webhooks -- via ListenerConfiguration.streamingCapability/
// pushNotificationsCapability. Both false here, on a dedicated listener,
// so the other listeners above (all left at the true default) keep
// proving today's unchanged behavior.

const int WITHHELD_CAPABILITIES_TEST_PORT = 19241;
final string withheldCapabilitiesServerUrl = string `http://localhost:${WITHHELD_CAPABILITIES_TEST_PORT}`;

listener Listener withheldCapabilitiesListener = new (WITHHELD_CAPABILITIES_TEST_PORT, agentCard = {
    name: "Echo Agent",
    description: "Echoes its input",
    version: "1.0.0",
    skills: [{id: "echo", name: "Echo", description: "Echoes text", tags: ["echo"]}],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
}, streamingCapability = false, pushNotificationsCapability = false);

@test:BeforeSuite
function startWithheldCapabilitiesServer() returns error? {
    check withheldCapabilitiesListener.attach(new EchoAgent());
}

@test:Config {}
function testServerRoundTripWithheldCapabilitiesReflectedOnCard() returns error? {
    AgentCard card = check resolveAgentCard(withheldCapabilitiesServerUrl);
    test:assertFalse(card.capabilities.streaming,
            "streamingCapability: false must be reflected as capabilities.streaming: false on the served card");
    test:assertFalse(card.capabilities.pushNotifications,
            "pushNotificationsCapability: false must be reflected as capabilities.pushNotifications: false");
}

@test:Config {}
function testServerRoundTripWithheldStreamingIsRejectedServerSide() returns error? {
    // The typed Client would normally short-circuit client-side on a card
    // that declares streaming unsupported -- go around it with a raw
    // http:Client to prove the server itself also refuses, per
    // specification 3.3.4, not just that the client happens not to try.
    http:Client raw = check new (withheldCapabilitiesServerUrl);
    json body = {"message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": "hello"}]}};
    http:Response resp = check raw->post("/message:stream", body, {"A2A-Version": "1.0"});
    test:assertEquals(resp.statusCode, http:STATUS_BAD_REQUEST,
            "sendStreamingMessage on a listener with streamingCapability: false must be rejected server-side");
}

@test:Config {}
function testServerRoundTripWithheldPushNotificationsIsRejectedServerSide() returns error? {
    // The typed Client's createTaskPushNotificationConfig already refuses
    // client-side on a card declaring pushNotifications unsupported (same
    // short-circuit as streaming) -- go around it with a raw http:Client,
    // per this codebase's own testing convention for exactly this case.
    http:Client raw = check new (withheldCapabilitiesServerUrl);
    json body = {"url": "https://example.com/webhook"};
    http:Response resp = check raw->post("/tasks/does-not-matter/pushNotificationConfigs", body,
            {"A2A-Version": "1.0"});
    test:assertEquals(resp.statusCode, http:STATUS_BAD_REQUEST,
            "push-notification-config operations on a listener with pushNotificationsCapability: false " +
            "must be rejected server-side, even before any task-existence check");
}

@test:AfterSuite
function stopEchoServer() returns error? {
    check echoListener.gracefulStop();
    check extendedCardListener.gracefulStop();
    check ownerScopedListener.gracefulStop();
    check pushNotificationListener.gracefulStop();
    check securityRequirementsListener.gracefulStop();
    check extensionsListener.gracefulStop();
    check withheldCapabilitiesListener.gracefulStop();
}
