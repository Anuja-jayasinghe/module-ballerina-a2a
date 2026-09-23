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

// The server entry point: a Listener that serves an A2A agent over HTTP+JSON.

import ballerina/http;

# Configuration for an `a2a:Listener`.
public type ListenerConfiguration record {|
    *http:ListenerConfiguration;
    # The store the server keeps its tasks in. Defaults to an in-memory store
    # that does not survive a restart; supply an `a2a:TaskStore` of your own
    # for durable storage.
    TaskStore taskStore = new InMemoryTaskStore();
    # The richer card `getExtendedAgentCard` returns to callers who request
    # it. Unset means the agent does not implement the operation: the
    # derived card declares `capabilities.extendedAgentCard` false, and a
    # request for it fails with `a2a:UnsupportedOperationError`.
    AgentCard? extendedAgentCard = ();
    # Resolves each request's caller to an owner scope, for task-visibility
    # scoping per [specification section 13.1](https://a2a-protocol.org/latest/specification/#131-data-access-and-authorization-scoping). Unset means every task is
    # visible to every caller — this server's behavior before this field
    # existed. See `a2a:TaskOwnerResolver`.
    TaskOwnerResolver? ownerResolver = ();
    # Delivers task updates to registered push-notification webhooks.
    # Defaults to `a2a:HttpPushNotificationSender`, a real HTTP POST — unlike
    # `ownerResolver`, delivery needs no identity this library cannot
    # invent, so it has a working default rather than an optional hook.
    PushNotificationSender pushSender = new HttpPushNotificationSender();
    # Seconds a live `sendStreamingMessage`/`subscribeToTask` stream may sit
    # idle — no event, from a task still being driven — before the server
    # ends it. The backstop for a client that disconnects without the HTTP
    # layer surfacing it as a clean stream close; a healthy long-running
    # task's own events reset this on every one they produce, so raising it
    # only matters for a task that can legitimately sit silent for a long
    # stretch (e.g. paused on `TASK_STATE_INPUT_REQUIRED`) with a
    # subscriber still attached.
    decimal streamIdleTimeout = 300;
|};

# Serves an A2A agent over the HTTP+JSON binding.
#
# Construct it with the agent's `a2a:AgentCard` and a port (or an existing
# `http:Listener`), then attach an `a2a:Service`:
#
# ```ballerina
# listener a2a:Listener agent = new (9090, agentCard = {
#     name: "Weather Agent",
#     description: "Answers weather questions",
#     version: "1.0.0",
#     skills: [],
#     defaultInputModes: ["text"],
#     defaultOutputModes: ["text"],
#     capabilities: {},         // derived by the listener
#     supportedInterfaces: []   // derived by the listener
# });
# ```
#
# The listener serves the card at `/.well-known/agent-card.json`, fills in its
# `supportedInterfaces` with the HTTP+JSON entry at its own address, and
# overrides the capability flags to match what is actually implemented — so a
# card cannot advertise a capability the server does not provide. Pass
# `capabilities: {}` and `supportedInterfaces: []` as placeholders; they are
# replaced.
public isolated class Listener {
    private final http:Listener httpListener;
    private final AgentCard & readonly card;
    private final TaskStore store;
    private final (AgentCard & readonly)? extendedCard;
    private final TaskOwnerResolver? ownerResolver;
    private final PushNotificationSender pushSender;
    private final decimal streamIdleTimeout;
    private DispatcherService? dispatcher = ();

    # Creates a Listener.
    #
    # + listenTo - A port, or an existing `http:Listener` to mount on
    # + agentCard - The agent's card; `supportedInterfaces` and `capabilities`
    #               are derived, so a caller supplies identity, skills, and I/O
    #               modes
    # + config - Listener configuration, including the task store and the
    #            extended card
    # + return - An `a2a:Error` if the card is invalid or the HTTP listener
    #            cannot be created
    public isolated function init(int|http:Listener listenTo, AgentCard agentCard,
            *ListenerConfiguration config) returns Error? {
        if listenTo is http:Listener {
            self.httpListener = listenTo;
        } else {
            http:ListenerConfiguration httpConfig = {};
            http:Listener|error created = new (listenTo, httpConfig);
            if created is error {
                return wrapTransportError(created);
            }
            self.httpListener = created;
        }
        self.store = config.taskStore;
        AgentCard? extended = config.extendedAgentCard;
        self.extendedCard = extended is AgentCard ? extended.cloneReadOnly() : ();
        self.card = deriveServedCard(agentCard, self.extendedCard is AgentCard).cloneReadOnly();
        self.ownerResolver = config.ownerResolver;
        self.pushSender = config.pushSender;
        self.streamIdleTimeout = config.streamIdleTimeout;
    }

    # Attaches an `a2a:Service` to serve.
    #
    # One service per listener in this release. The service's `onMessage` is
    # the agent's logic; the listener runs the rest of the protocol around it.
    #
    # + a2aService - The service to serve
    # + name - Ignored; the A2A paths are fixed by the specification
    # + return - An `a2a:Error` if attachment fails
    public isolated function attach(Service a2aService, string[]|string? name = ()) returns error? {
        TaskExecutionRegistry registry = new;
        DefaultHandler handler = new (a2aService, self.store, self.extendedCard, self.pushSender, registry,
                self.streamIdleTimeout);
        DispatcherService dispatcherService = new (self.card, handler, self.ownerResolver);
        lock {
            self.dispatcher = dispatcherService;
        }
        error? result = self.httpListener.attach(dispatcherService, "/");
        if result is error {
            return wrapTransportError(result);
        }
    }

    # Detaches the attached service.
    #
    # + a2aService - The service to detach
    # + return - An `a2a:Error` if detachment fails
    public isolated function detach(Service a2aService) returns error? {
        DispatcherService? dispatcherService;
        lock {
            dispatcherService = self.dispatcher;
        }
        if dispatcherService is DispatcherService {
            error? result = self.httpListener.detach(dispatcherService);
            if result is error {
                return wrapTransportError(result);
            }
        }
    }

    # Starts the listener.
    #
    # + return - An `a2a:Error` if the listener could not start
    public isolated function 'start() returns error? {
        error? result = self.httpListener.'start();
        if result is error {
            return wrapTransportError(result);
        }
    }

    # Stops the listener, letting in-flight requests finish.
    #
    # + return - An `a2a:Error` if the stop failed
    public isolated function gracefulStop() returns error? {
        error? result = self.httpListener.gracefulStop();
        if result is error {
            return wrapTransportError(result);
        }
    }

    # Stops the listener immediately, dropping in-flight requests.
    #
    # + return - An `a2a:Error` if the stop failed
    public isolated function immediateStop() returns error? {
        error? result = self.httpListener.immediateStop();
        if result is error {
            return wrapTransportError(result);
        }
    }
}

# Derives the card the server actually publishes from the one the developer
# supplied.
#
# The developer gives identity, skills, and I/O modes. This forces the
# `supportedInterfaces` to a single HTTP+JSON v1.0 entry — the only binding and
# version this server speaks — and sets the capability flags to what is
# implemented, so the card never claims a capability the server lacks. In this
# release that is: streaming on (sendStreamingMessage/subscribeToTask); push
# notifications on (the config CRUD operations plus real webhook delivery via
# the configured `a2a:PushNotificationSender`, `a2a:HttpPushNotificationSender`
# by default); extended card on only when the developer configured one.
#
# `extensions` is left exactly as the developer declared it, not derived --
# unlike the other three flags, this server has no way to know which
# extensions the developer's `onMessage` actually implements, so it cannot
# second-guess (or silently drop) that declaration the way it can for
# capabilities it fully owns.
#
# + supplied - The card the developer passed
# + extendedCardConfigured - Whether `ListenerConfiguration.extendedAgentCard`
#                            was set
# + return - The card to serve
isolated function deriveServedCard(AgentCard supplied, boolean extendedCardConfigured) returns AgentCard {
    AgentCard card = supplied.clone();
    card.supportedInterfaces = [
        {url: "", protocolBinding: HTTP_JSON, protocolVersion: A2A_PROTOCOL_VERSION}
    ];
    card.capabilities = {
        streaming: true,
        pushNotifications: true,
        extensions: supplied.capabilities.extensions,
        extendedAgentCard: extendedCardConfigured
    };
    return card;
}
