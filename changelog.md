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
- Add `RestListener`, an A2A server over the HTTP+JSON binding. The agent is a service attached to it, whose resource functions define the operations it supports (`post message\:send`, `get tasks/[string id]`, ...); the served Agent Card and its capabilities follow from them, and a service that defines only part of a capability is refused when attached. Configure it with `RestListenerConfiguration`: `auth` (surfaced as `AuthenticationError` and `AuthorizationError`), TLS, `publicUrl`, SSE keep-alives and opt-in `validateInputModes`
- Add `DefaultHandler`, a transport-free engine that runs the task lifecycle around an `AgentExecutor`, with pluggable `TaskStore`, `TaskOwnerResolver`, `PushNotificationSender` and event broadcasting, including live streaming and push-notification delivery with retries
