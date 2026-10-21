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

import ballerina/test;

final Gate artifactGate = new;

// Adds an artifact, then waits to be released before completing.
isolated class ArtifactThenWaitAgent {
    *AgentExecutor;

    public isolated function execute(RequestContext context, TaskUpdater updater) returns Message|Error? {
        check updater.working();
        check updater.addArtifact([{text: "partial"}]);
        artifactGate.advanceTo(1);
        artifactGate.awaitStep(2);
        check updater.complete();
        return;
    }
}

// An artifact a subscriber has been told about must be in the stored task too,
// while the agent is still working.
@test:Config {}
function testAnAddedArtifactIsStoredBeforeTheTaskEnds() returns error? {
    DefaultHandler handler = new (new ArtifactThenWaitAgent());
    Context context = {headers: {}};

    Task|Message|Error sent = handler.sendMessage(context,
            {message: {messageId: "artifact-1", role: ROLE_USER, parts: [{text: "go"}]}, configuration: {returnImmediately: true}});
    if sent !is Task {
        test:assertFail("expected the task back immediately");
    }
    artifactGate.awaitStep(1);
    Task working = check handler.getTask(context, {id: sent.id});
    test:assertEquals(working.status.state, TASK_STATE_WORKING);
    string[] texts = from Artifact artifact in working.artifacts ?: [] select artifact.parts[0]?.text ?: "";
    test:assertEquals(texts, ["partial"], "getTask must show the artifact the stream already announced");
    artifactGate.advanceTo(2);
}
