import ballerina/http;
import ballerina/test;

const int DETACH_TEST_PORT = 19310;

// Detaching the agent must take its interface off the card and free the path,
// so a replacement can be attached.
@test:Config {}
function testDetachTakesTheInterfaceOffTheCard() returns error? {
    RestListener agentListener = check new (DETACH_TEST_PORT);
    FullService first = new (new DefaultHandler(new CountingAgent()), authTestCard);
    check agentListener.attach(first);
    check agentListener.'start();
    http:Client cardClient = check new (string `http://localhost:${DETACH_TEST_PORT}`, cache = {enabled: false});

    http:Response before = check cardClient->get("/.well-known/agent-card.json");
    test:assertEquals(before.statusCode, 200);

    check agentListener.detach(first);
    http:Response after = check cardClient->get("/.well-known/agent-card.json");
    test:assertEquals(after.statusCode, 404, "a detached agent's card must no longer be served");

    check agentListener.attach(new FullService(new DefaultHandler(new CountingAgent()), authTestCard));
    json card = check cardClient->get("/.well-known/agent-card.json");
    json[] interfaces = check (check card.supportedInterfaces).ensureType();
    test:assertEquals(interfaces.length(), 1, "the replacement is the only interface");
    check agentListener.gracefulStop();
}
