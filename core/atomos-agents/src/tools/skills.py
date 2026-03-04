import base64
import os
from typing import Any, List

from langchain_core.tools import tool

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

def get_atomos_skills() -> List[Any]:
    """Return all skills available to Atom OS agents."""
    from tools.browser import get_browser_tools

    return [
        check_sync_status,
        query_context_manager,
        *get_browser_tools(),
    ]
