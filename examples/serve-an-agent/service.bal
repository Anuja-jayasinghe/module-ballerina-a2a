import ballerina/a2a;
import ballerina/io;

configurable int agentPort = 9090;

// Declared at module level: a listener declared inside `main` does not
// keep the program alive. `capabilities` and `supportedInterfaces` here
// are placeholders -- the listener replaces both with what it actually
// serves, so the published card can never advertise something this agent
// does not do.
listener a2a:Listener agent = new (agentPort, agentCard = {
    name: "Weather Agent",
    description: "Answers weather questions",
    version: "1.0.0",
    skills: [
        {id: "forecast", name: "Forecast", description: "Multi-day forecasts", tags: ["weather"]}
    ],
    defaultInputModes: ["text"],
    defaultOutputModes: ["text"],
    capabilities: {},
    supportedInterfaces: []
});

// `onMessage` is the entire agent: the listener runs the rest of the
// protocol around it -- getTask/cancelTask/listTasks over the task this
// creates, sendStreamingMessage/subscribeToTask as Server-Sent Events, the
// push-notification configuration operations, the well-known discovery
// endpoint, and version/capability gating.
isolated service class WeatherAgent {
    *a2a:Service;

    isolated remote function onMessage(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        // --- real agent logic goes here; this example hardcodes a reply ---
        check updater->working();
        check updater->addArtifact([{text: "Sunny, 22°C"}]);
        check updater->complete();
        return ();
    }
}

// A module-level `function init()` (not `main`) because `agent` is a
// module-level listener, declared above so the program stays alive; this
// runs automatically once every module-level variable, including `agent`
// itself, has finished initialising.
function init() returns error? {
    check agent.attach(new WeatherAgent());
    io:println(string `Weather Agent listening on http://localhost:${agentPort}`);
}
