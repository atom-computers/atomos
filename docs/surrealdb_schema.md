# SurrealDB Schema Patterns

## Overview
Atom OS utilizes SurrealDB namespaces to isolate components. The `atomos` namespace and the `main` database act as the core singleton.

## Schema Tables

### `atomos/filesystem/document`
Stores embeddings and chunked text segments indexed by `sync-manager` and `CocoIndex`.
- `path`: `string`
- `chunk_content`: `string`
- `embedding`: `vector<f32>` (all-MiniLM-L6-v2)
- `modified_at`: `datetime`

### `atomos/contexts/project`
Detected project context blobs tracked by the `context-manager`.
- `id`: Unique hash based on project root.
- `root_path`: `string`
- `classification`: `string` (work, personal)
- `activity_score`: `float`

### `atomos/workflows/state`
Tracks stateful execution for the `task-manager`.
- `id`: Workflow ID
- `trigger`: Enum (manual, event, schedule)
- `current_step`: `int`
- `variables`: `JSON map`
