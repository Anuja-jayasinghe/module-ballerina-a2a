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
