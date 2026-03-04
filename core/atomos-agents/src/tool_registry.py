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
from typing import Any

import requests
from langchain_core.tools import BaseTool

logger = logging.getLogger(__name__)

SURREALDB_URL = os.environ.get("SURREALDB_URL", "http://localhost:8000")
SURREALDB_NS = "atomos"
SURREALDB_DB = "atomos"
SURREALDB_USER = os.environ.get("SURREALDB_USER", "root")
SURREALDB_PASS = os.environ.get("SURREALDB_PASS", "root")
EMBED_MODEL = "nomic-embed-text"
OLLAMA_URL = "http://localhost:11434"

DEFAULT_TOP_K = 3
SIMILARITY_THRESHOLD = 0.25

_MIDDLEWARE_COUPLED_TOOLS = frozenset({"task", "write_todos"})

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
        from deepagents.backends import FilesystemBackend

        llm = init_chat_model("ollama:_registry_probe")
        backend = FilesystemBackend(root_dir="/", virtual_mode=False)
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


def discover_all_tools() -> list[dict]:
    """Return every available tool, with atomos tools taking priority."""
    atomos_tools = _discover_atomos_tools()
    deepagent_tools = _discover_deepagent_tools()
    seen: set[str] = set()
    combined: list[dict] = []
    for t in atomos_tools + deepagent_tools:
        if t["name"] not in seen:
            seen.add(t["name"])
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
    """Embed *query* and return the most relevant tool objects."""
    if not _tool_objects:
        logger.warning("No tool objects cached — falling back to empty tool list")
        return []

    try:
        [query_emb] = _embed([query])
    except Exception as exc:
        logger.error("Query embedding failed: %s — returning no tools", exc)
        return []

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
            return []
        if results[0].get("status") != "OK":
            logger.error(
                "Vector search query failed: %s", results[0].get("result")
            )
            return []
        rows = results[0].get("result", [])
        selected: list[BaseTool] = []
        for row in rows:
            name = row["name"]
            score = row.get("score", 0)
            if score < threshold:
                continue
            if name in _tool_objects:
                selected.append(_tool_objects[name])
                logger.info("Tool selected: %-20s (score=%.3f)", name, score)
        return selected
    except Exception as exc:
        logger.error("Vector search failed: %s", exc)
        return []


def ensure_registry() -> bool:
    """Populate/refresh the registry if stale. Called once at service startup."""
    tools = discover_all_tools()
    global _tool_objects
    _tool_objects = {t["name"]: t["tool"] for t in tools}
    logger.info("Discovered %d tools: %s", len(tools), [t["name"] for t in tools])

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
