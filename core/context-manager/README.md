# Context Manager

## Overview
The **Context Manager** is the intelligence hub for understanding a user's digital environment. It actively scans the data fetched by the Sync Manager to auto-discover personal and work project scopes, keeping track of active projects based on filesystem activity.

## Key Sub-components
- **Project Discovery:** Analyzes repositories (looking for `Cargo.toml`, `package.json`, `.git`) to establish project boundaries.
- **Activity Tracker:** Monitors file modification times to determine which contexts are active and boosts their scoring.
- **Context Summarization:** Builds multi-modal summaries of what the user is working on, persisting them into SurrealDB.
- **RAG Pre-prompt Builder:** Fetches context-aware embedding similarities and dynamically assembles system prompts for the Python Deep Agents.
