# Filesystem Sync Service

Syncs the Linux `$HOME` filesystem to SurrealDB for RAG capabilities.

## Features

- **Full $HOME Monitoring**: Watches entire home directory for changes
- **Real-time Sync**: Uses filesystem watcher to detect changes
- **Intelligent Filtering**: Excludes common non-document directories (`.git`, `target`, `node_modules`, etc.)
- **Vector Embeddings**: Generates embeddings for semantic search
- **Debounced Updates**: Prevents excessive re-indexing on rapid changes

## Usage

### Install Dependencies

```bash
pip3 install -r requirements.txt
```

### Run Service

```bash
python3 main.py
```

### Deploy to VM

The service is automatically deployed via `dev-watch.py` when changes are detected.

## Configuration

- **SurrealDB**: `ws://127.0.0.1:8000/rpc`
- **Namespace**: `atomos`
- **Database**: `filesystem`
- **Table**: `document`
- **Embedding Model**: `sentence-transformers/all-MiniLM-L6-v2`

## File Types Indexed

- Markdown (`.md`)
- Text (`.txt`)
- PDF (`.pdf`)
- Python (`.py`)
- Rust (`.rs`)
- TOML (`.toml`)
- JSON (`.json`)
- YAML (`.yaml`, `.yml`)
