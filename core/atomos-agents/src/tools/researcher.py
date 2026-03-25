"""GPT Researcher tools for atomos-agents.

Wraps the ``gpt-researcher`` package as LangChain tools so the agent can
conduct autonomous web research and generate structured reports.  The
package is imported as a regular Python library — no subprocess, no MCP
protocol.

Requires two API keys at runtime (configured via env vars or AtomOS
secret store):

  OPENAI_API_KEY  — used by GPT Researcher for LLM calls
  TAVILY_API_KEY  — used by GPT Researcher for web search
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Optional

from langchain_core.tools import tool

from tools._shared import resolve_api_key as _resolve_api_key

logger = logging.getLogger(__name__)

VALID_REPORT_TYPES = frozenset({
    "research_report",
    "resource_report",
    "outline_report",
})

_last_researcher = None


def _check_api_keys() -> str | None:
    """Return an error string if required API keys are missing, else None."""
    missing = []
    if not _resolve_api_key("OPENAI_API_KEY", ".openai"):
        missing.append("OPENAI_API_KEY")
    if not _resolve_api_key("TAVILY_API_KEY", ".tavily"):
        missing.append("TAVILY_API_KEY")
    if missing:
        return (
            f"Missing API keys: {', '.join(missing)}.  "
            f"Set them as environment variables or place them in "
            f"~/.<name> (e.g. ~/.openai, ~/.tavily)."
        )
    return None


def _inject_api_keys() -> None:
    """Ensure API keys are in the environment so gpt-researcher can find them."""
    for env_var, dotfile in [("OPENAI_API_KEY", ".openai"), ("TAVILY_API_KEY", ".tavily")]:
        if not os.environ.get(env_var, "").strip():
            key = _resolve_api_key(env_var, dotfile)
            if key:
                os.environ[env_var] = key


# ── tools ──────────────────────────────────────────────────────────────────


@tool
async def researcher_research(
    query: str,
    report_type: str = "research_report",
    report_format: str = "APA",
    tone: Optional[str] = None,
    max_subtopics: int = 3,
    verbose: bool = False,
) -> str:
    """Conduct autonomous web research on a topic and generate a report.

    This is the primary research tool.  It searches the web, gathers
    sources, synthesises findings, and writes a structured report.

    report_type must be one of: research_report, resource_report,
    outline_report.

    Returns the full report as markdown text.
    """
    global _last_researcher

    err = _check_api_keys()
    if err:
        return err

    if report_type not in VALID_REPORT_TYPES:
        return (
            f"Invalid report_type '{report_type}'.  "
            f"Must be one of: {', '.join(sorted(VALID_REPORT_TYPES))}"
        )

    _inject_api_keys()

    from gpt_researcher import GPTResearcher

    kwargs: dict = {
        "query": query,
        "report_type": report_type,
        "report_format": report_format,
        "max_subtopics": max_subtopics,
        "verbose": verbose,
    }
    if tone:
        kwargs["tone"] = tone

    researcher = GPTResearcher(**kwargs)
    await researcher.conduct_research()
    report = await researcher.write_report()
    _last_researcher = researcher

    if not report:
        return "(research completed but no report was generated)"
    return report


@tool
async def researcher_get_sources() -> str:
    """Get the source URLs from the most recent research session.

    Call this after researcher_research to retrieve the list of web
    sources that were consulted during the research.
    """
    global _last_researcher
    if _last_researcher is None:
        return "(no research session — call researcher_research first)"

    try:
        urls = _last_researcher.get_source_urls()
    except Exception:
        urls = []

    if not urls:
        return "(no sources recorded)"
    return json.dumps(urls, indent=2)


@tool
async def researcher_get_context() -> str:
    """Get the full research context from the most recent research session.

    Returns all retrieved information (source content and metadata)
    gathered during the last call to researcher_research.
    """
    global _last_researcher
    if _last_researcher is None:
        return "(no research session — call researcher_research first)"

    try:
        context = _last_researcher.get_research_context()
    except Exception:
        context = None

    if not context:
        return "(no research context available)"
    if isinstance(context, str):
        return context
    return json.dumps(context, indent=2, default=str)


@tool
async def researcher_get_costs() -> str:
    """Get the API token costs from the most recent research session.

    Returns the number of tokens consumed during the last research run.
    """
    global _last_researcher
    if _last_researcher is None:
        return "(no research session — call researcher_research first)"

    try:
        costs = _last_researcher.get_costs()
    except Exception:
        costs = None

    if costs is None:
        return "(cost data unavailable)"
    return json.dumps({"total_costs": costs}, indent=2)


# ── registration helper ───────────────────────────────────────────────────

_RESEARCHER_TOOLS = None


def get_researcher_tools() -> list:
    """Return all researcher tools.  Returns ``[]`` if the
    ``gpt-researcher`` package is not installed."""
    global _RESEARCHER_TOOLS
    if _RESEARCHER_TOOLS is not None:
        return _RESEARCHER_TOOLS

    try:
        import gpt_researcher  # noqa: F401 — verify importable
        _RESEARCHER_TOOLS = [
            researcher_research,
            researcher_get_sources,
            researcher_get_context,
            researcher_get_costs,
        ]
    except ImportError:
        logger.warning(
            "gpt-researcher not installed — researcher tools unavailable.  "
            "Install with: pip install 'gpt-researcher>=0.9.0'"
        )
        _RESEARCHER_TOOLS = []

    return _RESEARCHER_TOOLS
