# Ballerina A2A Module Examples

## Overview

Runnable examples demonstrating `ballerina/a2a`'s client this module
ships the HTTP+JSON binding at protocol v1.0, client side only.

### Call an Agent

Discovers a remote agent's Agent Card, connects, sends a message, and
handles both reply shapes (`a2a:Task` or a direct `a2a:Message`). Point it
at any A2A HTTP+JSON v1.0 agent defaults to the official
[`dice_agent_rest`](https://github.com/a2aproject/a2a-samples/tree/main/samples/python/agents/dice_agent_rest)
sample from [`a2aproject/a2a-samples`](https://github.com/a2aproject/a2a-samples).
See [`call-an-agent/README.md`](call-an-agent/README.md).
