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

// Specification rules that hold regardless of how a value reached us.
//
// These are protocol requirements, not transport concerns: the same rule
// applies to a Message built by a caller and to one decoded off any
// binding's wire. Kept out of the transport client for that reason, so the
// bindings still to come share them rather than restating them.

# Enforces non-emptiness on the two arrays the specification actually
# requires it for.
#
# Section 5.7 contains a blanket sentence -- "Arrays marked as required MUST
# contain at least one element" -- which cannot be read literally. The
# specification's own canonicalization example in section 8.4.1 publishes a
# conformant AgentCard carrying `"skills": []` and annotates it "REQUIRED
# field -> include", with a canonical output that keeps the empty array. A
# rule the specification's own example violates is not the rule: REQUIRED
# means the field must be *present*, which the type system already enforces.
#
# Non-emptiness is enforced only where the specification says so per field,
# or where the reference implementation corroborates it:
#
#   Artifact.parts  - the proto states "Must contain at least one part", the
#                     only such statement in the whole file; a2a-java
#                     enforces it (Artifact.java:52)
#   Message.parts   - no proto statement, but it is the message's content
#                     container and a2a-java enforces it (Message.java:70)
#
# a2a-java has no non-empty check on AgentCard or AgentSkill at all, which
# matches the section 8.4.1 example.
#
# Validated in both directions: section 5.7 asks implementations to "reject
# messages with missing required fields" -- messages, not only responses --
# and checking outbound turns a network round trip and whatever error the
# agent chooses into an immediate, local, precise one.
#
# + name - the field's dotted name, for the message
# + length - the array's actual length
# + inbound - true when validating what an agent sent us, false for what a
#             caller is about to send
# + return - an error when the array is empty, otherwise nil
isolated function requireNonEmpty(string name, int length, boolean inbound) returns Error? {
    if length > 0 {
        return ();
    }
    string message = string `${name} is a required array and must contain at least one element `
        + string `(specification section 5.7)`;
    // Inbound is the agent's fault; outbound is the caller's. InternalError
    // is this library's catch-all for a client-side precondition failure --
    // the specification defines no error for one, since section 3.3.2 and
    // section 5.4 both describe server behaviour, and the same choice is
    // already made by outboundPartVariantError.
    return inbound
        ? invalidAgentResponse(message)
        : error InternalError(message, message = message);
}

# Validates a Message a caller is about to send.
#
# + message - the message to check
# + return - an error when it violates a specification requirement
isolated function validateOutboundMessage(Message message) returns Error? {
    check requireNonEmpty("Message.parts", message.parts.length(), false);
    foreach Part part in message.parts {
        int variants = countSetPartVariants(part);
        if variants != 1 {
            error variantError = outboundPartVariantError(variants);
            string m = variantError.message();
            return error InternalError(m, message = m);
        }
    }
    return ();
}

# Validates a Task an agent sent us, and the artifacts and history it carries.
#
# + task - the decoded task
# + return - an error when it violates a specification requirement
isolated function validateInboundTask(Task task) returns Error? {
    foreach Artifact artifact in task.artifacts ?: [] {
        check requireNonEmpty("Artifact.parts", artifact.parts.length(), true);
    }
    foreach Message historyMessage in task.history ?: [] {
        check requireNonEmpty("Message.parts", historyMessage.parts.length(), true);
    }
    return ();
}
