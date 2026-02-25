# Developer Setup Guide

This guide describes how to get Atom OS up and running for local development.

## Prerequisites

Ensure you have the following installed on your system:
- **Rust Toolchain:** (latest stable) via `rustup`.
- **Python 3.10+:** with `pip` and `poetry` (or `pipenv`).
- **SurrealDB:** Version 2.x or latest.
- **Protobuf Compiler:** `protoc` (used by the gRPC bridge).

## Setting up the Database

Atom OS relies heavily on SurrealDB.
1. Start a local SurrealDB instance:
   ```bash
   surreal start file://local_data.db --user root --pass root
   ```
2. The initial schemas will be migrated automatically when the `atomos-db` client connects for the first time.

## Building the Core Services

The core managers are written in Rust. From the repository root:
```bash
cargo build --release
```

To run individual tests:
```bash
cargo test -p context-manager
```

## Setting up the Python Agent Service

The LLM logic and LangChain integrations live in `core/atomos-agents`.
```bash
cd core/atomos-agents
pip install -r requirements.txt
# Alternatively, set up your preferred virtualenv.
```

## Running the OS Stack Locally

Typically, for local development outside the full ISO build, you will run the desktop applets, the Rust bridge, and the Python server simultaneously.

1. **Start SurrealDB:** (as shown above)
2. **Start Python Agents:**
   ```bash
   cd core/atomos-agents
   python -m atomos_agents.main
   ```
3. **Start Rust Core Managers:** (Sync, Context, Task)
   ```bash
   # You generally run them as detached services or in a foreman/tmux layout
   cargo run -p sync-manager
   ```

*Note: The `Security Manager` applies strict sandboxing policies. For local iterative development, you can set `ATOMOS_DEV=1` environment variable to bypass Kata container requirements.*
