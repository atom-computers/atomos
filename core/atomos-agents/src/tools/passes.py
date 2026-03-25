"""Passes password manager adapter for atomos-agents.

Connects to Passes (GNOME password manager) running in iso-ubuntu via
the Secret Service D-Bus API.

SECURITY:
  - Credentials are NEVER included in agent response content.
  - The ``pass_get`` tool returns a relay token, not the actual password.
  - The bridge injects credentials directly into target actions (e.g.
    browser form fills) without exposing them in the chat stream.

Tools: pass_list, pass_get, pass_add, pass_search
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import time
import uuid
from typing import Optional

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter, DBusError

logger = logging.getLogger(__name__)

_SECRETS_BUS = "org.freedesktop.secrets"
_SECRETS_PATH = "/org/freedesktop/secrets"
_SECRETS_IFACE = "org.freedesktop.Secret.Service"
_PASSES_COLLECTION = "org.gnome.Passes"

# In-memory credential relay: maps relay_token → (username, password).
# Tokens expire after 60 seconds.  The bridge consumes a token exactly
# once when injecting credentials into a form field.
_credential_relay: dict[str, tuple[str, str, float]] = {}
_RELAY_TTL = 60


def _create_relay_token(username: str, password: str) -> str:
    """Store credentials under a short-lived relay token."""
    token = str(uuid.uuid4())[:12]
    _credential_relay[token] = (username, password, time.time())
    _cleanup_expired_tokens()
    return token


def _consume_relay_token(token: str) -> tuple[str, str] | None:
    """Consume a relay token, returning (username, password) or None."""
    _cleanup_expired_tokens()
    entry = _credential_relay.pop(token, None)
    if entry is None:
        return None
    username, password, created = entry
    if time.time() - created > _RELAY_TTL:
        return None
    return (username, password)


def _cleanup_expired_tokens() -> None:
    now = time.time()
    expired = [k for k, (_, _, ts) in _credential_relay.items() if now - ts > _RELAY_TTL]
    for k in expired:
        del _credential_relay[k]


@register_app_adapter
class PassesAdapter(AppAdapter):
    namespace = "pass"
    app_id = "org.gnome.Passes"
    binary = "passes"

    def get_tools(self) -> list:
        return [pass_list, pass_get, pass_add, pass_search]


_adapter: PassesAdapter | None = None


def _get_adapter() -> PassesAdapter:
    global _adapter
    if _adapter is None:
        _adapter = PassesAdapter()
    return _adapter


@tool
def pass_list(limit: int = 50) -> str:
    """List stored credentials in the password manager.

    Returns entry names (service/website) and usernames.
    Passwords are NEVER shown.
    """
    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _SECRETS_BUS, _SECRETS_PATH,
            _SECRETS_IFACE, "SearchItems",
            "{'application': 'org.gnome.Passes'}",
        )
        if not result or result == "()":
            return "(no stored credentials)"
        return result
    except DBusError:
        try:
            import keyring
            creds = keyring.get_credential(_PASSES_COLLECTION, None)
            if creds:
                return f"Credentials found: {creds.username}"
        except Exception:
            pass
        return "(credential store not accessible)"


@tool
def pass_get(
    service: str,
    username: str = "",
) -> str:
    """Retrieve credentials for a service.

    Returns a relay token that the bridge uses to inject the credential
    into target actions (e.g. form fills).  The actual password is NEVER
    included in this response.

    This action requires human-in-the-loop approval.
    """
    adapter = _get_adapter()

    password = None
    try:
        result = adapter.dbus.call(
            _SECRETS_BUS, _SECRETS_PATH,
            _SECRETS_IFACE, "GetSecret",
            f"'{service}'",
        )
        if result and result != "()":
            password = result.strip("()'\" ")
    except DBusError:
        pass

    if not password:
        try:
            import keyring
            password = keyring.get_password(service, username or "default")
        except Exception:
            pass

    if not password:
        return f"(no credentials found for '{service}')"

    effective_username = username or service
    token = _create_relay_token(effective_username, password)
    logger.info("Credential relay token created for %s (token=%s)", service, token[:4] + "...")
    return f"Credential ready for {service}. Relay token: {token}"


@tool
def pass_add(
    service: str,
    username: str,
    password: str,
    notes: str = "",
) -> str:
    """Store new credentials in the password manager.

    The password is stored securely in the system keyring.
    It will NEVER appear in chat output.
    """
    adapter = _get_adapter()

    try:
        import keyring
        keyring.set_password(service, username, password)
        logger.info("Credential stored for %s/%s", service, username)
        return f"Credentials stored for {service} (user: {username})"
    except Exception as exc:
        return f"Failed to store credentials: {exc}"


@tool
def pass_search(query: str, limit: int = 20) -> str:
    """Search stored credentials by service name or username.

    Returns matching entries with service names and usernames.
    Passwords are NEVER shown.
    """
    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _SECRETS_BUS, _SECRETS_PATH,
            _SECRETS_IFACE, "SearchItems",
            f"{{'application': 'org.gnome.Passes', 'query': '{query}'}}",
        )
        if not result or result == "()":
            return f"(no credentials matching '{query}')"
        return result
    except DBusError:
        return f"(credential search unavailable — keyring not responding)"


# ── registration helper ───────────────────────────────────────────────────

_PASSES_TOOLS = None


def get_passes_tools() -> list:
    """Return all Passes tools. Returns ``[]`` if not installed."""
    global _PASSES_TOOLS
    if _PASSES_TOOLS is not None:
        return _PASSES_TOOLS

    import shutil
    if shutil.which("passes") is not None:
        _PASSES_TOOLS = [pass_list, pass_get, pass_add, pass_search]
    else:
        logger.warning("Passes not installed — password manager tools unavailable")
        _PASSES_TOOLS = []

    return _PASSES_TOOLS
