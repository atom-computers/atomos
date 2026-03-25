"""Chatty messaging adapter for atomos-agents.

Connects to Chatty (GNOME/Phosh messaging app) running in iso-ubuntu
via its D-Bus API.  Supports Matrix, XMPP, and SMS backends.

Tools: chat_send, chat_read, chat_list, chat_search
"""

from __future__ import annotations

import json
import logging
from typing import Optional

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter, DBusError

logger = logging.getLogger(__name__)

_CHATTY_BUS = "sm.puri.Chatty"
_CHATTY_PATH = "/sm/puri/Chatty"
_CHATTY_IFACE = "sm.puri.Chatty"


@register_app_adapter
class ChattyAdapter(AppAdapter):
    namespace = "chat"
    app_id = "sm.puri.Chatty"
    binary = "chatty"

    def get_tools(self) -> list:
        return [chat_send, chat_read, chat_list, chat_search]


_adapter: ChattyAdapter | None = None


def _get_adapter() -> ChattyAdapter:
    global _adapter
    if _adapter is None:
        _adapter = ChattyAdapter()
    return _adapter


def _check_running() -> str | None:
    return _get_adapter().ensure_running()


@tool
def chat_send(
    recipient: str,
    message: str,
    protocol: str = "matrix",
) -> str:
    """Send a message via Chatty.

    Sends a text message to the specified recipient using the given
    protocol (matrix, xmpp, or sms).  This action requires
    human-in-the-loop approval before execution.
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        adapter.dbus.call(
            _CHATTY_BUS, _CHATTY_PATH,
            _CHATTY_IFACE, "SendMessage",
            f"'{recipient}'", f"'{message}'", f"'{protocol}'",
        )
        return f"Message sent to {recipient} via {protocol}"
    except DBusError as exc:
        return f"Failed to send message: {exc}"


@tool
def chat_read(
    conversation_id: str = "",
    recipient: str = "",
    limit: int = 20,
) -> str:
    """Read messages from a Chatty conversation.

    Provide a conversation_id or recipient name to read message history.
    Returns the most recent messages with sender, timestamp, and content.
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        if conversation_id:
            result = adapter.dbus.call(
                _CHATTY_BUS, _CHATTY_PATH,
                _CHATTY_IFACE, "GetMessages",
                f"'{conversation_id}'", str(limit),
            )
        elif recipient:
            result = adapter.dbus.call(
                _CHATTY_BUS, _CHATTY_PATH,
                _CHATTY_IFACE, "GetMessagesByRecipient",
                f"'{recipient}'", str(limit),
            )
        else:
            return "Error: provide either conversation_id or recipient"
        if not result or result == "()":
            return "(no messages found)"
        return result
    except DBusError:
        return "(message read unavailable — Chatty D-Bus API not responding)"


@tool
def chat_list(
    protocol: str = "",
    limit: int = 20,
) -> str:
    """List recent conversations in Chatty.

    Returns a list of conversations with recipient, last message preview,
    timestamp, and unread count.  Optionally filter by protocol.
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        args = [str(limit)]
        if protocol:
            args.insert(0, f"'{protocol}'")
        result = adapter.dbus.call(
            _CHATTY_BUS, _CHATTY_PATH,
            _CHATTY_IFACE, "ListConversations",
            *args,
        )
        if not result or result == "()":
            return "(no conversations)"
        return result
    except DBusError:
        return "(conversation list unavailable — Chatty D-Bus API not responding)"


@tool
def chat_search(
    query: str,
    limit: int = 20,
) -> str:
    """Search messages across all Chatty conversations.

    Searches message content for the given query string.
    Returns matching messages with conversation context.
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _CHATTY_BUS, _CHATTY_PATH,
            _CHATTY_IFACE, "SearchMessages",
            f"'{query}'", str(limit),
        )
        if not result or result == "()":
            return "(no matching messages found)"
        return result
    except DBusError:
        return "(message search unavailable — Chatty D-Bus API not responding)"


# ── registration helper ───────────────────────────────────────────────────

_CHATTY_TOOLS = None


def get_chatty_tools() -> list:
    """Return all Chatty messaging tools. Returns ``[]`` if not installed."""
    global _CHATTY_TOOLS
    if _CHATTY_TOOLS is not None:
        return _CHATTY_TOOLS

    import shutil
    if shutil.which("chatty") is not None:
        _CHATTY_TOOLS = [chat_send, chat_read, chat_list, chat_search]
    else:
        logger.warning("Chatty not installed — messaging tools unavailable")
        _CHATTY_TOOLS = []

    return _CHATTY_TOOLS
