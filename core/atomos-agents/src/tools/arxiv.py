"""arXiv research tools for atomos-agents.

Wraps the handler functions from the ``arxiv-mcp-server`` package as
LangChain tools so they can be used directly by the agent — no
subprocess, no MCP protocol overhead.  The package is imported as a
regular Python library.
"""

import json
import logging
import os
from pathlib import Path
from typing import Optional

from langchain_core.tools import tool

from tools._shared import call_mcp_handler as _call_handler

logger = logging.getLogger(__name__)


def _get_storage_path() -> str:
    path = os.environ.get("ARXIV_STORAGE_PATH", "")
    if path:
        return path
    return str(Path.home() / ".arxiv-mcp-server" / "papers")


# ── tools ──────────────────────────────────────────────────────────────────


@tool
async def arxiv_search_papers(
    query: str,
    max_results: int = 10,
    date_from: Optional[str] = None,
    date_to: Optional[str] = None,
    categories: Optional[list[str]] = None,
    sort_by: str = "relevance",
) -> str:
    """Search arXiv for academic papers.

    Supports keyword queries, date ranges (YYYY-MM-DD), arXiv category
    filters (e.g. cs.AI, cs.LG), and relevance/date sorting.
    """
    from arxiv_mcp_server.tools import handle_search

    arguments: dict = {"query": query, "max_results": max_results}
    if date_from:
        arguments["date_from"] = date_from
    if date_to:
        arguments["date_to"] = date_to
    if categories:
        arguments["categories"] = categories
    if sort_by != "relevance":
        arguments["sort_by"] = sort_by

    return await _call_handler(handle_search, arguments)


@tool
async def arxiv_download_paper(paper_id: str) -> str:
    """Download an arXiv paper by its ID (e.g. '2401.12345').

    The paper is converted to markdown and stored locally for later reading.
    """
    from arxiv_mcp_server.tools import handle_download

    return await _call_handler(handle_download, {"paper_id": paper_id})


@tool
async def arxiv_list_papers() -> str:
    """List all previously downloaded arXiv papers."""
    from arxiv_mcp_server.tools import handle_list_papers

    return await _call_handler(handle_list_papers, {})


@tool
async def arxiv_read_paper(paper_id: str) -> str:
    """Read the full markdown content of a downloaded arXiv paper."""
    from arxiv_mcp_server.tools import handle_read_paper

    return await _call_handler(handle_read_paper, {"paper_id": paper_id})


# ── registration helper ───────────────────────────────────────────────────

_ARXIV_TOOLS = None


def get_arxiv_tools() -> list:
    """Return all arxiv tools.  Imports are deferred so a missing
    ``arxiv-mcp-server`` package doesn't break the rest of the agent."""
    global _ARXIV_TOOLS
    if _ARXIV_TOOLS is not None:
        return _ARXIV_TOOLS

    try:
        import arxiv_mcp_server  # noqa: F401 — verify importable
        _ARXIV_TOOLS = [
            arxiv_search_papers,
            arxiv_download_paper,
            arxiv_list_papers,
            arxiv_read_paper,
        ]
    except ImportError:
        logger.warning(
            "arxiv-mcp-server not installed — arxiv tools unavailable.  "
            "Install with: pip install 'arxiv-mcp-server>=0.3.0'"
        )
        _ARXIV_TOOLS = []

    return _ARXIV_TOOLS
