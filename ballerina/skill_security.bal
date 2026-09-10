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
# ### Why an empty skill-level list means "inherit"
#
# A skill that declares no requirements of its own inherits the card's
# `securityRequirements`. That rule exists because the alternative cannot
# be represented: protobuf3 `repeated` fields carry no presence
# information, so "declares nothing" and "declares an empty list" are
# indistinguishable on the wire (a2a-python's own auth interceptor notes
# the same constraint), and this library's `AgentSkill.securityRequirements`
# defaults to `[]`, losing the distinction on the JSON side too. Treating
# empty as inherit matches OpenAPI's handling of an absent operation-level
# `security`, which is the model A2A borrows from.
#
# The one case this cannot express: a skill meaning "public, overriding the
# card's requirement" has no way to say so. That is a limitation of the
# specification's wire format, not of this function.
#
# + card - the agent's card, public or extended
# + skillId - the `id` of the skill to look up
# + return - the skill's own requirements, or the card-level requirements
#            if the skill declares none; an `Error` if no skill on the card
#            has this id
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
# + card - the agent's card, whose `securitySchemes` are the lookup source
# + requirement - one entry from `skillSecurityRequirements` or from
#                 `card.securityRequirements`
# + return - each named scheme, keyed by its name; an `Error` if the
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
# This is the specification's own mechanism for an agent needing
# permission part-way through a task - section 7.6, In-Task Authorization -
# and it is how per-skill authorization actually surfaces at runtime, since
# a client cannot declare up front which skill it is invoking. An agent
# that needs a credential it does not have transitions the task to
# `TASK_STATE_AUTH_REQUIRED` and waits.
#
# The state is not terminal: a streaming call stays open across the pause
# (see `isTerminalEvent` in sse.bal), so a subscriber keeps receiving events
# once the task resumes.
#
# ### Responding
#
# Section 7.6.2 leaves the response to the client, which may:
#
# - send a message to the same `taskId` to negotiate, correct, or reject
#   the request - `authorizationPrompt` returns what the agent asked for;
# - satisfy the request out of band, after which the agent may resume on
#   its own with no follow-up message needed;
# - delegate onward, if this client is itself an agent serving a task, by
#   moving its own task into `TASK_STATE_AUTH_REQUIRED`.
#
# A client with no open stream risks missing the resume. Section 7.6.2
# names three ways to avoid that: `subscribeToTask`, a push notification
# config, or polling `getTask`.
#
# + task - the task to inspect
# + return - true if the task is waiting on authorization
public isolated function isAuthorizationRequired(Task task) returns boolean {
    return task.status.state == TASK_STATE_AUTH_REQUIRED;
}

# The agent's explanation of the authorization it is waiting for.
#
# Section 7.6.1 requires an agent entering `TASK_STATE_AUTH_REQUIRED` to
# attach a status message describing what it needs, unless that was already
# agreed out of band or through an extension - so this is normally present,
# but legitimately absent in those two cases.
#
# It is a full `Message`, not a string, so an agent can attach structured
# content rather than only prose.
#
# + task - the task to inspect
# + return - the attached prompt, or () if the task is not awaiting
#            authorization or the agent attached no message
public isolated function authorizationPrompt(Task task) returns Message? {
    if !isAuthorizationRequired(task) {
        return ();
    }
    return task.status?.message;
}
