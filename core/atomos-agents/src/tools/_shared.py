"""Shared utilities for atomos-agents tool packages.

Provides common helpers that multiple tool wrappers need:

  call_mcp_handler  — invoke an MCP-style handler and extract TextContent
  parse_json_param  — parse a JSON string tool parameter, or return None
  resolve_api_key   — resolve an API key from env var → dotfile → home scan
  format_result     — format an API response as indented JSON or placeholder
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path

logger = logging.getLogger(__name__)


async def call_mcp_handler(handler, arguments: dict) -> str:
    """Invoke an MCP-style handler and extract text from its result.

    MCP tool handlers return a list of ``TextContent`` objects (each with
    a ``.text`` attribute).  This helper awaits the handler, joins the
    text blocks with newlines, and returns ``"(no results)"`` when the
    list is empty.
    """
    results = await handler(arguments)
    parts = [r.text for r in results if hasattr(r, "text")]
    return "\n".join(parts) if parts else "(no results)"


def parse_json_param(raw: str, param_name: str):
    """Parse a JSON string parameter, returning ``None`` for empty input.

    Raises ``ValueError`` with a descriptive message on invalid JSON.
    """
    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"Invalid JSON for {param_name}: {exc}") from exc


def _read_key_file(path: Path) -> str | None:
    """Read an API key from the first non-empty line of *path*."""
    try:
        line = path.read_text().splitlines()[0].strip()
        return line or None
    except (FileNotFoundError, IndexError, OSError):
        return None


def resolve_api_key(env_var: str, dotfile: str) -> str | None:
    """Resolve an API key by checking multiple sources.

    Resolution order:
      1. ``$env_var`` environment variable
      2. ``~/.<dotfile>`` (first line of the file)
      3. ``/home/$SUDO_USER/.<dotfile>``
      4. Scan ``/home/*/.<dotfile>`` (covers system services where
         ``$HOME`` doesn't match the real user's home directory)
    """
    val = os.environ.get(env_var, "").strip()
    if val:
        return val

    key = _read_key_file(Path.home() / dotfile)
    if key:
        return key

    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        key = _read_key_file(Path("/home") / sudo_user / dotfile)
        if key:
            return key

    try:
        for entry in sorted(Path("/home").iterdir()):
            if entry.is_dir():
                key = _read_key_file(entry / dotfile)
                if key:
                    return key
    except OSError:
        pass

    return None


def format_result(obj) -> str:
    """Format an API response as indented JSON.

    Returns ``"(no results)"`` for None, ``"(empty response)"`` for
    empty strings, and pretty-printed JSON for everything else.
    """
    if obj is None:
        return "(no results)"
    if isinstance(obj, str):
        return obj if obj else "(empty response)"
    return json.dumps(obj, indent=2, default=str)


# ── env-var package gating ─────────────────────────────────────────────────

_TOOL_PACKAGE_ENV_PREFIX = "ATOMOS_TOOLS_DISABLE_"


def is_tool_package_disabled(namespace: str) -> bool:
    """Return True if the tool package *namespace* is disabled via env var.

    Checks ``ATOMOS_TOOLS_DISABLE_<NAMESPACE>`` (case-insensitive on the
    env var value).  Any truthy value (``1``, ``true``, ``yes``) disables
    the package.

    Examples::

        ATOMOS_TOOLS_DISABLE_ARXIV=1       → arxiv tools disabled
        ATOMOS_TOOLS_DISABLE_NOTION=true   → notion tools disabled
        ATOMOS_TOOLS_DISABLE_DEVTOOLS=0    → devtools tools enabled
    """
    env_key = f"{_TOOL_PACKAGE_ENV_PREFIX}{namespace.upper()}"
    val = os.environ.get(env_key, "").strip().lower()
    return val in ("1", "true", "yes")
