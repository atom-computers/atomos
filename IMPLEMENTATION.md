Core packages:

- Sync Manager
Incremental synchronisation of data sources and memory storage. It runs as a background daemon. The [sync](sync/) directory contains the package.

It is composed of the following components:
1. Filesystem 
2. MCP servers
3. Conversations
4. Contacts

And stored in the [surrealdb](surreald/) instance.

- Context Manager
For context aware prompt engineering, the context manager automatically scopes things into personal and work contexts with projects for each. There must be a way to summarize at a high level recent and long-term before retrieving deeper context with mutli-modal RAG queries.

It must build pre-prompts for each user turn based on the current context which is constantly updated and can switch between contexts at any time requiring a semantic cache hit or router to fetch the right context.

- Task Manager
Long-running tasks and multi-agent orchestration in parallel can be isolated into stateful workerflows that can be resumed or cancelled at any time or scheduled for certain times or events. These workerflows can be triggered by user input, events, or other workerflows. They can be composed of multiple agents and tools.

It can connect to the following interfaces:
1. Generative UI (graphs/widgets, native rendering of web, agent chat interfaces)
2. Local tools (terminal sandbox, browser automation, IDE)
3. Data sources / APIs (web retrieval, databases, MCP servers)

- Security Manager
Kata containers for sandboxing of the browser. 

Whitelisting of everything else with user approval. Certificate based verification for all services. Must all be trusted by the security manager.

SurrealDB impossible to access from the browser. Only accessible from the sync manager and context manager.