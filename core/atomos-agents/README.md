# Atom OS Agents (`atomos-agents`)

## Overview
The Python half of the AI system, leveraging LangChain primitives. This is a gRPC server that listens for agent invocations from the `atomos-bridge`.

## Deep Agents Integration
It exposes the `create_deep_agent` factory builder:
- **Middleware:** Implements memory, summarization, tool injection, and human-in-the-loop loops.
- **Subagents:** Prepares specific sub-agent instances (Research, Code, Automation) depending on user routing.
- **Tools:** Exposes OS-level tools like filesystem access, MCP integrations, browser drivers, and raw SurrealDB querying (scoped to safety).

## Usage
Run the server locally:
```bash
python -m atomos_agents.main
```
