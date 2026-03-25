"""Authenticator TOTP/2FA adapter for atomos-agents.

Connects to GNOME Authenticator running in iso-ubuntu via the Secret
Service D-Bus API (``org.freedesktop.secrets``) which stores TOTP secrets.
Generates time-based one-time passwords (TOTP, RFC 6238) in-process.

SECURITY: TOTP secrets are NEVER exposed in tool output or logs.
Only the current 6-digit code is returned.

Tools: auth_list, auth_get_code, auth_add
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import struct
import subprocess
import time
from typing import Optional

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter, DBusError

logger = logging.getLogger(__name__)

_SECRETS_BUS = "org.freedesktop.secrets"
_SECRETS_PATH = "/org/freedesktop/secrets"
_SECRETS_IFACE = "org.freedesktop.Secret.Service"
_AUTHENTICATOR_COLLECTION = "org.gnome.Authenticator"


def _generate_totp(secret_b32: str, period: int = 30, digits: int = 6) -> str:
    """Generate a TOTP code from a base32-encoded secret.

    Implements RFC 6238 (TOTP) with SHA-1 hash, configurable period and
    digit count.
    """
    import base64
    try:
        key = base64.b32decode(secret_b32.upper().replace(" ", ""), casefold=True)
    except Exception:
        return "(invalid secret)"

    counter = int(time.time()) // period
    counter_bytes = struct.pack(">Q", counter)
    mac = hmac.new(key, counter_bytes, hashlib.sha1).digest()
    offset = mac[-1] & 0x0F
    code_int = struct.unpack(">I", mac[offset:offset + 4])[0] & 0x7FFFFFFF
    code = str(code_int % (10 ** digits)).zfill(digits)
    return code


def _seconds_remaining(period: int = 30) -> int:
    """Return the number of seconds before the current TOTP code expires."""
    return period - (int(time.time()) % period)


@register_app_adapter
class AuthenticatorAdapter(AppAdapter):
    namespace = "auth"
    app_id = "com.belmoussaoui.Authenticator"
    binary = "authenticator"

    def get_tools(self) -> list:
        return [auth_list, auth_get_code, auth_add]


_adapter: AuthenticatorAdapter | None = None


def _get_adapter() -> AuthenticatorAdapter:
    global _adapter
    if _adapter is None:
        _adapter = AuthenticatorAdapter()
    return _adapter


def _get_accounts_from_keyring() -> list[dict]:
    """Retrieve TOTP accounts from the Secret Service keyring.

    Returns a list of dicts with 'label' and 'issuer' (secret is NOT included).
    """
    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _SECRETS_BUS, _SECRETS_PATH,
            _SECRETS_IFACE, "SearchItems",
            "{'application': 'com.belmoussaoui.Authenticator'}",
        )
        if result and result != "()":
            return [{"label": "account", "raw": result}]
    except DBusError:
        pass
    return []


def _get_secret_for_account(account_label: str) -> str | None:
    """Retrieve the TOTP secret for a specific account.

    This value is NEVER logged or returned to the user.
    """
    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _SECRETS_BUS, _SECRETS_PATH,
            _SECRETS_IFACE, "GetSecret",
            f"'{account_label}'",
        )
        if result and result != "()":
            return result.strip("()'\" ")
    except DBusError:
        pass

    try:
        import keyring
        secret = keyring.get_password(_AUTHENTICATOR_COLLECTION, account_label)
        return secret
    except Exception:
        pass

    return None


@tool
def auth_list() -> str:
    """List all TOTP/2FA accounts in Authenticator.

    Returns account names and issuers.  Secrets are NEVER shown.
    """
    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _SECRETS_BUS, _SECRETS_PATH,
            _SECRETS_IFACE, "SearchItems",
            "{'application': 'com.belmoussaoui.Authenticator'}",
        )
        if not result or result == "()":
            return "(no TOTP accounts found)"
        return f"TOTP accounts:\n{result}"
    except DBusError:
        try:
            import keyring
            creds = keyring.get_credential(_AUTHENTICATOR_COLLECTION, None)
            if creds:
                return f"TOTP accounts: {creds.username}"
        except Exception:
            pass
        return "(no TOTP accounts found — keyring not accessible)"


@tool
def auth_get_code(account: str) -> str:
    """Get the current TOTP code for an account.

    Returns the 6-digit code and seconds until it expires.
    The underlying secret is NEVER exposed.
    """
    secret = _get_secret_for_account(account)
    if not secret:
        return f"(no TOTP secret found for '{account}')"

    code = _generate_totp(secret)
    remaining = _seconds_remaining()
    return f"Code: {code} (expires in {remaining}s)"


@tool
def auth_add(
    account: str,
    issuer: str,
    secret: str = "",
    uri: str = "",
) -> str:
    """Add a new TOTP account to Authenticator.

    Provide either:
    - account + issuer + secret (base32-encoded TOTP secret)
    - uri (otpauth:// URI from a QR code)

    The secret is stored securely in the keyring and NEVER logged.
    """
    if uri:
        if not uri.startswith("otpauth://"):
            return "Error: URI must start with 'otpauth://'"
        adapter = _get_adapter()
        try:
            adapter.dbus.call(
                _SECRETS_BUS, _SECRETS_PATH,
                _SECRETS_IFACE, "CreateItem",
                f"'{uri}'",
            )
            return f"TOTP account added via URI for {issuer or account}"
        except DBusError:
            pass

    if not secret:
        return "Error: provide either 'secret' or 'uri'"

    try:
        import keyring
        keyring.set_password(
            _AUTHENTICATOR_COLLECTION,
            account,
            secret,
        )
        logger.info("TOTP account added: %s (%s) — secret stored in keyring", account, issuer)
        return f"TOTP account added: {account} ({issuer})"
    except Exception as exc:
        return f"Failed to store TOTP secret: {exc}"


# ── registration helper ───────────────────────────────────────────────────

_AUTH_TOOLS = None


def get_authenticator_tools() -> list:
    """Return all Authenticator tools. Returns ``[]`` if not installed."""
    global _AUTH_TOOLS
    if _AUTH_TOOLS is not None:
        return _AUTH_TOOLS

    import shutil
    if shutil.which("authenticator") is not None:
        _AUTH_TOOLS = [auth_list, auth_get_code, auth_add]
    else:
        logger.warning("Authenticator not installed — TOTP tools unavailable")
        _AUTH_TOOLS = []

    return _AUTH_TOOLS
