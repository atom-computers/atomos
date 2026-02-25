# Sync Manager

## Overview
The **Sync Manager** keeps Atom OS updated by connecting to external data sinks and feeding them into the shared `atomos-db`. It manages everything from the local file system to applet conversation data and MCP (Model Context Protocol) servers.

## Primary Responsibilities
- **Local File Syncing:** Uses the external Python `sync/` service (powered by CocoIndex) to read documents, generate `SentenceTransformerEmbed` embeddings, and inject them into `atomos/filesystem/document`.
- **MCP Discovery & Resources:** Dynamically tracks available MCP servers over mDNS and ensures their resources/tools are exposed system-wide and synced.
- **Applet Conversations:** Captures and ingests `.ron`-based history from internal OS experiences.
- **Contacts Deduplication:** Aggregates and merges contact/identity objects from multiple providers.

## Getting Started
It relies on the underlying SurrealDB connection and usually connects via local UNIX sockets or `localhost`.
```bash
cargo run -p sync-manager
```
