# Task Manager

## Overview
The **Task Manager** is the execution engine for background workflows and agent orchestration in Atom OS. It can be triggered manually, via scheduled cron-like events, or event-bus signals.

## Features
- **Workflow Engine:** A stateful execution runner that can persist and resume multi-step workflows from SurrealDB.
- **Agent Orchestrator:** Manages the lifecycle, concurrency, and result aggregation of sub-agents (via Deep Agents over the bridge).
- **Tool Connectors:** Interfaces natively with browser automation, terminal sandbox connections, and Generative UI streaming endpoints.

## Execution Model
We use isolated agent contexts and prioritize executing commands through Kata Container environments where necessary to ensure system safety. Parallel sub-tasks are mapped to the event bus and awaited asynchronously.
