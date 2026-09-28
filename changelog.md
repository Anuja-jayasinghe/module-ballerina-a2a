# Change Log

This file documents all significant changes made to the Ballerina A2A package across releases.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- [Introduce `ballerina/a2a`, an A2A (Agent2Agent) Protocol Client over HTTP+JSON](https://github.com/ballerina-platform/ballerina-library/issues/9158)
- Add `HttpClient`, Which Resolves an Agent's Card and Connects over the HTTP+JSON Binding
- Add Agent Card Discovery and Parsing via `resolveAgentCard`
- Add Server-Sent Events Streaming for `sendStreamingMessage` and `subscribeToTask`, with Opt-In Automatic Reconnection
- Add Credential Resolution by Security-Scheme Name via `CredentialProvider` and `InMemoryCredentialStore`
- Add the Nine Error Types of Specification Section 5.4 as Distinct Subtypes of `Error`, plus `InternalError` for Unnamed Failures
- Add `Listener`, an A2A Server over the HTTP+JSON Binding, Where a Single `Service.onMessage` Method Is the Whole Agent
- Add `TaskUpdater` for Driving a Task Through Its States, Including Streaming and Input-Required Pauses
- Add `TaskStore` and the Default `InMemoryTaskStore`, Which Enforces Legal State Transitions
- Add Task-Scoped Push-Notification Configuration Storage and an Optional Extended Agent Card to the Server
- Add `TaskOwnerResolver` for Per-Caller Task and Push-Notification-Config Visibility Scoping, per Specification Section 13.1
- Add Real Push-Notification Delivery via `PushNotificationSender`, with `HttpPushNotificationSender` Rejecting Non-Public Webhook URLs by Default per Specification Section 13.2
- Run `onMessage` Detached from the Request That Started It, so a Separate `subscribeToTask` Call Can Follow a Task Still in Progress
- Stream `sendStreamingMessage` and `subscribeToTask` Live, with Correct Multi-Subscriber Fan-Out per Specification Section 3.5.2
- Add Task Continuation via `message.taskId`, per Specification Sections 3.4.2 and 3.4.3
- Honor `SendMessageConfiguration.returnImmediately`, Returning a Task Before `onMessage` Finishes
- Enforce Required Extensions per Specification Sections 3.3.4/4.6.3, via the `A2A-Extensions` Header
- Serve `securityRequirements` in the Correct v1.0 Wire Shape, and Add Agent Card `Cache-Control`/`ETag` Headers per Specification Section 8.6.1
- Add `ListenerConfiguration.streamingCapability`/`pushNotificationsCapability`, Letting a Deployment Deliberately Withhold a Capability This Listener Otherwise Always Implements
- Add `ListenerConfiguration.keepAliveInterval`, Sending SSE Keep-Alive Comments so a Quiet, Long-Running Stream Survives HTTP Idle Timeouts
- Add `ListenerConfiguration.auth`, Authenticating Every Request Except the Public Card with `ballerina/http`'s JWT, OAuth2 Introspection, and File/LDAP Basic Handlers per Specification Section 7.4, with the Authenticated Identity Scoping Tasks per Section 13.1
- Derive the Served Agent Card's `securitySchemes` and `securityRequirements` from `ListenerConfiguration.auth` when the Card Declares Neither, per Specification Sections 7.3 and 13.3
- Add `AuthenticationError` (401) and `AuthorizationError` (403), Typed from the `ErrorInfo` Reason or the Bare Status, with an `AuthenticationError` Carrying the `WWW-Authenticate` Challenges; the Server Maps Both to Their Statuses
- Refuse to Start a `Listener` Configured with `extendedAgentCard` but No `auth`, per Specification Section 13.3 (a Breaking Change for Any Such Configuration)

### Fixed

- Serve the Agent Card's `securitySchemes` in the Specification's Wrapped Shape (`{"httpAuthSecurityScheme": {...}}`, with `location` for an API Key), Instead of the Flat Shape with a `type` Discriminator, per Specification Section 4.5
- A Request to a Path That Is No A2A Operation Is Now a 404 (`METHOD_NOT_FOUND`), and a Request Naming a Tenant the Agent Does Not Serve Is Now a 400 (`INVALID_PARAMS`), Instead of a 500 for Both; the Specification Reserves 5xx for System Failures and an Agent's Own Malformed Response
- A 401 or 403 Is Now an `AuthenticationError` or `AuthorizationError` Instead of an `InternalError` Carrying That Status as Its Code
- `subscribeToTask` on an Already-Terminal Task Now Correctly Answers `UnsupportedOperationError` per Specification Section 3.1.6, Instead of a One-Event Snapshot
- A Panic or Returned `Error` from `onMessage` Now Transitions the Task to `TASK_STATE_FAILED` Instead of Leaving It at Whatever State It Was Left In
