"""Karlender calendar adapter for atomos-agents.

Connects to Karlender (or any CalDAV-backed calendar) running in
iso-ubuntu.  Uses Evolution Data Server (EDS) D-Bus API as the primary
interface since most GNOME calendar apps delegate storage to EDS.

Tools: calendar_list, calendar_create, calendar_update, calendar_delete, calendar_search
"""

from __future__ import annotations

import json
import logging
import subprocess
from datetime import datetime, timedelta
from typing import Optional

from langchain_core.tools import tool

from tools.app_adapter import AppAdapter, register_app_adapter, DBusError

logger = logging.getLogger(__name__)

_EDS_CAL_BUS = "org.gnome.evolution.dataserver.Calendar"
_EDS_SOURCES_BUS = "org.gnome.evolution.dataserver.Sources"
_EDS_SOURCES_PATH = "/org/gnome/evolution/dataserver/SourceManager"
_EDS_SOURCES_IFACE = "org.gnome.evolution.dataserver.SourceManager"


@register_app_adapter
class KarlenderAdapter(AppAdapter):
    namespace = "calendar"
    app_id = "org.gnome.Karlender"
    binary = "karlender"

    def get_tools(self) -> list:
        return [calendar_list, calendar_create, calendar_update, calendar_delete, calendar_search]


_adapter: KarlenderAdapter | None = None


def _get_adapter() -> KarlenderAdapter:
    global _adapter
    if _adapter is None:
        _adapter = KarlenderAdapter()
    return _adapter


def _check_eds() -> str | None:
    """Check if EDS (Evolution Data Server) is reachable."""
    adapter = _get_adapter()
    try:
        adapter.dbus.call(
            _EDS_SOURCES_BUS, _EDS_SOURCES_PATH,
            _EDS_SOURCES_IFACE, "ListSources",
        )
        return None
    except DBusError:
        return "Evolution Data Server not responding — calendar operations unavailable"


def _run_eds_query(query: str) -> str:
    """Run a calendar query via gnome-calendar-cli or D-Bus."""
    try:
        proc = subprocess.run(
            ["gnome-calendar", "--list-events"],
            capture_output=True, text=True, timeout=10,
        )
        if proc.returncode == 0:
            return proc.stdout.strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return ""


@tool
def calendar_list(
    time_min: str = "",
    time_max: str = "",
    max_results: int = 20,
) -> str:
    """List upcoming calendar events.

    time_min/time_max are ISO 8601 datetime strings (e.g. '2025-01-15T09:00:00').
    Defaults to today through the next 7 days.
    """
    if not time_min:
        time_min = datetime.now().isoformat()
    if not time_max:
        time_max = (datetime.now() + timedelta(days=7)).isoformat()

    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _EDS_SOURCES_BUS, _EDS_SOURCES_PATH,
            _EDS_SOURCES_IFACE, "ListEvents",
            f"'{time_min}'", f"'{time_max}'", str(max_results),
        )
        if not result or result == "()":
            return "(no upcoming events)"
        return result
    except DBusError:
        output = _run_eds_query("list")
        return output if output else "(no upcoming events — calendar service not responding)"


@tool
def calendar_create(
    summary: str,
    start_time: str,
    end_time: str,
    description: str = "",
    location: str = "",
    attendees: str = "",
    all_day: bool = False,
) -> str:
    """Create a new calendar event.

    start_time and end_time are ISO 8601 datetime strings.
    attendees is a comma-separated list of email addresses.
    This action requires human-in-the-loop approval.
    """
    adapter = _get_adapter()

    ical_lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "BEGIN:VEVENT",
        f"SUMMARY:{summary}",
        f"DTSTART:{_to_ical_dt(start_time, all_day)}",
        f"DTEND:{_to_ical_dt(end_time, all_day)}",
    ]
    if description:
        ical_lines.append(f"DESCRIPTION:{description}")
    if location:
        ical_lines.append(f"LOCATION:{location}")
    if attendees:
        for addr in attendees.split(","):
            addr = addr.strip()
            if addr:
                ical_lines.append(f"ATTENDEE:mailto:{addr}")
    ical_lines.extend(["END:VEVENT", "END:VCALENDAR"])
    ical = "\n".join(ical_lines)

    try:
        adapter.dbus.call(
            _EDS_SOURCES_BUS, _EDS_SOURCES_PATH,
            _EDS_SOURCES_IFACE, "CreateEvent",
            f"'{ical}'",
        )
        return f"Event created: {summary} ({start_time} — {end_time})"
    except DBusError as exc:
        return f"Failed to create event: {exc}"


@tool
def calendar_update(
    event_id: str,
    summary: str = "",
    start_time: str = "",
    end_time: str = "",
    description: str = "",
    location: str = "",
) -> str:
    """Update an existing calendar event.

    Provide the event_id and any fields to update.  Unchanged fields
    retain their current values.
    """
    adapter = _get_adapter()
    try:
        updates = {}
        if summary:
            updates["summary"] = summary
        if start_time:
            updates["start_time"] = start_time
        if end_time:
            updates["end_time"] = end_time
        if description:
            updates["description"] = description
        if location:
            updates["location"] = location

        adapter.dbus.call(
            _EDS_SOURCES_BUS, _EDS_SOURCES_PATH,
            _EDS_SOURCES_IFACE, "UpdateEvent",
            f"'{event_id}'", f"'{json.dumps(updates)}'",
        )
        return f"Event updated: {event_id}"
    except DBusError as exc:
        return f"Failed to update event: {exc}"


@tool
def calendar_delete(event_id: str) -> str:
    """Delete a calendar event by ID.

    This action requires human-in-the-loop approval.
    """
    adapter = _get_adapter()
    try:
        adapter.dbus.call(
            _EDS_SOURCES_BUS, _EDS_SOURCES_PATH,
            _EDS_SOURCES_IFACE, "DeleteEvent",
            f"'{event_id}'",
        )
        return f"Event deleted: {event_id}"
    except DBusError as exc:
        return f"Failed to delete event: {exc}"


@tool
def calendar_search(
    query: str,
    time_min: str = "",
    time_max: str = "",
    max_results: int = 20,
) -> str:
    """Search calendar events by keyword.

    Searches event summaries, descriptions, and locations.
    Optionally restrict by date range.
    """
    if not time_min:
        time_min = (datetime.now() - timedelta(days=30)).isoformat()
    if not time_max:
        time_max = (datetime.now() + timedelta(days=365)).isoformat()

    adapter = _get_adapter()
    try:
        result = adapter.dbus.call(
            _EDS_SOURCES_BUS, _EDS_SOURCES_PATH,
            _EDS_SOURCES_IFACE, "SearchEvents",
            f"'{query}'", f"'{time_min}'", f"'{time_max}'", str(max_results),
        )
        if not result or result == "()":
            return f"(no events matching '{query}')"
        return result
    except DBusError:
        return f"(calendar search unavailable — EDS not responding)"


def _to_ical_dt(iso_str: str, all_day: bool = False) -> str:
    """Convert ISO 8601 to iCalendar datetime format."""
    try:
        dt = datetime.fromisoformat(iso_str)
        if all_day:
            return dt.strftime("%Y%m%d")
        return dt.strftime("%Y%m%dT%H%M%S")
    except ValueError:
        return iso_str.replace("-", "").replace(":", "").replace("T", "T")


# ── registration helper ───────────────────────────────────────────────────

_KARLENDER_TOOLS = None


def get_karlender_tools() -> list:
    """Return all Karlender calendar tools. Returns ``[]`` if not installed."""
    global _KARLENDER_TOOLS
    if _KARLENDER_TOOLS is not None:
        return _KARLENDER_TOOLS

    import shutil
    has_karlender = shutil.which("karlender") is not None
    has_eds = shutil.which("gnome-calendar") is not None
    if has_karlender or has_eds:
        _KARLENDER_TOOLS = [calendar_list, calendar_create, calendar_update, calendar_delete, calendar_search]
    else:
        logger.warning("Karlender/EDS not installed — calendar tools unavailable")
        _KARLENDER_TOOLS = []

    return _KARLENDER_TOOLS
