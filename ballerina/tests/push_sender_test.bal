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

import ballerina/http;
import ballerina/test;

// ---- URL validation, table-driven --------------------------------------

isolated function urlValidationCases() returns [string, boolean][] => [
    // Allowed.
    ["https://example.com/webhook", true],
    ["http://webhook.example.org:8080/x", true],
    ["https://8.8.8.8/hook", true],
    ["http://172.10.0.5/hook", true], // outside the 172.16-31/12 private block
    ["http://100.63.0.5/hook", true], // outside the 100.64.0.0/10 CGNAT block
    ["http://[2001:4860:4860::8888]/hook", true], // public IPv6
    ["http://user:pass@example.com:8080/hook", true], // userinfo stripped before the host check
    // Rejected: scheme.
    ["ftp://example.com/", false],
    ["example.com/webhook", false],
    // Rejected: loopback, metadata, private, CGNAT, unspecified.
    ["http://127.0.0.1:9000/", false],
    ["http://169.254.169.254/latest/meta-data", false],
    ["http://10.0.0.5/hook", false],
    ["http://172.20.0.5/hook", false],
    ["http://192.168.1.5/hook", false],
    ["http://100.64.0.5/hook", false],
    ["http://0.0.0.0/hook", false],
    // Rejected: by name.
    ["http://localhost:8080/hook", false],
    ["http://sub.localhost/hook", false],
    ["http://myservice.local/hook", false],
    ["http://metadata.google.internal/x", false],
    // Rejected: IPv6.
    ["http://[::1]:8080/hook", false],
    ["http://[fc00::1]/hook", false]
];

@test:Config {dataProvider: urlValidationCases}
function testValidateWebhookUrl(string url, boolean allowed) returns error? {
    Error? result = validateWebhookUrl(url);
    if allowed {
        test:assertTrue(result is (),
                string `expected "${url}" to be allowed, got: ${result is Error ? result.message() : ""}`);
    } else {
        test:assertTrue(result is Error, string `expected "${url}" to be rejected`);
    }
}

// ---- HttpPushNotificationSender, against a real local receiver --------

const int PUSH_SENDER_TEST_PORT = 19237;

type CapturedWebhookCall record {|
    map<string> headers;
    json body;
    string rawPath;
|};

isolated CapturedWebhookCall? lastWebhookCall = ();

isolated function recordWebhookCall(CapturedWebhookCall call) {
    lock {
        lastWebhookCall = call.clone();
    }
}

isolated function takeLastWebhookCall() returns CapturedWebhookCall? {
    lock {
        CapturedWebhookCall? call = lastWebhookCall;
        lastWebhookCall = ();
        return call.clone();
    }
}

listener http:Listener webhookReceiver = new (PUSH_SENDER_TEST_PORT);

service /webhook/receiver on webhookReceiver {
    resource function post .(http:Request req) returns json {
        map<string> headers = {};
        foreach string name in req.getHeaderNames() {
            string|http:HeaderNotFoundError value = req.getHeader(name);
            if value is string {
                headers[name.toLowerAscii()] = value;
            }
        }
        json body = {};
        json|error payload = req.getJsonPayload();
        if payload is json {
            body = payload;
        }
        recordWebhookCall({headers, body, rawPath: req.rawPath});
        return {received: true};
    }
}

isolated function sampleTask() returns Task => {
    id: "task-1",
    contextId: "ctx-1",
    status: {state: TASK_STATE_COMPLETED, timestamp: "2026-01-01T00:00:00Z"}
};

@test:Config {}
function testHttpPushNotificationSenderPostsTaskBody() returns error? {
    // validateUrl: false -- this test's receiver is itself on localhost,
    // which the sender's own SSRF validation correctly rejects by default;
    // that rejection is what testHttpPushNotificationSenderRejectsDisallowedUrlBeforeSending
    // covers. This test is about the POST mechanics, not validation.
    HttpPushNotificationSender sender = new ({validateUrl: false});
    Error? result = sender.send({url: string `http://localhost:${PUSH_SENDER_TEST_PORT}/webhook/receiver`},
            sampleTask());
    test:assertTrue(result is (), "delivery to a real, reachable receiver must succeed");

    CapturedWebhookCall? call = takeLastWebhookCall();
    test:assertTrue(call is CapturedWebhookCall, "the receiver must have been called");
    CapturedWebhookCall received = <CapturedWebhookCall>call;
    test:assertEquals(received.rawPath, "/webhook/receiver", "the config's path must reach the receiver intact");
    test:assertEquals(received.body.id, "task-1");
    test:assertEquals(received.body.status.state, "TASK_STATE_COMPLETED");
    test:assertEquals(received.headers["content-type"], "application/json");
}

@test:Config {}
function testHttpPushNotificationSenderSendsTokenAndAuthHeaders() returns error? {
    HttpPushNotificationSender sender = new ({validateUrl: false});
    Error? result = sender.send({
        url: string `http://localhost:${PUSH_SENDER_TEST_PORT}/webhook/receiver`,
        token: "corr-42",
        authentication: {scheme: "Bearer", credentials: "secret-token"}
    }, sampleTask());
    test:assertTrue(result is ());

    CapturedWebhookCall received = <CapturedWebhookCall>takeLastWebhookCall();
    test:assertEquals(received.headers["x-a2a-notification-token"], "corr-42",
            "config.token must round-trip as the correlation header");
    test:assertEquals(received.headers["authorization"], "Bearer secret-token",
            "config.authentication must build a standard Authorization header");
}

@test:Config {}
function testHttpPushNotificationSenderRejectsDisallowedUrlBeforeSending() returns error? {
    HttpPushNotificationSender sender = new ();
    Error? result = sender.send({url: "http://127.0.0.1:9/unreachable"}, sampleTask());
    test:assertTrue(result is Error, "a loopback URL must be rejected before any connection is attempted");
}

@test:Config {}
function testHttpPushNotificationSenderValidationCanBeDisabled() returns error? {
    // Loopback is where the real receiver in this test file actually
    // listens -- proving validateUrl: false genuinely lets a deployment
    // reach an internal host, not just that the flag exists.
    HttpPushNotificationSender sender = new ({validateUrl: false});
    Error? result = sender.send({url: string `http://localhost:${PUSH_SENDER_TEST_PORT}/webhook/receiver`},
            sampleTask());
    test:assertTrue(result is (), "validateUrl: false must allow a loopback webhook through");
}

@test:Config {}
function testHttpPushNotificationSenderUnreachableHostIsAnError() returns error? {
    HttpPushNotificationSender sender = new ({validateUrl: false});
    Error? result = sender.send({url: "http://localhost:1/nobody-listens-here"}, sampleTask());
    test:assertTrue(result is Error, "an unreachable webhook must return an Error, not panic or hang");
}
