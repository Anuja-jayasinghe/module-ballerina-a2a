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

// skill_security.bal: reading a card's per-skill security model, and
// recognising the specification's in-task authorization signal.
//
// Direct unit tests against the public helpers - no client construction,
// no network I/O. `cardWithSecurity` (auth_test.bal) covers the
// card-level-only cases; these build cards carrying real skills.

import ballerina/test;

# Builds a card whose skills carry their own security requirements.
#
# + skills - the skills to declare
# + cardRequirements - card-level securityRequirements, the inheritance
#                      source for a skill declaring none
# + schemes - securitySchemes to declare, keyed by scheme name
# + return - a minimal card carrying exactly those declarations
isolated function cardWithSkills(AgentSkill[] skills, SecurityRequirement[] cardRequirements = [],
        map<SecurityScheme> schemes = {}) returns AgentCard {
    return {
        name: "skilled",
        description: "x",
        version: "1.0.0",
        capabilities: {},
        supportedInterfaces: [{url: "https://agent.example.com", protocolBinding: "JSONRPC", protocolVersion: "1.0"}],
        skills: skills,
        securitySchemes: schemes,
        securityRequirements: cardRequirements,
        defaultInputModes: ["text"],
        defaultOutputModes: ["text"]
    };
}

# Builds a skill with the given id and security requirements.
#
# + id - the skill's id
# + requirements - the skill's own securityRequirements
# + return - a minimal skill
isolated function skillWithSecurity(string id, SecurityRequirement[] requirements = []) returns AgentSkill {
    return {id: id, name: id, description: "x", securityRequirements: requirements, tags: []};
}

@test:Config {}
function testSkillSecurityRequirementsReturnsTheSkillsOwn() returns error? {
    AgentCard card = cardWithSkills(
            [skillWithSecurity("public-qa"), skillWithSecurity("escalate", [{"bearer-admin": []}])],
            [{"bearer-staff": []}]);
    SecurityRequirement[] requirements = check skillSecurityRequirements(card, "escalate");
    test:assertEquals(requirements, <SecurityRequirement[]>[{"bearer-admin": []}],
            "a skill declaring its own requirement must not inherit the card's");
}

@test:Config {}
function testSkillSecurityRequirementsInheritsCardLevelWhenSkillDeclaresNone() returns error? {
    // Proto3 repeated fields carry no presence information, so "declares
    // nothing" and "declares an empty list" are the same value on the
    // wire. Treating empty as inherit matches OpenAPI's handling of an
    // absent operation-level `security`, and is documented on the function.
    AgentCard card = cardWithSkills(
            [skillWithSecurity("public-qa")],
            [{"bearer-staff": []}]);
    SecurityRequirement[] requirements = check skillSecurityRequirements(card, "public-qa");
    test:assertEquals(requirements, <SecurityRequirement[]>[{"bearer-staff": []}]);
}

@test:Config {}
function testSkillSecurityRequirementsIsEmptyWhenNeitherLevelDeclaresAny() returns error? {
    AgentCard card = cardWithSkills([skillWithSecurity("open")]);
    SecurityRequirement[] requirements = check skillSecurityRequirements(card, "open");
    test:assertEquals(requirements.length(), 0);
}

@test:Config {}
function testSkillSecurityRequirementsRejectsUnknownSkillId() {
    AgentCard card = cardWithSkills([skillWithSecurity("known")]);
    SecurityRequirement[]|Error result = skillSecurityRequirements(card, "ghost");
    test:assertTrue(result is Error, "an unknown skill id must be an error, not an empty list");
    if result is Error {
        test:assertTrue(result.message().includes("ghost"),
                "the error must name the skill id that was not found");
    }
}

@test:Config {}
function testSkillSecurityRequirementsDoesNotMutateTheCard() returns error? {
    // The returned list is cloned, so a caller editing it cannot reach
    // back into the card it came from.
    AgentCard card = cardWithSkills([skillWithSecurity("escalate", [{"bearer-admin": []}])]);
    SecurityRequirement[] requirements = check skillSecurityRequirements(card, "escalate");
    requirements.push({"injected": []});
    test:assertEquals((card.skills[0].securityRequirements ?: []).length(), 1,
            "mutating the returned list must not alter the card");
}

@test:Config {}
function testResolveSecuritySchemesNamesTheConcreteKind() returns error? {
    // The point of this function: "bearer-admin" is an arbitrary label
    // until resolved, and says nothing on its own about what to send.
    AgentCard card = cardWithSkills([], [], {
        "bearer-admin": <HttpAuthSecurityScheme>{scheme: "Bearer"},
        "key": <ApiKeySecurityScheme>{'in: "header", name: "X-Key"}
    });
    map<SecurityScheme> resolved = check resolveSecuritySchemes(card, {"bearer-admin": [], "key": []});
    test:assertEquals(resolved.length(), 2);
    test:assertTrue(resolved["bearer-admin"] is HttpAuthSecurityScheme);
    test:assertTrue(resolved["key"] is ApiKeySecurityScheme);
    test:assertEquals((<ApiKeySecurityScheme>resolved["key"]).name, "X-Key");
}

@test:Config {}
function testResolveSecuritySchemesRejectsAnUndeclaredScheme() {
    // Silently dropping this would leave a caller believing it had
    // satisfied a requirement it had not.
    AgentCard card = cardWithSkills([], [], {"known": <HttpAuthSecurityScheme>{scheme: "Bearer"}});
    map<SecurityScheme>|Error result = resolveSecuritySchemes(card, {"known": [], "ghost": []});
    test:assertTrue(result is Error, "a requirement naming an undeclared scheme must be reported");
    if result is Error {
        test:assertTrue(result.message().includes("ghost"),
                "the error must name the scheme the card does not declare");
    }
}

@test:Config {}
function testParsesSecurityRequirementsFromRealV10WireForm() returns error? {
    // Captured from the real a2a-python SDK (1.1.2) by serialising an
    // AgentCard through MessageToJson, so this is the exact shape a real
    // v1.0 agent serves - not a hand-written approximation.
    //
    // v1.0 wraps the requirement in a `schemes` field and encodes each
    // scope list as a StringList object (rendered `{}` when empty), where
    // v0.3/OpenAPI used a bare `{"scheme": ["scope"]}` map.
    json realV10Card = {
        "name": "X",
        "description": "d",
        "version": "0.1.0",
        "capabilities": {"extendedAgentCard": true},
        "supportedInterfaces": [{"url": "http://x", "protocolBinding": "JSONRPC", "protocolVersion": "1.0"}],
        "securitySchemes": {"bearer-staff": {"httpAuthSecurityScheme": {"scheme": "Bearer"}}},
        "securityRequirements": [{"schemes": {"bearer-staff": {}}}],
        "skills": [
            {
                "id": "case-escalation",
                "name": "n",
                "description": "d",
                "securityRequirements": [{"schemes": {"bearer-staff": {"list": ["write"]}}}]
            , "tags": []}
        ]
    , "defaultInputModes": ["text"], "defaultOutputModes": ["text"]};
    AgentCard card = check parseAgentCardBody(realV10Card);

    test:assertEquals((card.securitySchemes ?: {}).length(), 1, "the v1.0 oneof-wrapped scheme must parse");
    test:assertEquals(card.securityRequirements, <SecurityRequirement[]>[{"bearer-staff": []}],
            "a v1.0 card-level securityRequirement must unwrap `schemes` and its empty StringList");
    test:assertEquals(card.skills[0].securityRequirements, <SecurityRequirement[]>[{"bearer-staff": ["write"]}],
            "a v1.0 skill-level securityRequirement must unwrap `schemes` and keep its scopes");

    SecurityRequirement[] resolved = check skillSecurityRequirements(card, "case-escalation");
    test:assertEquals(resolved, <SecurityRequirement[]>[{"bearer-staff": ["write"]}]);
}

@test:Config {}
function testIsAuthorizationRequiredRecognisesOnlyThatState() {
    Task waiting = {id: "t1", status: {state: TASK_STATE_AUTH_REQUIRED}};
    Task working = {id: "t2", status: {state: TASK_STATE_WORKING}};
    Task done = {id: "t3", status: {state: TASK_STATE_COMPLETED}};
    test:assertTrue(isAuthorizationRequired(waiting));
    test:assertFalse(isAuthorizationRequired(working));
    test:assertFalse(isAuthorizationRequired(done));
}

@test:Config {}
function testAuthorizationPromptReturnsTheAgentsAttachedMessage() {
    // Section 7.6.1 requires the agent to explain what it needs, and it is
    // a full Message so the explanation can be structured, not just prose.
    Message prompt = {
        messageId: "m1",
        role: ROLE_AGENT,
        parts: [{"text": "This skill needs an admin token."}]
    };
    Task waiting = {id: "t1", status: {state: TASK_STATE_AUTH_REQUIRED, message: prompt}};
    Message? returned = authorizationPrompt(waiting);
    test:assertTrue(returned is Message);
    test:assertEquals((<Message>returned).messageId, "m1");
}

@test:Config {}
function testAuthorizationPromptIsNilOffTheAuthRequiredState() {
    // A task in some other state may still carry a status message; it is
    // not an authorization prompt, and must not be returned as one.
    Message note = {messageId: "m1", role: ROLE_AGENT, parts: [{"text": "working on it"}]};
    Task working = {id: "t1", status: {state: TASK_STATE_WORKING, message: note}};
    test:assertTrue(authorizationPrompt(working) is (),
            "only a task awaiting authorization has an authorization prompt");
}

@test:Config {}
function testAuthorizationPromptIsNilWhenAgentAttachedNoMessage() {
    // Legitimate per section 7.6.1 when the authorization was negotiated
    // out of band or through an extension.
    Task waiting = {id: "t1", status: {state: TASK_STATE_AUTH_REQUIRED}};
    test:assertTrue(authorizationPrompt(waiting) is ());
}
