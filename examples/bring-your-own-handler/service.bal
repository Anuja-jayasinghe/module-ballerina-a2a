import ballerina/a2a;
import ballerina/io;
import ballerina/time;
import ballerina/uuid;

configurable int agentPort = 9091;

isolated class EchoHandler {
    private final map<a2a:Task> tasks = {};

    isolated function send(a2a:SendMessageRequest request) returns a2a:Task {
        string text = request.message.parts[0]?.text ?: "";
        string taskId = uuid:createType4AsString();
        a2a:Task task = {
            id: taskId,
            contextId: request.message.contextId ?: uuid:createType4AsString(),
            status: {state: a2a:TASK_STATE_COMPLETED, timestamp: time:utcToString(time:utcNow(3))},
            artifacts: [{artifactId: uuid:createType4AsString(), name: "Echo", parts: [{text: string `You said: ${text}`}]}],
            history: [request.message]
        };
        lock {
            self.tasks[taskId] = task.clone();
        }
        return task;
    }

    isolated function find(string taskId) returns a2a:Task|a2a:TaskNotFoundError {
        lock {
            a2a:Task? task = self.tasks[taskId];
            if task is a2a:Task {
                return task.clone();
            }
        }
        string message = string `no task with id ${taskId}`;
        return error a2a:TaskNotFoundError(message, message = message, code = -32001);
    }

    isolated function findAll() returns a2a:Task[] {
        lock {
            return self.tasks.toArray().clone();
        }
    }
}

@a2a:ServiceConfig {
    agentCard: {
        name: "Echo Agent",
        description: "Echoes what it is told and remembers each exchange as a task",
        version: "1.0.0",
        skills: [{id: "echo", name: "Echo", description: "Repeats the message", tags: ["echo"]}],
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"],
        capabilities: {},
        supportedInterfaces: []
    }
}
isolated service /rest on new a2a:HttpListener(agentPort) {

    private final EchoHandler handler = new;

    isolated remote function onSendMessage(a2a:SendMessageRequest request)
            returns a2a:Task|a2a:Message|a2a:Error {
        return self.handler.send(request);
    }

    isolated remote function onGetTask(a2a:GetTaskRequest request)
            returns a2a:Task|a2a:Error {
        return self.handler.find(request.id);
    }

    isolated remote function onListTasks(a2a:ListTasksRequest request)
            returns a2a:ListTasksResponse|a2a:Error {
        a2a:Task[] tasks = self.handler.findAll();
        return {tasks, nextPageToken: "", pageSize: tasks.length(), totalSize: tasks.length()};
    }
}

function init() {
    io:println(string `Echo Agent listening on http://localhost:${agentPort}`);
}
