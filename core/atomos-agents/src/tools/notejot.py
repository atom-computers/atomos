"""Notejot notes adapter for atomos-agents.

Connects to Notejot running in iso-ubuntu.  Reads and writes directly to
Notejot's JSON data store for fast access, and uses D-Bus activation to
refresh the UI when changes are made.

Tools: notes_create, notes_list, notes_read, notes_update, notes_delete, notes_search
"""

from __future__ import annotations

import json
import logging
import os
import time
import uuid
from pathlib import Path
from typing import Optional

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter, DBusError

logger = logging.getLogger(__name__)

_NOTEJOT_BUS = "io.github.lainsce.Notejot"
_NOTEJOT_PATH = "/io/github/lainsce/Notejot"

_DATA_DIRS = [
    Path.home() / ".local" / "share" / "notejot",
    Path.home() / ".var" / "app" / "io.github.lainsce.Notejot" / "data" / "notejot",
    Path.home() / ".local" / "share" / "io.github.lainsce.Notejot",
]


def _find_data_dir() -> Path:
    for d in _DATA_DIRS:
        if d.exists():
            return d
    return _DATA_DIRS[0]


def _find_notes_file() -> Path:
    data_dir = _find_data_dir()
    for name in ("notes.json", "notejot.json", "data.json"):
        p = data_dir / name
        if p.exists():
            return p
    return data_dir / "notes.json"


def _load_notes() -> list[dict]:
    path = _find_notes_file()
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text())
        if isinstance(data, list):
            return data
        if isinstance(data, dict) and "notes" in data:
            return data["notes"]
        return []
    except (json.JSONDecodeError, OSError):
        return []


def _save_notes(notes: list[dict]) -> None:
    path = _find_notes_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(notes, indent=2))


@register_app_adapter
class NotejotAdapter(AppAdapter):
    namespace = "notes"
    app_id = "io.github.lainsce.Notejot"
    binary = "notejot"

    def get_tools(self) -> list:
        return [notes_create, notes_list, notes_read, notes_update, notes_delete, notes_search]


_adapter: NotejotAdapter | None = None


def _get_adapter() -> NotejotAdapter:
    global _adapter
    if _adapter is None:
        _adapter = NotejotAdapter()
    return _adapter


@tool
def notes_create(
    title: str,
    content: str,
    color: str = "",
) -> str:
    """Create a new note in Notejot.

    Returns the note ID for future reference.
    """
    notes = _load_notes()
    note_id = str(uuid.uuid4())[:8]
    note = {
        "id": note_id,
        "title": title,
        "content": content,
        "color": color or "default",
        "created": time.time(),
        "modified": time.time(),
    }
    notes.append(note)
    _save_notes(notes)
    return f"Note created: {title} (id={note_id})"


@tool
def notes_list(limit: int = 50) -> str:
    """List all notes.

    Returns note ID, title, preview, and modification date.
    """
    notes = _load_notes()
    if not notes:
        return "(no notes)"

    notes_sorted = sorted(notes, key=lambda n: n.get("modified", 0), reverse=True)
    results = []
    for n in notes_sorted[:limit]:
        content = n.get("content", "")
        preview = content[:100] + "..." if len(content) > 100 else content
        results.append({
            "id": n.get("id", ""),
            "title": n.get("title", "(untitled)"),
            "preview": preview,
            "color": n.get("color", ""),
            "modified": n.get("modified", ""),
        })
    return json.dumps(results, indent=2)


@tool
def notes_read(note_id: str) -> str:
    """Read the full content of a note by ID.

    Returns the complete note including title, content, and metadata.
    """
    notes = _load_notes()
    for n in notes:
        if n.get("id") == note_id:
            return json.dumps(n, indent=2)
    return f"(note not found: {note_id})"


@tool
def notes_update(
    note_id: str,
    title: str = "",
    content: str = "",
    color: str = "",
) -> str:
    """Update an existing note.

    Provide the note_id and any fields to change.
    """
    notes = _load_notes()
    for n in notes:
        if n.get("id") == note_id:
            if title:
                n["title"] = title
            if content:
                n["content"] = content
            if color:
                n["color"] = color
            n["modified"] = time.time()
            _save_notes(notes)
            return f"Note updated: {n.get('title', note_id)}"
    return f"(note not found: {note_id})"


@tool
def notes_delete(note_id: str) -> str:
    """Delete a note by ID.

    This action is permanent.
    """
    notes = _load_notes()
    original_len = len(notes)
    notes = [n for n in notes if n.get("id") != note_id]
    if len(notes) == original_len:
        return f"(note not found: {note_id})"
    _save_notes(notes)
    return f"Note deleted: {note_id}"


@tool
def notes_search(query: str, limit: int = 20) -> str:
    """Search notes by title or content.

    Returns matching notes with relevance-ranked results.
    """
    notes = _load_notes()
    query_lower = query.lower()
    matches = []
    for n in notes:
        title = n.get("title", "").lower()
        content = n.get("content", "").lower()
        score = 0
        if query_lower in title:
            score += 2
        if query_lower in content:
            score += 1
        if score > 0:
            matches.append((score, n))

    matches.sort(key=lambda x: x[0], reverse=True)
    if not matches:
        return f"(no notes matching '{query}')"

    results = []
    for _, n in matches[:limit]:
        content = n.get("content", "")
        idx = content.lower().find(query_lower)
        if idx >= 0:
            start = max(0, idx - 50)
            end = min(len(content), idx + len(query) + 50)
            snippet = content[start:end]
        else:
            snippet = content[:100]
        results.append({
            "id": n.get("id", ""),
            "title": n.get("title", "(untitled)"),
            "snippet": snippet,
        })
    return json.dumps(results, indent=2)


# ── registration helper ───────────────────────────────────────────────────

_NOTEJOT_TOOLS = None


def get_notejot_tools() -> list:
    """Return all Notejot tools. Returns ``[]`` if not installed."""
    global _NOTEJOT_TOOLS
    if _NOTEJOT_TOOLS is not None:
        return _NOTEJOT_TOOLS

    import shutil
    has_binary = shutil.which("notejot") is not None
    has_data = _find_notes_file().exists()
    if has_binary or has_data:
        _NOTEJOT_TOOLS = [notes_create, notes_list, notes_read, notes_update, notes_delete, notes_search]
    else:
        logger.warning("Notejot not installed — notes tools unavailable")
        _NOTEJOT_TOOLS = []

    return _NOTEJOT_TOOLS
