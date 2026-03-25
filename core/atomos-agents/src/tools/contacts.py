"""GNOME Contacts adapter for atomos-agents.

Connects to GNOME Contacts via the Evolution Data Server (EDS) address
book D-Bus API.  EDS is the backend for all GNOME contact applications.

Tools: contacts_list, contacts_search, contacts_create, contacts_get
"""

from __future__ import annotations

import json
import logging
import subprocess
from typing import Optional

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter, DBusError

logger = logging.getLogger(__name__)

_EDS_ADDRESSBOOK_BUS = "org.gnome.evolution.dataserver.AddressBook"
_EDS_SOURCES_BUS = "org.gnome.evolution.dataserver.Sources"
_EDS_SOURCES_PATH = "/org/gnome/evolution/dataserver/SourceManager"
_EDS_SOURCES_IFACE = "org.gnome.evolution.dataserver.SourceManager"


@register_app_adapter
class ContactsAdapter(AppAdapter):
    namespace = "contacts"
    app_id = "org.gnome.Contacts"
    binary = "gnome-contacts"

    def get_tools(self) -> list:
        return [contacts_list, contacts_search, contacts_create, contacts_get]


_adapter: ContactsAdapter | None = None


def _get_adapter() -> ContactsAdapter:
    global _adapter
    if _adapter is None:
        _adapter = ContactsAdapter()
    return _adapter


def _build_vcard(
    full_name: str,
    email: str = "",
    phone: str = "",
    address: str = "",
    organization: str = "",
    note: str = "",
) -> str:
    """Build a minimal vCard 3.0 string."""
    lines = [
        "BEGIN:VCARD",
        "VERSION:3.0",
        f"FN:{full_name}",
    ]
    parts = full_name.split(None, 1)
    given = parts[0] if parts else ""
    family = parts[1] if len(parts) > 1 else ""
    lines.append(f"N:{family};{given};;;")
    if email:
        lines.append(f"EMAIL;TYPE=INTERNET:{email}")
    if phone:
        lines.append(f"TEL;TYPE=CELL:{phone}")
    if address:
        lines.append(f"ADR;TYPE=HOME:;;{address};;;;")
    if organization:
        lines.append(f"ORG:{organization}")
    if note:
        lines.append(f"NOTE:{note}")
    lines.append("END:VCARD")
    return "\n".join(lines)


@tool
def contacts_list(limit: int = 50) -> str:
    """List contacts from the address book.

    Returns name, email, phone for each contact.
    """
    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _EDS_SOURCES_BUS, _EDS_SOURCES_PATH,
            _EDS_SOURCES_IFACE, "ListContacts",
            str(limit),
        )
        if not result or result == "()":
            return "(no contacts found)"
        return result
    except DBusError:
        try:
            proc = subprocess.run(
                ["gnome-contacts", "--list"],
                capture_output=True, text=True, timeout=10,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                return proc.stdout.strip()
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass
        return "(contacts list unavailable — EDS not responding)"


@tool
def contacts_search(query: str, limit: int = 20) -> str:
    """Search contacts by name, email, or phone number.

    Returns matching contacts with all available fields.
    """
    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _EDS_SOURCES_BUS, _EDS_SOURCES_PATH,
            _EDS_SOURCES_IFACE, "SearchContacts",
            f"'{query}'", str(limit),
        )
        if not result or result == "()":
            return f"(no contacts matching '{query}')"
        return result
    except DBusError:
        return f"(contact search unavailable — EDS not responding)"


@tool
def contacts_create(
    full_name: str,
    email: str = "",
    phone: str = "",
    address: str = "",
    organization: str = "",
    note: str = "",
) -> str:
    """Create a new contact in the address book.

    At minimum, provide full_name.  All other fields are optional.
    """
    adapter = _get_adapter()
    vcard = _build_vcard(full_name, email, phone, address, organization, note)

    try:
        adapter.dbus.call(
            _EDS_SOURCES_BUS, _EDS_SOURCES_PATH,
            _EDS_SOURCES_IFACE, "CreateContact",
            f"'{vcard}'",
        )
        return f"Contact created: {full_name}"
    except DBusError as exc:
        return f"Failed to create contact: {exc}"


@tool
def contacts_get(contact_id: str) -> str:
    """Get detailed information for a specific contact by ID.

    Returns the full vCard data including all fields (phone, email,
    address, photo URL, notes, etc.).
    """
    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _EDS_SOURCES_BUS, _EDS_SOURCES_PATH,
            _EDS_SOURCES_IFACE, "GetContact",
            f"'{contact_id}'",
        )
        if not result or result == "()":
            return f"(contact not found: {contact_id})"
        return result
    except DBusError:
        return f"(contact details unavailable — EDS not responding)"


# ── registration helper ───────────────────────────────────────────────────

_CONTACTS_TOOLS = None


def get_contacts_tools() -> list:
    """Return all GNOME Contacts tools. Returns ``[]`` if not installed."""
    global _CONTACTS_TOOLS
    if _CONTACTS_TOOLS is not None:
        return _CONTACTS_TOOLS

    import shutil
    if shutil.which("gnome-contacts") is not None:
        _CONTACTS_TOOLS = [contacts_list, contacts_search, contacts_create, contacts_get]
    else:
        logger.warning("GNOME Contacts not installed — contact tools unavailable")
        _CONTACTS_TOOLS = []

    return _CONTACTS_TOOLS
