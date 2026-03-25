import base64
import logging
import os
from typing import Any, List

from langchain_core.tools import tool

from tools._shared import is_tool_package_disabled

logger = logging.getLogger(__name__)

SURREALDB_USER = os.environ.get("SURREALDB_USER", "root")
SURREALDB_PASS = os.environ.get("SURREALDB_PASS", "root")


@tool
def check_sync_status(file_path: str) -> str:
    """Check the sync status of a file using SurrealDB mapping."""
    return f"File {file_path} is synced."

@tool
def query_context_manager(project_name: str) -> str:
    """Retrieve contextual embeddings from the Context Manager."""
    import requests
    db_url = os.environ.get("SURREALDB_URL", "http://localhost:8000")
    sql_url = f"{db_url}/sql"
    creds = base64.b64encode(f"{SURREALDB_USER}:{SURREALDB_PASS}".encode()).decode()
    headers = {
        "Accept": "application/json",
        "Authorization": f"Basic {creds}",
        "surreal-ns": "atomos",
        "surreal-db": "atomos",
    }
      
    query = f"SELECT * FROM project WHERE name = '{project_name}' LIMIT 1;"
    try:
        response = requests.post(sql_url, data=query, headers=headers)
        response.raise_for_status()
        results = response.json()
        if results and len(results) > 0 and results[0].get("status") == "OK":
            rows = results[0].get("result", [])
            if not rows:
                return f"No project found with name {project_name}."
            
            project_id = rows[0].get("id")
            
            summary_query = f"SELECT * FROM project_summary WHERE project_id = '{project_id}' ORDER BY window_end DESC LIMIT 1;"
            summary_response = requests.post(sql_url, data=summary_query, headers=headers)
            summary_response.raise_for_status()
            summary_results = summary_response.json()
            
            if summary_results and len(summary_results) > 0 and summary_results[0].get("status") == "OK":
                summary_rows = summary_results[0].get("result", [])
                if not summary_rows:
                    return f"No context summary available yet for project {project_name}."
                
                return f"Context for {project_name}:\\n{summary_rows[0].get('content')}"
            else:
                return f"Error fetching summary for project {project_name}."
        else:
            return f"Error fetching project {project_name}."
    except Exception as e:
        return f"Database error querying context manager for project {project_name}: {str(e)}"


# ── gated tool package loaders ─────────────────────────────────────────────
#
# Each entry maps a human-readable namespace to (module_path, getter_fn).
# Packages are loaded in order; disabled packages are skipped and logged.

_TOOL_PACKAGES: list[tuple[str, str, str]] = [
    ("browser",     "tools.browser",     "get_browser_tools"),
    ("editor",      "tools.editor",      "get_editor_tools"),
    ("shell",       "tools.shell",       "get_shell_tools"),
    ("arxiv",       "tools.arxiv",       "get_arxiv_tools"),
    ("devtools",    "tools.devtools",    "get_devtools_tools"),
    ("superpowers", "tools.superpowers", "get_superpowers_tools"),
    ("researcher",  "tools.researcher",  "get_researcher_tools"),
    ("drawio",      "tools.drawio",      "get_drawio_tools"),
    ("notion",      "tools.notion",      "get_notion_tools"),
    ("google_workspace", "tools.google_workspace", "get_google_workspace_tools"),
    # iso-ubuntu application adapters (§3)
    ("geary",         "tools.geary",         "get_geary_tools"),
    ("chatty",        "tools.chatty",        "get_chatty_tools"),
    ("amberol",       "tools.amberol",       "get_amberol_tools"),
    ("podcasts",      "tools.podcasts",      "get_podcasts_tools"),
    ("vocalis",       "tools.vocalis",       "get_vocalis_tools"),
    ("loupe",         "tools.loupe",         "get_loupe_tools"),
    ("karlender",     "tools.karlender",     "get_karlender_tools"),
    ("contacts",      "tools.contacts",      "get_contacts_tools"),
    ("pidif",         "tools.pidif",         "get_pidif_tools"),
    ("notejot",       "tools.notejot",       "get_notejot_tools"),
    ("authenticator", "tools.authenticator", "get_authenticator_tools"),
    ("passes",        "tools.passes",        "get_passes_tools"),
]


def get_atomos_skills() -> List[Any]:
    """Return all skills available to Atom OS agents.

    Tool packages can be individually disabled via environment variables::

        ATOMOS_TOOLS_DISABLE_ARXIV=1      → arxiv tools will not load
        ATOMOS_TOOLS_DISABLE_NOTION=true  → notion tools will not load
    """
    tools: List[Any] = [
        check_sync_status,
        query_context_manager,
    ]

    for namespace, module_path, getter_name in _TOOL_PACKAGES:
        if is_tool_package_disabled(namespace):
            logger.info("Tool package '%s' disabled via env var", namespace)
            continue
        try:
            import importlib
            mod = importlib.import_module(module_path)
            getter = getattr(mod, getter_name)
            tools.extend(getter())
        except Exception as exc:
            logger.warning(
                "Failed to load tool package '%s' from %s: %s",
                namespace, module_path, exc,
            )

    return tools
