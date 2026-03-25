"""GNOME Podcasts adapter for atomos-agents.

Connects to GNOME Podcasts running in iso-ubuntu.  Uses the application's
SQLite database for read operations and D-Bus activation / CLI for
control operations.

Tools: podcast_subscribe, podcast_list, podcast_play, podcast_search
"""

from __future__ import annotations

import json
import logging
import sqlite3
from pathlib import Path

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter, DBusError

logger = logging.getLogger(__name__)

_PODCASTS_BUS = "org.gnome.Podcasts"
_PODCASTS_PATH = "/org/gnome/Podcasts"
_PODCASTS_IFACE = "org.gnome.Podcasts"

_DATA_DIRS = [
    Path.home() / ".local" / "share" / "gnome-podcasts",
    Path.home() / ".var" / "app" / "org.gnome.Podcasts" / "data" / "gnome-podcasts",
]


def _find_db() -> Path | None:
    """Locate the GNOME Podcasts SQLite database."""
    for d in _DATA_DIRS:
        db = d / "podcasts.db"
        if db.exists():
            return db
    return None


@register_app_adapter
class PodcastsAdapter(AppAdapter):
    namespace = "podcast"
    app_id = "org.gnome.Podcasts"
    binary = "gnome-podcasts"

    def get_tools(self) -> list:
        return [podcast_subscribe, podcast_list, podcast_play, podcast_search]


_adapter: PodcastsAdapter | None = None


def _get_adapter() -> PodcastsAdapter:
    global _adapter
    if _adapter is None:
        _adapter = PodcastsAdapter()
    return _adapter


def _check_running() -> str | None:
    return _get_adapter().ensure_running()


def _query_db(sql: str, params: tuple = ()) -> list[dict]:
    """Run a read-only SQL query against the Podcasts database."""
    db_path = _find_db()
    if not db_path:
        return []
    try:
        conn = sqlite3.connect(str(db_path))
        conn.row_factory = sqlite3.Row
        rows = conn.execute(sql, params).fetchall()
        conn.close()
        return [dict(r) for r in rows]
    except sqlite3.Error as exc:
        logger.warning("Podcasts DB query failed: %s", exc)
        return []


@tool
def podcast_subscribe(feed_url: str) -> str:
    """Subscribe to a podcast by RSS/Atom feed URL.

    Adds the feed to GNOME Podcasts and triggers an initial fetch.
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        adapter.dbus.call(
            _PODCASTS_BUS, _PODCASTS_PATH,
            "org.freedesktop.Application", "Open",
            f"['{feed_url}']", "{}",
        )
        return f"Subscribed to feed: {feed_url}"
    except DBusError:
        import subprocess
        try:
            subprocess.Popen(
                ["gnome-podcasts", feed_url],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            return f"Subscribed to feed (via CLI): {feed_url}"
        except Exception as exc:
            return f"Failed to subscribe: {exc}"


@tool
def podcast_list(limit: int = 20) -> str:
    """List subscribed podcasts with episode counts.

    Returns podcast title, description, and number of episodes.
    """
    rows = _query_db(
        "SELECT title, description, link FROM shows ORDER BY title LIMIT ?",
        (limit,),
    )
    if not rows:
        adapter = _get_adapter()
        try:
            result = adapter.dbus.call(
                _PODCASTS_BUS, _PODCASTS_PATH,
                _PODCASTS_IFACE, "ListShows",
            )
            return result if result and result != "()" else "(no subscribed podcasts)"
        except DBusError:
            return "(no subscribed podcasts — database not found)"

    return json.dumps(rows, indent=2)


@tool
def podcast_play(episode_id: str = "", show_title: str = "") -> str:
    """Play a podcast episode.

    Provide an episode_id for a specific episode, or show_title to play
    the latest episode of a show.
    """
    err = _check_running()
    if err:
        return err

    if not episode_id and show_title:
        rows = _query_db(
            "SELECT e.id, e.title, e.uri FROM episodes e "
            "JOIN shows s ON e.show_id = s.id "
            "WHERE s.title LIKE ? ORDER BY e.epoch DESC LIMIT 1",
            (f"%{show_title}%",),
        )
        if rows:
            episode_id = str(rows[0]["id"])
            uri = rows[0].get("uri", "")
            if uri:
                adapter = _get_adapter()
                try:
                    adapter.dbus.call(
                        _PODCASTS_BUS, _PODCASTS_PATH,
                        "org.freedesktop.Application", "Open",
                        f"['{uri}']", "{}",
                    )
                    return f"Playing: {rows[0].get('title', show_title)}"
                except DBusError:
                    pass

    adapter = _get_adapter()
    try:
        adapter.dbus.call(
            _PODCASTS_BUS, _PODCASTS_PATH,
            _PODCASTS_IFACE, "PlayEpisode",
            f"'{episode_id}'",
        )
        return f"Playing episode {episode_id}"
    except DBusError as exc:
        return f"Failed to play episode: {exc}"


@tool
def podcast_search(query: str, limit: int = 20) -> str:
    """Search podcast episodes by title or description.

    Searches across all subscribed podcasts.
    """
    rows = _query_db(
        "SELECT e.title, e.description, s.title as show_title, e.epoch "
        "FROM episodes e JOIN shows s ON e.show_id = s.id "
        "WHERE e.title LIKE ? OR e.description LIKE ? "
        "ORDER BY e.epoch DESC LIMIT ?",
        (f"%{query}%", f"%{query}%", limit),
    )
    if not rows:
        return f"(no episodes matching '{query}')"
    return json.dumps(rows, indent=2)


# ── registration helper ───────────────────────────────────────────────────

_PODCASTS_TOOLS = None


def get_podcasts_tools() -> list:
    """Return all Podcasts tools. Returns ``[]`` if not installed."""
    global _PODCASTS_TOOLS
    if _PODCASTS_TOOLS is not None:
        return _PODCASTS_TOOLS

    import shutil
    if shutil.which("gnome-podcasts") is not None or _find_db() is not None:
        _PODCASTS_TOOLS = [podcast_subscribe, podcast_list, podcast_play, podcast_search]
    else:
        logger.warning("GNOME Podcasts not installed — podcast tools unavailable")
        _PODCASTS_TOOLS = []

    return _PODCASTS_TOOLS
