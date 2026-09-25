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

import ballerina/http;

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
#
# The body is a `StreamResponse`, as [specification section 4.3.3](https://a2a-protocol.org/latest/specification/#433-push-notification-payload)
# requires -- the task under its `task` key, `{"task": {...}}`, exactly the
# shape a streaming client receives -- so a receiver can tell a task from a
# status or artifact update by the key alone. The media type is
# `application/a2a+json`.
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
        if self.validateUrl {
            check validateWebhookUrl(config.url);
        }

        // HTTP/1.1 forced, not left to negotiate: a webhook receiver is a
        // third party this server does not control, and a server that
        // advertises HTTPS without genuinely supporting HTTP/2 fails
        // negotiation with a generic, undiagnosable connection error --
        // hit directly against a real endpoint earlier in this module's
        // development. A receiver expecting HTTP/2 still speaks HTTP/1.1.
        http:Client|error webhook = new (config.url, httpVersion = http:HTTP_1_1, timeout = self.timeout);
        if webhook is error {
            return wrapTransportError(webhook);
        }

        // The wire envelope, not a bare `task.toJson()`: it is the same
        // StreamResponse shape a live stream carries, and it base64-encodes
        // file bytes the way the rest of the wire does, which `toJson()` on a
        // `byte[]` does not.
        json|error body = wireEnvelopeFor(task);
        if body is error {
            return wrapTransportError(body);
        }

        map<string> headers = {"Content-Type": CONTENT_TYPE_A2A_JSON};
        string? token = config?.token;
        if token is string {
            headers["X-A2A-Notification-Token"] = token;
        }
        AuthenticationInfo? auth = config?.authentication;
        if auth is AuthenticationInfo {
            string? credentials = auth?.credentials;
            if credentials is string {
                headers["Authorization"] = string `${auth.scheme} ${credentials}`;
            }
        }

        http:Response|error result = webhook->post("", body, headers);
        if result is error {
            return wrapTransportError(result);
        }
    }
}

# Rejects a webhook URL by form, per specification section 13.2's
# SSRF-protection obligation -- checked at send time against
# `HttpPushNotificationSender.validateUrl`, not at registration, matching
# the fire-and-forget delivery model: a caller registering a disallowed
# URL still gets a stored config back; the rejection surfaces the same way
# an unreachable webhook does, as a swallowed delivery failure.
#
# Form-level only, deliberately: Ballerina has no stdlib DNS resolver
# (`ballerina/socket` no longer exists; `tcp`/`udp` never hand back a
# resolved address), and this package carries no native Java code by its
# own build convention, so resolving a hostname to an IP is not available
# without a dependency this package does not otherwise need. A host that is
# not itself an IP literal -- `webhook.internal.corp` resolving to a
# private address, for instance -- is not caught here; that DNS-rebinding
# gap is real and left open, the same gap the reference Java SDK's own
# documentation concedes for the same reason.
#
# + url - The webhook URL to check
# + return - An `a2a:Error` if the URL's scheme or host is disallowed
isolated function validateWebhookUrl(string url) returns Error? {
    int? schemeEnd = url.indexOf("://");
    if schemeEnd is () {
        return invalidWebhookUrl(url, "missing a scheme");
    }
    string scheme = url.substring(0, schemeEnd);
    if scheme != "http" && scheme != "https" {
        return invalidWebhookUrl(url, string `scheme "${scheme}" is not http or https`);
    }

    string rest = url.substring(schemeEnd + 3);
    int authorityEnd = rest.length();
    foreach string delimiter in ["/", "?", "#"] {
        int? idx = rest.indexOf(delimiter);
        if idx is int && idx < authorityEnd {
            authorityEnd = idx;
        }
    }
    string authority = rest.substring(0, authorityEnd);

    int? atIdx = authority.lastIndexOf("@");
    string hostPort = atIdx is int ? authority.substring(atIdx + 1) : authority;

    string host;
    if hostPort.startsWith("[") {
        // An IPv6 literal, e.g. "[::1]:8080" -- the brackets disambiguate
        // its embedded colons from a port separator.
        int? closeBracket = hostPort.indexOf("]");
        host = closeBracket is int ? hostPort.substring(1, closeBracket) : hostPort;
    } else {
        int? colonIdx = hostPort.lastIndexOf(":");
        host = colonIdx is int ? hostPort.substring(0, colonIdx) : hostPort;
    }
    string lowerHost = host.toLowerAscii();

    if lowerHost == "localhost" || lowerHost.endsWith(".localhost") || lowerHost.endsWith(".local")
            || lowerHost == "metadata.google.internal" {
        return invalidWebhookUrl(url, string `host "${host}" is disallowed`);
    }
    if isDisallowedIpLiteral(lowerHost) {
        return invalidWebhookUrl(url, string `host "${host}" is a disallowed IP address`);
    }
}

# Whether a host, already known to be an IP literal or plain hostname,
# names a loopback, link-local (which covers the
# `169.254.169.254`-style cloud metadata endpoint), private (RFC 1918),
# carrier-grade-NAT (`100.64.0.0/10`), or IPv6 unique-local/loopback
# address.
#
# + host - The lowercased host, brackets and port already stripped
# + return - Whether the host is a disallowed IP literal
isolated function isDisallowedIpLiteral(string host) returns boolean {
    int[]? octets = parseIPv4(host);
    if octets is int[] {
        int a = octets[0];
        int b = octets[1];
        if a == 127 || a == 0 || a == 10 || (a == 172 && b >= 16 && b <= 31)
                || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && b >= 64 && b <= 127) {
            return true;
        }
        return false;
    }
    // IPv6: loopback, unspecified, and the fc00::/7 unique-local block --
    // whose two /8s, fc00::/8 and fd00::/8, both surface as the host
    // starting "fc" or "fd" in standard (non-compressed-leading-zero)
    // hextet form.
    return host == "::1" || host == "::" || host.startsWith("fc") || host.startsWith("fd");
}

# Parses a dotted-quad IPv4 literal into its four octets, or `()` if `host`
# is not one -- including any plain hostname, which is exactly the case
# this function's caller uses `()` to mean "not an IP literal, nothing more
# to check here."
#
# + host - The candidate host string
# + return - The four octets, or `()` if `host` is not a valid IPv4 literal
isolated function parseIPv4(string host) returns int[]? {
    string[] parts = [];
    string remaining = host;
    while true {
        int? dotIdx = remaining.indexOf(".");
        if dotIdx is () {
            parts.push(remaining);
            break;
        }
        parts.push(remaining.substring(0, dotIdx));
        remaining = remaining.substring(dotIdx + 1);
    }
    if parts.length() != 4 {
        return;
    }
    int[] result = [];
    foreach string part in parts {
        if part.length() == 0 || part.length() > 3 {
            return;
        }
        int|error n = int:fromString(part);
        if n is error || n < 0 || n > 255 {
            return;
        }
        result.push(n);
    }
    return result;
}

# Builds the typed error for a rejected webhook URL.
#
# + url - The rejected URL
# + reason - Why it was rejected
# + return - The typed error
isolated function invalidWebhookUrl(string url, string reason) returns Error {
    string msg = string `push-notification webhook URL "${url}" is not allowed: ${reason}`;
    return error InternalError(msg, message = msg);
}
