"""Dynamic tool registry backed by SurrealDB vector search.

Discovers tools from deepagents built-ins and atomos custom tools,
generates embeddings via Ollama, and retrieves the most relevant
tools per user query using cosine similarity.

Population happens automatically at atomos-agents service startup.
If deepagents or custom tools change (package update, ISO rebuild),
the registry refreshes on the next service start.
"""

import base64
import hashlib
import json
import logging
import os
from pathlib import Path
from typing import Any

import requests
from langchain_core.tools import BaseTool

from security import (
    wrap_tool_with_security,
    validate_tool_whitelist,
)

logger = logging.getLogger(__name__)

SURREALDB_URL = os.environ.get("SURREALDB_URL", "http://localhost:8000")
SURREALDB_NS = "atomos"
SURREALDB_DB = "atomos"
SURREALDB_USER = os.environ.get("SURREALDB_USER", "root")
SURREALDB_PASS = os.environ.get("SURREALDB_PASS", "root")
EMBED_MODEL = "nomic-embed-text"
OLLAMA_URL = "http://localhost:11434"


DEFAULT_TOP_K = 5
SIMILARITY_THRESHOLD = 0.25

_MIDDLEWARE_COUPLED_TOOLS = frozenset({"task", "write_todos"})

_INTERNAL_ONLY_TOOLS = frozenset({
    "check_sync_status",
    "query_context_manager",
})

_ALWAYS_AVAILABLE_TOOLS = frozenset({
    # Terminal — output goes to the terminal window
    "terminal",
    # Editor — opens project/file in GUI editor
    "code_editor",
})

_ALLOWED_EXPOSED_TOOLS = frozenset({
    "code_editor",
    "terminal",
    # arxiv tools (imported directly from arxiv-mcp-server package)
    "arxiv_search_papers",
    "arxiv_download_paper",
    "arxiv_list_papers",
    "arxiv_read_paper",
    # chrome devtools tools (imported from chrome-devtools-mcp-fork package)
    "devtools_connect",
    "devtools_execute_javascript",
    "devtools_get_page_info",
    "devtools_get_network_requests",
    "devtools_get_console_logs",
    "devtools_get_dom",
    # superpowers workflow skills (vendored from obra/superpowers)
    "superpowers_list_skills",
    "superpowers_use_skill",
    "superpowers_get_skill_file",
    "superpowers_recommend_skills",
    "superpowers_compose_workflow",
    "superpowers_validate_workflow",
    "superpowers_search_skills",
    # GPT Researcher tools (imported from gpt-researcher package)
    "researcher_research",
    "researcher_get_sources",
    "researcher_get_context",
    "researcher_get_costs",
    # Draw.io diagram tools (imported from drawio-mcp package)
    "drawio_diagram",
    "drawio_draw",
    "drawio_style",
    "drawio_layout",
    "drawio_inspect",
    # Notion workspace tools (imported from notion-sdk-ldraney)
    "notion_search",
    "notion_get_page",
    "notion_create_page",
    "notion_update_page",
    "notion_get_block_children",
    "notion_append_blocks",
    "notion_query_database",
    "notion_get_database",
    # Google Workspace CLI tools (wrapped via gcloud CLI)
    "google_mail_search",
    "google_mail_send",
    "google_calendar_list",
    "google_calendar_create",
    "google_drive_list",
    "google_drive_download",
    "google_docs_read",
    "google_docs_write",
    # Geary email tools (iso-ubuntu app adapter)
    "email_compose",
    "email_send",
    "email_search",
    "email_read",
    # Chatty messaging tools (iso-ubuntu app adapter)
    "chat_send",
    "chat_read",
    "chat_list",
    "chat_search",
    # Amberol music tools (MPRIS2 D-Bus adapter)
    "music_play",
    "music_pause",
    "music_skip",
    "music_queue",
    "music_now_playing",
    # GNOME Podcasts tools (iso-ubuntu app adapter)
    "podcast_subscribe",
    "podcast_list",
    "podcast_play",
    "podcast_search",
    # Vocalis voice recorder tools (iso-ubuntu app adapter)
    "voice_record_start",
    "voice_record_stop",
    "voice_recordings_list",
    # Loupe image viewer tools (iso-ubuntu app adapter)
    "image_open",
    "image_metadata",
    # Karlender calendar tools (EDS D-Bus adapter)
    "calendar_list",
    "calendar_create",
    "calendar_update",
    "calendar_delete",
    "calendar_search",
    # GNOME Contacts tools (EDS D-Bus adapter)
    "contacts_list",
    "contacts_search",
    "contacts_create",
    "contacts_get",
    # Pidif feed reader tools (CLI adapter)
    "feeds_add",
    "feeds_list",
    "feeds_articles",
    "feeds_read",
    "feeds_search",
    # Notejot notes tools (file-based adapter)
    "notes_create",
    "notes_list",
    "notes_read",
    "notes_update",
    "notes_delete",
    "notes_search",
    # Authenticator TOTP tools (Secret Service adapter)
    "auth_list",
    "auth_get_code",
    "auth_add",
    # Passes password manager tools (Secret Service adapter)
    "pass_list",
    "pass_get",
    "pass_add",
    "pass_search",
    # Browser automation tools (local Chromium + cloud fallback)
    "browse_web",
    "browse_web_with_session",
})

_DISABLED_TOOLS = frozenset({
    # Direct filesystem mutation/reads are intentionally disabled.
    # Use terminal (bash) for file operations instead.
    "create_file",
    "read_file",
    "edit_file",
    "search_in_files",
    # Legacy tool name replaced by code_editor.
    "open_in_editor",
})

_tool_objects: dict[str, BaseTool] = {}


def _surreal_headers() -> dict:
    creds = base64.b64encode(f"{SURREALDB_USER}:{SURREALDB_PASS}".encode()).decode()
    return {
        "Accept": "application/json",
        "Authorization": f"Basic {creds}",
        "surreal-ns": SURREALDB_NS,
        "surreal-db": SURREALDB_DB,
    }


def _surreal_query(sql: str) -> list:
    resp = requests.post(
        f"{SURREALDB_URL}/sql",
        data=sql,
        headers=_surreal_headers(),
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()


def _embed(texts: list[str]) -> list[list[float]]:
    resp = requests.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": EMBED_MODEL, "input": texts},
        timeout=300,
    )
    resp.raise_for_status()
    return resp.json()["embeddings"]


def _fingerprint(name: str, description: str) -> str:
    return hashlib.sha256(f"{name}:{description}".encode()).hexdigest()[:16]


def _discover_deepagent_tools() -> list[dict]:
    """Build a throw-away deepagents graph and extract its built-in tools."""
    try:
        from langchain.chat_models import init_chat_model
        from deepagents import create_deep_agent
        from deepagents.backends import LocalShellBackend

        llm = init_chat_model("ollama:_registry_probe")
        home = str(Path.home())
        backend = LocalShellBackend(
            root_dir=home,
            env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": home},
            timeout=120,
            max_output_bytes=100_000,
        )
        agent = create_deep_agent(
            tools=[],
            system_prompt="probe",
            model=llm,
            backend=backend,
            subagents=[],
        )
        found: list[dict] = []
        for node_name, node in agent.get_graph().nodes.items():
            if node_name == "tools" and hasattr(node.data, "tools_by_name"):
                for name, tool in node.data.tools_by_name.items():
                    if name in _MIDDLEWARE_COUPLED_TOOLS:
                        continue
                    found.append({
                        "name": name,
                        "description": getattr(tool, "description", ""),
                        "source": "deepagents",
                        "tool": tool,
                    })
        return found
    except Exception as exc:
        logger.warning("Could not discover deepagents tools: %s", exc)
        return []
        

def _discover_atomos_tools() -> list[dict]:
    """Import the atomos custom tools."""
    try:
        from tools.skills import get_atomos_skills

        found: list[dict] = []
        for tool in get_atomos_skills():
            found.append({
                "name": getattr(tool, "name", str(tool)),
                "description": getattr(tool, "description", ""),
                "source": "atomos",
                "tool": tool,
            })
        return found
    except Exception as exc:
        logger.warning("Could not discover atomos tools: %s", exc)
        return []


class ToolNamespaceCollisionError(RuntimeError):
    """Raised when two tool packages register tools with the same name."""


def _check_namespace_collisions(tools: list[dict]) -> None:
    """Raise ``ToolNamespaceCollisionError`` if any two tool packages
    register tools with the same name.

    Only checks tools from different *sources*.  Duplicate names within
    the same source are silently deduplicated (first-wins) by
    ``discover_all_tools``.
    """
    name_to_source: dict[str, str] = {}
    for t in tools:
        name = t["name"]
        source = t.get("source", "unknown")
        if name in name_to_source and name_to_source[name] != source:
            raise ToolNamespaceCollisionError(
                f"Tool name collision: '{name}' is registered by both "
                f"'{name_to_source[name]}' and '{source}'.  "
                f"Each tool package must use a unique namespace prefix "
                f"(e.g. 'arxiv_', 'devtools_') to avoid collisions."
            )
        name_to_source[name] = source


def discover_all_tools() -> list[dict]:
    """Return every available tool, with atomos tools taking priority.

    Internal-only tools (context enrichment, sync status) are excluded
    from the user-facing set — they belong in the pre-prompt / RAG
    pipeline, not in the agent's tool belt.

    Raises ``ToolNamespaceCollisionError`` if two different tool sources
    register tools with the same name.
    """
    atomos_tools = _discover_atomos_tools()
    deepagent_tools = _discover_deepagent_tools()

    all_tools = atomos_tools + deepagent_tools
    _check_namespace_collisions(all_tools)

    seen: set[str] = set()
    combined: list[dict] = []
    for t in all_tools:
        name = t["name"]
        if name in seen or name in _INTERNAL_ONLY_TOOLS or name in _DISABLED_TOOLS:
            continue
        if name not in _ALLOWED_EXPOSED_TOOLS:
            continue
        seen.add(name)
        combined.append(t)
    return combined


def _aggregate_fingerprint(tools: list[dict]) -> str:
    parts = sorted(f"{t['name']}:{_fingerprint(t['name'], t['description'])}" for t in tools)
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:32]


def _pull_embedding_model() -> None:
    try:
        resp = requests.post(
            f"{OLLAMA_URL}/api/pull",
            json={"name": EMBED_MODEL, "stream": False},
            timeout=600,
        )
        resp.raise_for_status()
        logger.info("Embedding model %s ready", EMBED_MODEL)
    except Exception as exc:
        logger.warning("Could not pull embedding model: %s", exc)


def populate_registry(tools: list[dict] | None = None) -> int:
    """Discover tools, embed descriptions, and upsert into SurrealDB.

    Returns the number of tools stored.
    """
    global _tool_objects

    if tools is None:
        tools = discover_all_tools()
    if not tools:
        logger.warning("No tools discovered — registry will be empty")
        return 0

    _tool_objects = {t["name"]: t["tool"] for t in tools}
    _pull_embedding_model()

    descriptions = [t["description"][:2000] for t in tools]
    try:
        embeddings = _embed(descriptions)
    except Exception as exc:
        logger.error("Embedding generation failed: %s", exc)
        return 0

    agg_fp = _aggregate_fingerprint(tools)

    stored = 0
    for tool_info, emb in zip(tools, embeddings):
        name = tool_info["name"]
        fp = _fingerprint(name, tool_info["description"])
        desc_esc = tool_info["description"].replace("\\", "\\\\").replace("'", "\\'")
        emb_json = json.dumps(emb)
        sql = (
            f"DELETE FROM tool_definition WHERE name = '{name}';\n"
            f"CREATE tool_definition SET "
            f"name = '{name}', "
            f"description = '{desc_esc}', "
            f"source = '{tool_info['source']}', "
            f"fingerprint = '{fp}', "
            f"embedding = {emb_json};"
        )
        try:
            results = _surreal_query(sql)
            has_error = any(r.get("status") == "ERR" for r in results)
            if has_error:
                logger.error(
                    "SurrealDB rejected tool '%s': %s", name,
                    [r.get("result") for r in results if r.get("status") == "ERR"],
                )
            else:
                stored += 1
        except Exception as exc:
            logger.error("Failed to store tool '%s': %s", name, exc)

    try:
        _surreal_query(
            f"DELETE FROM tool_registry_meta WHERE id = 'current';\n"
            f"CREATE tool_registry_meta SET id = 'current', "
            f"fingerprint = '{agg_fp}', tool_count = {len(tools)};"
        )
    except Exception as exc:
        logger.error("Failed to update registry meta: %s", exc)

    logger.info("Tool registry populated: %d/%d tools stored (fp=%s)", stored, len(tools), agg_fp)
    return stored


def retrieve_tools(
    query: str,
    top_k: int = DEFAULT_TOP_K,
    threshold: float = SIMILARITY_THRESHOLD,
) -> list[BaseTool]:
    """Embed *query* and return the most relevant tool objects.

    Tools listed in ``_ALWAYS_AVAILABLE_TOOLS`` are included regardless
    of similarity score so the agent can always use the code editor and
    run shell commands. RAG-selected tools are appended on top of those.

    Every returned tool is wrapped with the security layer (audit
    logging, approval gating, output sanitisation).
    """
    if not _tool_objects:
        logger.warning("No tool objects cached — falling back to empty tool list")
        return []

    seen: set[str] = set()
    selected: list[BaseTool] = []

    for name in _ALWAYS_AVAILABLE_TOOLS:
        if name in _tool_objects:
            selected.append(wrap_tool_with_security(_tool_objects[name]))
            seen.add(name)
            logger.info("Tool always-on: %-20s", name)

    try:
        [query_emb] = _embed([query])
    except Exception as exc:
        logger.error("Query embedding failed: %s — returning core tools only", exc)
        return selected

    emb_json = json.dumps(query_emb)
    sql = (
        f"SELECT name, vector::similarity::cosine(embedding, {emb_json}) AS score "
        f"FROM tool_definition "
        f"ORDER BY score DESC "
        f"LIMIT {top_k};"
    )
    try:
        results = _surreal_query(sql)
        if not results:
            logger.error("Vector search returned empty response")
            return selected
        if results[0].get("status") != "OK":
            logger.error(
                "Vector search query failed: %s", results[0].get("result")
            )
            return selected
        rows = results[0].get("result", [])
        for row in rows:
            name = row["name"]
            score = row.get("score", 0)
            if score < threshold:
                continue
            if name not in _ALLOWED_EXPOSED_TOOLS:
                continue
            if name in _DISABLED_TOOLS:
                continue
            if name in seen:
                continue
            if name in _tool_objects:
                selected.append(wrap_tool_with_security(_tool_objects[name]))
                seen.add(name)
                logger.info("Tool selected: %-20s (score=%.3f)", name, score)
        return selected
    except Exception as exc:
        logger.error("Vector search failed: %s", exc)
        return selected


def ensure_registry() -> bool:
    """Populate/refresh the registry if stale. Called once at service startup."""
    tools = discover_all_tools()
    global _tool_objects
    _tool_objects = {t["name"]: t["tool"] for t in tools}
    logger.info("Discovered %d tools: %s", len(tools), [t["name"] for t in tools])

    from tools.skills import _TOOL_PACKAGES
    namespaces = [ns for ns, _, _ in _TOOL_PACKAGES]
    violations = validate_tool_whitelist(namespaces)
    if violations:
        logger.warning(
            "Tool whitelist violations — these namespaces have undeclared "
            "dependencies in pyproject.toml: %s", violations,
        )

    if not tools:
        return False

    current_fp = _aggregate_fingerprint(tools)

    try:
        results = _surreal_query(
            "SELECT fingerprint, tool_count FROM tool_registry_meta WHERE id = 'current';"
        )
        if results and results[0].get("status") == "OK":
            rows = results[0].get("result", [])
            if rows:
                stored_fp = rows[0].get("fingerprint", "")
                if stored_fp == current_fp:
                    logger.info("Tool registry up-to-date (fp=%s)", current_fp)
                    return True
                logger.info(
                    "Tool definitions changed (stored=%s, current=%s) — refreshing",
                    stored_fp, current_fp,
                )
    except Exception as exc:
        logger.warning("Registry check failed: %s — will populate", exc)

    return populate_registry(tools) > 0
