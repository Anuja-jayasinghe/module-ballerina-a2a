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

const int RETRY_ATTACH_TEST_PORT = 19313;

isolated service class RootBlocker {
    *http:Service;

    isolated resource function get [string... path]() returns string => "taken";
}

// If mounting the card service fails, a retried attach must mount it, or the
// agent is served without a card to discover it by.
@test:Config {}
function testARetriedAttachMountsTheCardAfterTheCardServiceFailed() returns error? {
    http:Listener shared = check new (RETRY_ATTACH_TEST_PORT);
    RootBlocker blocker = new;
    check shared.attach(blocker);
    RestListener agentListener = check new (shared);
    FullService agent = new (new DefaultHandler(new CountingAgent()), authTestCard);

    error? first = agentListener.attach(agent);
    test:assertTrue(first is error, "the card service cannot mount while / is taken");

    check shared.detach(blocker);
    check agentListener.attach(agent);
    check shared.'start();
    http:Client cardClient = check new (string `http://localhost:${RETRY_ATTACH_TEST_PORT}`, cache = {enabled: false});
    http:Response card = check cardClient->get("/.well-known/agent-card.json");
    test:assertEquals(card.statusCode, 200, "the retried attach must mount the card");
    check shared.gracefulStop();
}
