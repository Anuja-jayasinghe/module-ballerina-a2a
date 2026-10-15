# Ballerina A2A Module Examples: Bring Your Own Handler

## Overview

This example demonstrates how to serve an agent with your own handler
instead of `a2a:DefaultHandler`. The service defines the A2A operations it
supports and answers them from its own class, which keeps its own tasks.
Nothing in it uses `a2a:DefaultHandler`, `a2a:AgentExecutor` or
`a2a:TaskUpdater`.

### Features

- **Your handler, your storage**: `EchoHandler` creates a completed task for
  every message and keeps it in a map. The service only calls it.
- **Define what you support**: the service defines the
  `post message\:send`, `get tasks/[string id]` and `get tasks` resources.
  Every operation it leaves out answers
  `UnsupportedOperationError`, and the card says so: `streaming`,
  `pushNotifications` and `extendedAgentCard` are all `false`, derived from
  the operations that exist.
- **Typed errors**: an unknown task id returns an `a2a:TaskNotFoundError`,
  which the listener serves as a 404 with the `TASK_NOT_FOUND` reason.

## Running the Bring Your Own Handler Example

Start the program using the Ballerina runtime:

```sh
bal run
```

```
Echo Agent listening on http://localhost:9091
```

To run it on a different port:

```sh
bal run -- -ClistenerPort=9999
```

## Calling It

```sh
curl -s http://localhost:9091/rest/message:send \
  -H 'Content-Type: application/json' -H 'A2A-Version: 1.0' \
  -d '{"message": {"messageId": "m1", "role": "ROLE_USER", "parts": [{"text": "hello"}]}}'
```

The reply is a completed task whose artifact says `You said: hello`. Fetch
it, or list every task, with the id it returned:

```sh
curl -s http://localhost:9091/rest/tasks/<task id> -H 'A2A-Version: 1.0'
curl -s http://localhost:9091/rest/tasks -H 'A2A-Version: 1.0'
```

Cancelling a task, or streaming a message, answers `UNSUPPORTED_OPERATION`.

## Code Structure

- **The handler**: `isolated class EchoHandler` builds the `a2a:Task` records
  and stores them. It is an ordinary class: the service decides which of its
  methods answer which operation.
- **The service**: `isolated service on new a2a:RestListener(listenerPort)`
  carries the agent card with `@a2a:ServiceConfig` and defines the three
  operations. Each is one line into the handler. The path names the binding:
  `rest` is HTTP+JSON.
- **What the listener adds**: authentication when configured, the
  well-known card, version checks, and the mapping of the handler's errors
  to HTTP statuses.

To keep the lifecycle, streaming and push notifications of
`a2a:DefaultHandler` and replace only one operation, hold both in the
service and delegate the operations you do not change, as the
[`serve-an-agent`](../serve-an-agent/README.md) example does.
