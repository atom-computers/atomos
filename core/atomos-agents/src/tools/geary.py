"""Geary email client adapter for atomos-agents.

Connects to Geary running in iso-ubuntu via its D-Bus API
(``org.gnome.Geary``) and Evolution Data Server.  Falls back to AT-SPI
automation when D-Bus methods are unavailable.

Tools: email_compose, email_send, email_search, email_read
"""

from __future__ import annotations

import json
import logging
from typing import Optional

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter, DBusError

logger = logging.getLogger(__name__)

_GEARY_BUS = "org.gnome.Geary"
_GEARY_PATH = "/org/gnome/Geary"
_GEARY_IFACE = "org.gnome.Geary"
_GEARY_COMPOSE_IFACE = "org.gnome.Geary.Compose"


@register_app_adapter
class GearyAdapter(AppAdapter):
    namespace = "email"
    app_id = "org.gnome.Geary"
    binary = "geary"

    def get_tools(self) -> list:
        return [email_compose, email_send, email_search, email_read]


_adapter: GearyAdapter | None = None


def _get_adapter() -> GearyAdapter:
    global _adapter
    if _adapter is None:
        _adapter = GearyAdapter()
    return _adapter


def _check_running() -> str | None:
    adapter = _get_adapter()
    err = adapter.ensure_running()
    if err:
        return err
    return None


@tool
def email_compose(
    to: str,
    subject: str,
    body: str,
    cc: str = "",
    bcc: str = "",
) -> str:
    """Compose a new email in Geary.

    Creates a draft email with the given recipients, subject, and body.
    The email is NOT sent until email_send is called — this allows the
    human to review before sending.
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        mailto = f"mailto:{to}?subject={subject}"
        if cc:
            mailto += f"&cc={cc}"
        if bcc:
            mailto += f"&bcc={bcc}"

        adapter.dbus.call(
            _GEARY_BUS, _GEARY_PATH,
            "org.freedesktop.Application", "Open",
            f"['{mailto}']", "{}",
        )
        adapter.set_cached("last_draft", {
            "to": to, "subject": subject, "body": body,
            "cc": cc, "bcc": bcc,
        })
        return f"Draft composed: To={to}, Subject={subject}"
    except DBusError:
        try:
            import subprocess
            subprocess.Popen(
                ["geary", f"mailto:{to}?subject={subject}&body={body}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            return f"Draft composed (via CLI): To={to}, Subject={subject}"
        except Exception as exc:
            return f"Failed to compose email: {exc}"


@tool
def email_send(
    to: str,
    subject: str,
    body: str,
    cc: str = "",
    bcc: str = "",
) -> str:
    """Send an email via Geary.

    Composes and sends the email immediately.  This action requires
    human-in-the-loop approval before execution.
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        mailto_parts = [f"mailto:{to}?subject={subject}&body={body}"]
        if cc:
            mailto_parts[0] += f"&cc={cc}"
        if bcc:
            mailto_parts[0] += f"&bcc={bcc}"

        adapter.dbus.call(
            _GEARY_BUS, _GEARY_PATH,
            _GEARY_IFACE, "SendCompose",
            f"'{to}'", f"'{cc}'", f"'{bcc}'", f"'{subject}'", f"'{body}'",
        )
        return f"Email sent to {to}: {subject}"
    except DBusError as exc:
        return f"Failed to send email via D-Bus: {exc}"


@tool
def email_search(
    query: str,
    folder: str = "INBOX",
    max_results: int = 20,
) -> str:
    """Search emails in Geary by keyword.

    Searches the specified folder (default INBOX) for messages matching
    the query string.  Returns subject, sender, date, and snippet.
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _GEARY_BUS, _GEARY_PATH,
            _GEARY_IFACE, "Search",
            f"'{query}'", f"'{folder}'", str(max_results),
        )
        if not result or result == "()":
            return "(no matching emails found)"
        return result
    except DBusError:
        try:
            import subprocess
            proc = subprocess.run(
                ["geary", "--search", query],
                capture_output=True, text=True, timeout=15,
            )
            return proc.stdout.strip() if proc.stdout else "(no matching emails found)"
        except Exception:
            return "(email search unavailable — Geary D-Bus API not responding)"


@tool
def email_read(
    message_id: str = "",
    folder: str = "INBOX",
    index: int = 0,
) -> str:
    """Read an email message from Geary.

    Provide a message_id to read a specific email, or use folder+index
    to read the Nth most recent message in a folder.  Returns the full
    email content including headers and body.
    """
    err = _check_running()
    if err:
        return err

    adapter = _get_adapter()
    try:
        if message_id:
            result = adapter.dbus.call(
                _GEARY_BUS, _GEARY_PATH,
                _GEARY_IFACE, "GetMessage",
                f"'{message_id}'",
            )
        else:
            result = adapter.dbus.call(
                _GEARY_BUS, _GEARY_PATH,
                _GEARY_IFACE, "GetMessageByIndex",
                f"'{folder}'", str(index),
            )
        if not result or result == "()":
            return "(message not found)"
        return result
    except DBusError:
        return "(email read unavailable — Geary D-Bus API not responding)"


# ── registration helper ───────────────────────────────────────────────────

_GEARY_TOOLS = None


def get_geary_tools() -> list:
    """Return all Geary email tools. Returns ``[]`` if Geary is not installed."""
    global _GEARY_TOOLS
    if _GEARY_TOOLS is not None:
        return _GEARY_TOOLS

    import shutil
    if shutil.which("geary") is not None:
        _GEARY_TOOLS = [email_compose, email_send, email_search, email_read]
    else:
        logger.warning("Geary not installed — email tools unavailable")
        _GEARY_TOOLS = []

    return _GEARY_TOOLS
