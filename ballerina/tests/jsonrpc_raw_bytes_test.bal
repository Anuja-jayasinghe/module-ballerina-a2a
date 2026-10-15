import ballerina/http;
import ballerina/test;

const int RAW_BYTES_TEST_PORT = 19283;

isolated class RawArtifactAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater->addArtifact([{raw: "tck".toBytes(), mediaType: "text/plain", filename: "out.txt"}]);
        check updater->complete();
        return;
    }
}

final http:Listener rawBytesRpcHttp = check new (RAW_BYTES_TEST_PORT);
listener JsonRpcListener rawBytesRpcListener = new (rawBytesRpcHttp);

@test:BeforeSuite
function startRawBytesServers() returns error? {
    DefaultHandler handler = new (new RawArtifactAgent());
    check rawBytesRpcListener.attach(new RpcService(handler, rpcTestCard));
}

// "tck" is `dGNr` in base64: a task fetched over JSON-RPC carries it as a
// string, whichever spelling of the field names the client used.
@test:Config {}
function testARawPartIsBase64InAFetchedTaskOverJsonRpc() returns error? {
    json sent = check rpcCall(RAW_BYTES_TEST_PORT, "SendMessage", rpcSendParams("raw-rpc-1"));
    string taskId = check (check sent.result.task.id).ensureType();

    json fetched = check rpcCall(RAW_BYTES_TEST_PORT, "GetTask", {task_id: taskId, id: taskId});
    json[] artifacts = <json[]>check fetched.result.artifacts;
    json[] parts = <json[]>check artifacts[0].parts;
    test:assertEquals(check parts[0].raw, "dGNr");
}
