# Atom OS Architecture

Atom OS is built around a set of core Rust managers that intercommunicate via standard mechanisms (such as gRPC) and store state in [SurrealDB](https://surrealdb.com/). It deeply integrates intelligent operations, such as RAG (Retrieval-Augmented Generation), workflows, and agents, into the desktop environment using the COSMIC desktop toolkit.

## System Diagram

```mermaid
graph TD
    subgraph UI Applets
        A[COSMIC Desktop Applets] -->|gRPC / JSON-RPC| B(Bridge Client)
    end

    subgraph Core Managers
        B -->|gRPC| Python[Deep Agents Service]
        C[Context Manager] <--> SDB[(SurrealDB)]
        D[Sync Manager] <--> SDB
        E[Task Manager] <--> SDB
        F[Security Manager] -.-> |Enforces Policies| C
        F -.-> |Enforces Policies| D
        F -.-> |Enforces Policies| E
        C -.-> |Context / Pre-Prompts| Python
        D -.-> |Index / Metadata| Python
    end

    subgraph Data Sources
        FS[Filesystem] <--> D
        MCP[MCP Servers] <--> D
        Apps[Apps/Browsers] <--> E
    end
```

## Core Components

- **SurrealDB:** The persistent bedrock of Atom OS. It stores filesystem sync records, conversation history, task state, discovered contexts, and schema metadata.
- **Sync Manager:** Connects local data (like the filesystem using CocoIndex) and MCP (Model Context Protocol) servers into the database. It handles incremental updates and embeddings.
- **Context Manager:** Automatically discovers personal and work projects, clusters information using RAG, and generates summaries and pre-prompts for AI agents.
- **Task Manager:** A workflow engine with scheduling capabilities and a multi-agent orchestration layer that executes user-defined or autonomous tasks.
- **Security Manager:** Manages system-level security—from certificate rotations and Kata Container sandboxing to whitelisting specific agent tool requests.
- **Bridge (Rust & Python):** A gRPC-based bridge connecting the Rust system components to a powerful LangChain-based Python agent framework.
