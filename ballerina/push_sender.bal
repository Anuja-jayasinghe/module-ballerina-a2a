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

// Delivers task updates to registered push-notification webhooks. Mirrors
// owner_resolver.bal's shape -- a pluggable, single-method isolated object
// -- but unlike TaskOwnerResolver (which needs an identity source this
// library cannot invent), delivery has one sensible universal default: POST
// to the registered URL. That default is HttpPushNotificationSender, below.

# Delivers one task update to one registered webhook.
#
# `a2a:DefaultHandler` calls this once per registered
# `a2a:TaskPushNotificationConfig` whenever a task it drives reaches a new
# state -- fire-and-forget: a delivery failure is not surfaced as the
# triggering operation's own error, matching every reference SDK's posture.
# Implement this to change delivery semantics entirely (a queue, a
# different retry policy, a non-HTTP transport); to only change how a
# webhook URL is validated or how the request is built, configure
# `a2a:HttpPushNotificationSender` instead of replacing it.
public type PushNotificationSender isolated object {

    # Delivers one update.
    #
    # + config - The webhook to call, including its `token` and
    #            `authentication`, if set
    # + task - The task's state at the moment of this call
    # + return - An `a2a:Error` if delivery failed; callers are expected to
    #            log and continue, not fail the operation that triggered it
    public isolated function send(TaskPushNotificationConfig config, Task task) returns Error?;
};

# Configuration for `a2a:HttpPushNotificationSender`.
public type PushNotificationSenderConfiguration record {|
    # Per-request timeout, in seconds
    decimal timeout = 10;
    # Whether to reject a webhook URL resolving to a loopback, link-local,
    # or private address before sending -- specification section 13.2's
    # SSRF-protection obligation. On by default, matching the reference
    # Java and Go SDKs over Python's opt-in stance; turn off for a
    # deployment whose webhooks legitimately live on a private network.
    boolean validateUrl = true;
|};

# The default `a2a:PushNotificationSender`: an HTTP POST of the task to the
# registered URL.
public isolated class HttpPushNotificationSender {
    *PushNotificationSender;

    private final decimal timeout;
    private final boolean validateUrl;

    # + config - Delivery configuration
    public isolated function init(*PushNotificationSenderConfiguration config) {
        self.timeout = config.timeout;
        self.validateUrl = config.validateUrl;
    }

    # + config - The webhook to call
    # + task - The task's state at the moment of this call
    # + return - An `a2a:Error` if delivery failed
    public isolated function send(TaskPushNotificationConfig config, Task task) returns Error? {
        // Real delivery lands in a following change; this commit only
        // wires the type through so nothing downstream depends on a
        // not-yet-existing send().
        return;
    }
}
