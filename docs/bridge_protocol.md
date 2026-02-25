# Bridge Protocol (`bridge.proto`)

## Overview
The Atom OS Bridge allows Rust clients (like Applets) to interface with the Python-based Deep Agent subsystem. It works over a standard gRPC connection.

## Message Types
- `InvokeAgentRequest`: Includes the prompt string, initial chat history, and any context overrides.
- `AgentResponseStream`: Streams back tokens, UI rendering JSON descriptions, tool invocation requests, and internal planning thought notes.
- `RegisterTool`: Informs the Python agent about an OS-native tool available for use via the bridge.
- `CreateSubagent`: Defines a child sub-agent with a limited set of memory and specific specialized instructions.

## Bi-Directional Streaming
The most important RPC is `InvokeStream`. The client opens a stream, sends the user intent, and then the server streams back tokens. If the agent needs to invoke a host tool (e.g. read the terminal), it sends a `ToolCall` message on the stream. The client executes it and replies with a `ToolResult` message.
