import ballerina/a2a;
import ballerina/io;

configurable int agentPort = 9090;

isolated class WeatherExecutor {
    *a2a:AgentExecutor;

    public isolated function execute(a2a:RequestContext context, a2a:TaskUpdater updater)
            returns a2a:Message|a2a:Error? {
        check updater->working();
        check updater->addArtifact([{text: "Sunny, 22°C"}]);
        check updater->complete();
        return;
    }
}

@a2a:ServiceConfig {
    agentCard: {
        name: "Weather Agent",
        description: "Answers weather questions",
        version: "1.0.0",
        provider: {organization: "Example Co", url: "https://example.com"},
        skills: [
            {id: "forecast", name: "Forecast", description: "Multi-day forecasts", tags: ["weather"]}
        ],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        capabilities: {},
        supportedInterfaces: []
    }
}
isolated service /rest on new a2a:HttpListener(agentPort) {

    private final a2a:DefaultHandler handler = new (new WeatherExecutor());

    isolated remote function onSendMessage(a2a:Context context, a2a:SendMessageRequest request)
            returns a2a:Task|a2a:Message|a2a:Error {
        return self.handler.sendMessage(context, request);
    }

    isolated remote function onSendStreamingMessage(a2a:Context context, a2a:SendMessageRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error {
        return self.handler.sendStreamingMessage(context, request);
    }

    isolated remote function onSubscribeToTask(a2a:Context context, a2a:SubscribeToTaskRequest request)
            returns stream<a2a:StreamResponse, a2a:Error?>|a2a:Error {
        return self.handler.subscribeToTask(context, request);
    }

    isolated remote function onGetTask(a2a:Context context, a2a:GetTaskRequest request)
            returns a2a:Task|a2a:Error {
        return self.handler.getTask(context, request);
    }

    isolated remote function onListTasks(a2a:Context context, a2a:ListTasksRequest request)
            returns a2a:ListTasksResponse|a2a:Error {
        return self.handler.listTasks(context, request);
    }

    isolated remote function onCancelTask(a2a:Context context, a2a:CancelTaskRequest request)
            returns a2a:Task|a2a:Error {
        return self.handler.cancelTask(context, request);
    }

    isolated remote function onCreateTaskPushNotificationConfig(a2a:Context context,
            a2a:TaskPushNotificationConfig request)
            returns a2a:TaskPushNotificationConfig|a2a:Error {
        return self.handler.createTaskPushNotificationConfig(context, request);
    }

    isolated remote function onGetTaskPushNotificationConfig(a2a:Context context,
            a2a:GetTaskPushNotificationConfigRequest request)
            returns a2a:TaskPushNotificationConfig|a2a:Error {
        return self.handler.getTaskPushNotificationConfig(context, request);
    }

    isolated remote function onListTaskPushNotificationConfigs(a2a:Context context,
            a2a:ListTaskPushNotificationConfigsRequest request)
            returns a2a:ListTaskPushNotificationConfigsResponse|a2a:Error {
        return self.handler.listTaskPushNotificationConfigs(context, request);
    }

    isolated remote function onDeleteTaskPushNotificationConfig(a2a:Context context,
            a2a:DeleteTaskPushNotificationConfigRequest request)
            returns a2a:Error? {
        return self.handler.deleteTaskPushNotificationConfig(context, request);
    }
}

function init() {
    io:println(string `Weather Agent listening on http://localhost:${agentPort}`);
}
