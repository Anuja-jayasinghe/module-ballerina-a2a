import ballerina/test;

isolated service class ProbeService {
    isolated resource function post message\:send(Context context, SendMessageRequest request)
            returns Task|Message|Error {
        return error InternalError("sent by " + (context?.tenant ?: "none"));
    }

    isolated resource function get tasks/[string id](GetTaskRequest request) returns Task|Error {
        return error InternalError("get " + id + " " + request.id);
    }

    isolated resource function post tasks/[string id]/cancel(CancelTaskRequest request) returns Task|Error {
        return error InternalError("cancel " + id);
    }
}

@test:Config {}
function describesAServicesResources() {
    string[] entries = describeResources(new ProbeService());
    test:assertTrue(entries.indexOf("post message:send +context") is int, entries.toString());
    test:assertTrue(entries.indexOf("get tasks/*") is int, entries.toString());
    test:assertTrue(entries.indexOf("post tasks/*/cancel") is int, entries.toString());
}

@test:Config {}
function invokesAResourceWithPathParametersAndContext() {
    ProbeService probe = new;
    anydata|stream<StreamResponse, Error?>|error cancelled =
        invokeResource(probe, "post", "tasks/*/cancel", ["t-9"], {headers: {}, tenant: "acme"}, <CancelTaskRequest>{id: "t-9"});
    test:assertTrue(cancelled is error, "expected the resource's error");
    test:assertEquals((<error>cancelled).message(), "cancel t-9");

    anydata|stream<StreamResponse, Error?>|error sent =
        invokeResource(probe, "post", "message:send", [], {headers: {}, tenant: "acme"}, <SendMessageRequest>{message: {messageId: "m", role: ROLE_USER, parts: [{text: "hi"}]}});
    test:assertTrue(sent is error, "expected the resource's error");
    test:assertEquals((<error>sent).message(), "sent by acme");
}
