-- Migration: 0002_tool_registry.surql
-- Name: tool_registry
-- Created: 2026-03-03

-- RAG-based tool registry for dynamic agent tool selection.
-- Tool descriptions are embedded via Ollama and stored as vectors.
-- At query time, the user prompt is embedded and the most relevant
-- tools are retrieved via cosine similarity.

DEFINE TABLE IF NOT EXISTS tool_definition SCHEMALESS;
DEFINE INDEX IF NOT EXISTS tool_name_idx ON TABLE tool_definition FIELDS name UNIQUE;

-- Metadata table tracks the aggregate fingerprint of all tool definitions
-- so the registry can detect when tools change (package update, etc.)
-- and refresh embeddings accordingly.
DEFINE TABLE IF NOT EXISTS tool_registry_meta SCHEMALESS;
