"""Notion workspace tools for atomos-agents.

Wraps the ``notion-sdk-ldraney`` Python SDK as LangChain tools so the
agent can search, read, create, and update Notion pages, databases, and
blocks entirely in-process — no subprocess, no MCP protocol overhead.

Requires a Notion integration API key at runtime, resolved from:
  NOTION_API_KEY env var → ~/.notion → /home/$SUDO_USER/.notion
  → scan /home/*/.notion
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Optional

from langchain_core.tools import tool

from tools._shared import resolve_api_key, format_result as _fmt, parse_json_param as _parse_json_param

logger = logging.getLogger(__name__)

_client = None


def _resolve_notion_key() -> str | None:
    """Resolve the Notion API key from env var → dotfile → home scan."""
    return resolve_api_key("NOTION_API_KEY", ".notion")


def _get_client():
    """Return a lazily-initialised NotionClient singleton."""
    global _client
    if _client is not None:
        return _client

    api_key = _resolve_notion_key()
    if not api_key:
        return None

    from notion_sdk import NotionClient

    _client = NotionClient(api_key=api_key)
    return _client


def _check_client():
    """Return an error string if the client can't be initialised, else None."""
    if _get_client() is None:
        return (
            "Missing NOTION_API_KEY.  Set it as an environment variable "
            "or place it in ~/.notion (first line of the file)."
        )
    return None


# ── tools ──────────────────────────────────────────────────────────────────


@tool
def notion_search(
    query: str = "",
    filter_type: str = "",
    page_size: int = 10,
    start_cursor: str = "",
) -> str:
    """Search Notion for pages and databases by title.

    filter_type can be 'page' or 'database' to restrict results.
    Returns a list of matching objects with titles and IDs.
    """
    err = _check_client()
    if err:
        return err

    kwargs: dict = {}
    if query:
        kwargs["query"] = query
    if filter_type in ("page", "database"):
        kwargs["filter"] = {"value": filter_type, "property": "object"}
    if page_size != 10:
        kwargs["page_size"] = page_size
    if start_cursor:
        kwargs["start_cursor"] = start_cursor

    try:
        result = _get_client().search(**kwargs)
        return _fmt(result)
    except Exception as exc:
        return f"Notion API error: {exc}"


@tool
def notion_get_page(page_id: str) -> str:
    """Get a Notion page by ID, including all properties.

    Returns the page object with title, properties, parent info, and
    metadata.  Use notion_get_block_children to read the page content.
    """
    err = _check_client()
    if err:
        return err

    try:
        result = _get_client().get_page(page_id)
        return _fmt(result)
    except Exception as exc:
        return f"Notion API error: {exc}"


@tool
def notion_create_page(
    parent_id: str,
    parent_type: str = "page_id",
    title: str = "",
    properties_json: str = "",
    children_json: str = "",
    icon_emoji: str = "",
) -> str:
    """Create a new Notion page.

    parent_type is 'page_id' (nested under a page) or 'database_id'
    (new row in a database).  For page parents, title sets the page
    title.  For database parents, use properties_json to set column
    values.

    children_json is an optional JSON array of block objects to add as
    the initial page content.
    """
    err = _check_client()
    if err:
        return err

    try:
        properties = _parse_json_param(properties_json, "properties_json")
        children = _parse_json_param(children_json, "children_json")
    except ValueError as exc:
        return f"Error: {exc}"

    parent = {"type": parent_type, parent_type: parent_id}

    kwargs: dict = {"parent": parent}

    if parent_type == "page_id" and title and not properties:
        kwargs["properties"] = {
            "title": [{"text": {"content": title}}]
        }
    elif properties:
        kwargs["properties"] = properties
    elif title:
        kwargs["properties"] = {
            "title": [{"text": {"content": title}}]
        }

    if children:
        kwargs["children"] = children
    if icon_emoji:
        kwargs["icon"] = {"type": "emoji", "emoji": icon_emoji}

    try:
        result = _get_client().create_page(**kwargs)
        return _fmt(result)
    except Exception as exc:
        return f"Notion API error: {exc}"


@tool
def notion_update_page(
    page_id: str,
    properties_json: str = "",
    archived: Optional[bool] = None,
    icon_emoji: str = "",
) -> str:
    """Update properties of an existing Notion page.

    properties_json is a JSON object mapping property names to their new
    values (Notion property value format).  Set archived=true to move a
    page to the trash.
    """
    err = _check_client()
    if err:
        return err

    try:
        properties = _parse_json_param(properties_json, "properties_json")
    except ValueError as exc:
        return f"Error: {exc}"

    kwargs: dict = {"page_id": page_id}
    if properties:
        kwargs["properties"] = properties
    if archived is not None:
        kwargs["archived"] = archived
    if icon_emoji:
        kwargs["icon"] = {"type": "emoji", "emoji": icon_emoji}

    try:
        result = _get_client().update_page(**kwargs)
        return _fmt(result)
    except Exception as exc:
        return f"Notion API error: {exc}"


@tool
def notion_get_block_children(
    block_id: str,
    page_size: int = 100,
    start_cursor: str = "",
) -> str:
    """Get the child blocks (content) of a page or block.

    Pass the page ID to read the full page content.  Returns a list of
    block objects (paragraphs, headings, lists, code blocks, etc.).
    """
    err = _check_client()
    if err:
        return err

    kwargs: dict = {"block_id": block_id}
    if page_size != 100:
        kwargs["page_size"] = page_size
    if start_cursor:
        kwargs["start_cursor"] = start_cursor

    try:
        result = _get_client().get_block_children(**kwargs)
        return _fmt(result)
    except Exception as exc:
        return f"Notion API error: {exc}"


@tool
def notion_append_blocks(
    block_id: str,
    children_json: str,
) -> str:
    """Append content blocks to a page or block.

    children_json is a JSON array of Notion block objects.  Example:
    [{"object":"block","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":"Hello"}}]}}]
    """
    err = _check_client()
    if err:
        return err

    try:
        children = _parse_json_param(children_json, "children_json")
    except ValueError as exc:
        return f"Error: {exc}"

    if not children:
        return "Error: children_json is required and must be a non-empty JSON array"

    try:
        result = _get_client().append_block_children(
            block_id=block_id, children=children
        )
        return _fmt(result)
    except Exception as exc:
        return f"Notion API error: {exc}"


@tool
def notion_query_database(
    database_id: str,
    filter_json: str = "",
    sorts_json: str = "",
    page_size: int = 100,
    start_cursor: str = "",
) -> str:
    """Query a Notion database with optional filters and sorts.

    filter_json is a Notion filter object (JSON string).
    sorts_json is a JSON array of sort objects.
    Returns matching pages (rows) with their properties.
    """
    err = _check_client()
    if err:
        return err

    try:
        filter_obj = _parse_json_param(filter_json, "filter_json")
        sorts = _parse_json_param(sorts_json, "sorts_json")
    except ValueError as exc:
        return f"Error: {exc}"

    kwargs: dict = {"database_id": database_id}
    if filter_obj:
        kwargs["filter"] = filter_obj
    if sorts:
        kwargs["sorts"] = sorts
    if page_size != 100:
        kwargs["page_size"] = page_size
    if start_cursor:
        kwargs["start_cursor"] = start_cursor

    try:
        result = _get_client().query_database(**kwargs)
        return _fmt(result)
    except Exception as exc:
        return f"Notion API error: {exc}"


@tool
def notion_get_database(database_id: str) -> str:
    """Get a Notion database schema by ID.

    Returns the database object including title, properties (column
    definitions), and parent info.  Useful for understanding the
    structure before creating pages or querying.
    """
    err = _check_client()
    if err:
        return err

    try:
        result = _get_client().get_database(database_id)
        return _fmt(result)
    except Exception as exc:
        return f"Notion API error: {exc}"


# ── registration helper ───────────────────────────────────────────────────

_NOTION_TOOLS = None


def get_notion_tools() -> list:
    """Return all Notion tools.  Returns ``[]`` if the
    ``notion-sdk-ldraney`` package is not installed."""
    global _NOTION_TOOLS
    if _NOTION_TOOLS is not None:
        return _NOTION_TOOLS

    try:
        import notion_sdk  # noqa: F401 — verify importable
        _NOTION_TOOLS = [
            notion_search,
            notion_get_page,
            notion_create_page,
            notion_update_page,
            notion_get_block_children,
            notion_append_blocks,
            notion_query_database,
            notion_get_database,
        ]
    except ImportError:
        logger.warning(
            "notion-sdk-ldraney not installed — Notion tools unavailable.  "
            "Install with: pip install 'notion-mcp-ldraney>=0.1.13'"
        )
        _NOTION_TOOLS = []

    return _NOTION_TOOLS
