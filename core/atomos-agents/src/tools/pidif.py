"""Pidif feed reader adapter for atomos-agents.

Connects to Pidif (terminal RSS/Atom feed reader) running in iso-ubuntu
via its CLI interface and config/cache files.

Tools: feeds_add, feeds_list, feeds_articles, feeds_read, feeds_search
"""

from __future__ import annotations

import json
import logging
import subprocess
from pathlib import Path

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter

logger = logging.getLogger(__name__)

_CONFIG_DIRS = [
    Path.home() / ".config" / "pidif",
    Path.home() / ".pidif",
]

_CACHE_DIRS = [
    Path.home() / ".cache" / "pidif",
    Path.home() / ".local" / "share" / "pidif",
]


def _find_config_dir() -> Path:
    for d in _CONFIG_DIRS:
        if d.exists():
            return d
    default = _CONFIG_DIRS[0]
    default.mkdir(parents=True, exist_ok=True)
    return default


def _find_cache_dir() -> Path:
    for d in _CACHE_DIRS:
        if d.exists():
            return d
    default = _CACHE_DIRS[0]
    default.mkdir(parents=True, exist_ok=True)
    return default


def _run_pidif(args: list[str], timeout: int = 15) -> str:
    """Run a pidif CLI command and return stdout."""
    try:
        proc = subprocess.run(
            ["pidif"] + args,
            capture_output=True, text=True, timeout=timeout,
        )
        return proc.stdout.strip() if proc.returncode == 0 else proc.stderr.strip()
    except FileNotFoundError:
        return "(pidif not found)"
    except subprocess.TimeoutExpired:
        return "(pidif command timed out)"


@register_app_adapter
class PidifAdapter(AppAdapter):
    namespace = "feeds"
    app_id = "org.pidif.Pidif"
    binary = "pidif"

    def get_tools(self) -> list:
        return [feeds_add, feeds_list, feeds_articles, feeds_read, feeds_search]


_adapter: PidifAdapter | None = None


def _get_adapter() -> PidifAdapter:
    global _adapter
    if _adapter is None:
        _adapter = PidifAdapter()
    return _adapter


@tool
def feeds_add(feed_url: str, title: str = "") -> str:
    """Add an RSS/Atom feed to Pidif.

    Provide the feed URL and an optional display title.
    """
    args = ["add", feed_url]
    if title:
        args.extend(["--title", title])
    result = _run_pidif(args)
    if not result or "error" in result.lower() or "not found" in result.lower() or "timed out" in result.lower():
        return f"Failed to add feed: {result}"
    return f"Feed added: {feed_url}" + (f" ({title})" if title else "")


@tool
def feeds_list() -> str:
    """List all subscribed feeds.

    Returns feed title, URL, and number of unread articles.
    """
    result = _run_pidif(["list"])
    if not result:
        config_dir = _find_config_dir()
        feeds_file = config_dir / "feeds.json"
        if feeds_file.exists():
            try:
                data = json.loads(feeds_file.read_text())
                return json.dumps(data, indent=2)
            except (json.JSONDecodeError, OSError):
                pass
        return "(no subscribed feeds)"
    return result


@tool
def feeds_articles(
    feed_url: str = "",
    feed_title: str = "",
    limit: int = 20,
    unread_only: bool = False,
) -> str:
    """List articles from a specific feed or all feeds.

    Provide feed_url or feed_title to filter.  Returns article title,
    date, author, and preview.
    """
    args = ["articles"]
    if feed_url:
        args.extend(["--feed", feed_url])
    elif feed_title:
        args.extend(["--title", feed_title])
    args.extend(["--limit", str(limit)])
    if unread_only:
        args.append("--unread")

    result = _run_pidif(args)
    if not result:
        return "(no articles found)"
    return result


@tool
def feeds_read(article_id: str = "", article_url: str = "") -> str:
    """Read the full content of a feed article.

    Provide either article_id or article_url.  Returns the full article
    text content (HTML stripped).
    """
    if not article_id and not article_url:
        return "Error: provide either article_id or article_url"

    args = ["read"]
    if article_id:
        args.extend(["--id", article_id])
    elif article_url:
        args.extend(["--url", article_url])

    result = _run_pidif(args, timeout=20)
    if not result:
        return "(article not found or empty)"
    return result


@tool
def feeds_search(query: str, limit: int = 20) -> str:
    """Search across all feed articles by keyword.

    Searches article titles and content.
    """
    args = ["search", query, "--limit", str(limit)]
    result = _run_pidif(args)
    if not result:
        return f"(no articles matching '{query}')"
    return result


# ── registration helper ───────────────────────────────────────────────────

_PIDIF_TOOLS = None


def get_pidif_tools() -> list:
    """Return all Pidif feed tools. Returns ``[]`` if not installed."""
    global _PIDIF_TOOLS
    if _PIDIF_TOOLS is not None:
        return _PIDIF_TOOLS

    import shutil
    if shutil.which("pidif") is not None:
        _PIDIF_TOOLS = [feeds_add, feeds_list, feeds_articles, feeds_read, feeds_search]
    else:
        logger.warning("Pidif not installed — feed reader tools unavailable")
        _PIDIF_TOOLS = []

    return _PIDIF_TOOLS
