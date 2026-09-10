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

// Reading an AgentCard's declared security model, and recognising the
// spec's in-task authorization signal.
//
// Everything here is read-only and advisory. Two deliberate boundaries,
// both forced by the protocol rather than chosen:
//
// 1. A client cannot know which skill will serve a given call. `Message`
//    carries no skill identifier - not in this library's type, and not in
//    the spec's own `a2a.proto` - so the agent alone decides which skill
//    handles a message. Per-skill credentials therefore cannot be selected
//    automatically at send time; a caller reads what a skill requires and
//    decides for itself. `CredentialProvider` (auth.bal) resolves against
//    the card-level requirements for exactly this reason.
// 2. Enforcing that a guarded skill is only reachable with a credential is
//    the *server's* duty, per spec section 7.5 ("authorization logic is
//    implementation-specific and MAY consider: specific skills
//    requested") and section 13.1 ("servers MUST implement authorization
//    checks on every request"). This library is a client; it cannot and
//    does not enforce anything.

# The effective security requirements for one of an agent's skills.
#
# Requirements follow the same OR-of-ANDs model used at the AgentCard
# level: the returned list is an OR - satisfying any single entry is
# enough - and each entry is a map of scheme names that must *all* be
# satisfied together. Pass an entry to `resolveSecuritySchemes` to learn
# what those scheme names concretely mean.
#
# A skill declaring no requirements of its own inherits the card's, matching
# OpenAPI's handling of an absent operation-level `security`. A skill meaning
# "public, overriding the card" cannot be expressed — the wire format carries
# no presence information to distinguish it from declaring nothing.
#
# + card - The agent's card, public or extended
# + skillId - The `id` of the skill to look up
# + return - The skill's own requirements, or the card-level requirements if
#            it declares none, or an `a2a:Error` if no skill has this id
public isolated function skillSecurityRequirements(AgentCard card, string skillId)
        returns SecurityRequirement[]|Error {
    foreach AgentSkill skill in card.skills {
        if skill.id != skillId {
            continue;
        }
        SecurityRequirement[] skillRequirements = skill.securityRequirements ?: [];
        if skillRequirements.length() > 0 {
            return skillRequirements.clone();
        }
        return (card.securityRequirements ?: []).clone();
    }
    string message = string `the agent card declares no skill with id "${skillId}"`;
    return error Error(message, message = message);
}

# Resolves one security requirement's scheme names against the card's
# declared `securitySchemes`.
#
# A `SecurityRequirement` names schemes but does not describe them - the
# name is arbitrary, chosen by whoever wrote the card, so `"bearer-admin"`
# says nothing on its own about whether a bearer token, an API key, or a
# client certificate is wanted. This turns those names into the typed
# `SecurityScheme` values that do say, so a caller can prepare the right
# credential rather than guessing.
#
# Every name in the requirement must resolve. A requirement naming a scheme
# the card never declared is a malformed card, and is reported rather than
# quietly dropped - silently ignoring it would leave a caller believing it
# had satisfied a requirement it had not.
#
# + card - The agent's card, whose `securitySchemes` are the lookup source
# + requirement - One entry from `skillSecurityRequirements` or from
#                 `card.securityRequirements`
# + return - Each named scheme, keyed by its name; an `Error` if the
#            requirement names a scheme the card does not declare
public isolated function resolveSecuritySchemes(AgentCard card, SecurityRequirement requirement)
        returns map<SecurityScheme>|Error {
    map<SecurityScheme> resolved = {};
    foreach string schemeName in requirement.keys() {
        SecurityScheme? scheme = card.securitySchemes[schemeName];
        if scheme is () {
            string message = string `security requirement names "${schemeName}", `
                + string `but the agent card declares no such security scheme`;
            return error Error(message, message = message);
        }
        resolved[schemeName] = scheme.clone();
    }
    return resolved;
}

# Whether the agent has paused this task to wait for authorization.
#
# In-Task Authorization (specification section 7.6) is how per-skill
# authorization surfaces at runtime, since a client cannot declare up front
# which skill it is invoking: an agent needing a credential it does not have
# parks the task in `TASK_STATE_AUTH_REQUIRED` and waits.
#
# The state is not terminal, so a streaming call stays open across the pause.
# Section 7.6.2 leaves the response to you — send a message to the same
# `taskId`, satisfy the request out of band, or delegate onward. Use
# `a2a:authorizationPrompt` to read what the agent asked for.
#
# + task - The task to inspect
# + return - Whether the task is waiting on authorization
public isolated function isAuthorizationRequired(Task task) returns boolean {
    return task.status.state == TASK_STATE_AUTH_REQUIRED;
}

# The agent's explanation of the authorization it is waiting for.
#
# Specification section 7.6.1 requires an agent entering
# `TASK_STATE_AUTH_REQUIRED` to attach a status message describing what it
# needs, unless that was agreed out of band or through an extension — so this
# is normally present, and legitimately absent in those two cases.
#
# + task - The task to inspect
# + return - The attached prompt, or `()` if the task is not awaiting
#            authorization or the agent attached no message
public isolated function authorizationPrompt(Task task) returns Message? {
    if !isAuthorizationRequired(task) {
        return ();
    }
    return task.status?.message;
}
