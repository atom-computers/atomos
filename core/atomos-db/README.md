# Atom OS DB Layer (`atomos-db`)

## Overview
This core crate provides the data access layer for Atom OS. It serves as a wrapper over the **SurrealDB** client, handling connections, pooling, data schemas, migrations, and change-feed subscriptions.

## Features
- Connection pooling and auto-reconnects to `surreal://`
- Built-in schema creation and initial deployment for multiple namespace tables (`filesystem`, `context`, `tasks`, etc.)
- Full-text and vector RAG querying bindings
- SurrealDB Live Query streams for responsive updates within Sync and Task managers.

## Developer Usage

```rust
use atomos_db::SurrealClient;

// Initialize the shared client pool
let db = SurrealClient::new("root", "root", "file://local_data.db").await?;

// Connect to a namespace/database
db.use_ns("atomos").use_db("main").await?;
```
