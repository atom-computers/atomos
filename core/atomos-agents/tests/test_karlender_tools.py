"""
Tests for the Karlender calendar adapter (tools/karlender.py).

Covers:
  - Tool registration and discovery via get_karlender_tools()
  - Tool names and argument schemas
  - EDS D-Bus integration (mock)
  - iCal event generation
  - Error handling
  - Registry integration
"""

import json
import pytest
from unittest.mock import MagicMock, patch

from tools.app_adapter import DBusError


def _reset():
    import tools.karlender as mod
    mod._adapter = None
    mod._KARLENDER_TOOLS = None


class TestKarlenderToolRegistration:

    def test_get_karlender_tools_returns_five(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/karlender"):
            from tools.karlender import get_karlender_tools
            result = get_karlender_tools()
            assert len(result) == 5
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/karlender"):
            from tools.karlender import get_karlender_tools
            names = {t.name for t in get_karlender_tools()}
            assert names == {"calendar_list", "calendar_create", "calendar_update", "calendar_delete", "calendar_search"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        with patch("shutil.which", return_value=None):
            from tools.karlender import get_karlender_tools
            result = get_karlender_tools()
            assert result == []
        _reset()

    def test_returns_tools_when_gnome_calendar_available(self):
        _reset()
        def fake_which(name):
            if name == "gnome-calendar":
                return "/usr/bin/gnome-calendar"
            return None
        with patch("shutil.which", side_effect=fake_which):
            from tools.karlender import get_karlender_tools
            result = get_karlender_tools()
            assert len(result) == 5
        _reset()


class TestCalendarList:

    def test_list_returns_events(self):
        _reset()
        from tools.karlender import calendar_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('Team meeting @ 9am', 'Lunch @ 12pm')"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_list.invoke({})
            assert "Team meeting" in result
        _reset()

    def test_list_empty(self):
        _reset()
        from tools.karlender import calendar_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_list.invoke({})
            assert "no upcoming events" in result
        _reset()

    def test_list_dbus_error_fallback(self):
        _reset()
        from tools.karlender import calendar_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("EDS down")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch("tools.karlender._run_eds_query", return_value=""):
            result = calendar_list.invoke({})
            assert "no upcoming events" in result
        _reset()


class TestCalendarCreate:

    def test_create_event_via_dbus(self):
        _reset()
        from tools.karlender import calendar_create, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_create.invoke({
                "summary": "Team standup",
                "start_time": "2025-06-15T09:00:00",
                "end_time": "2025-06-15T09:30:00",
            })
            assert "Event created" in result
            assert "Team standup" in result

            call_args = mock_dbus.call.call_args
            ical_arg = call_args[0][-1]
            assert "VCALENDAR" in ical_arg
            assert "VEVENT" in ical_arg
            assert "SUMMARY:Team standup" in ical_arg
        _reset()

    def test_create_event_with_attendees(self):
        _reset()
        from tools.karlender import calendar_create, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_create.invoke({
                "summary": "Review",
                "start_time": "2025-06-15T14:00:00",
                "end_time": "2025-06-15T15:00:00",
                "attendees": "alice@co.com, bob@co.com",
            })
            assert "Event created" in result

            call_args = mock_dbus.call.call_args
            ical_arg = call_args[0][-1]
            assert "ATTENDEE:mailto:alice@co.com" in ical_arg
            assert "ATTENDEE:mailto:bob@co.com" in ical_arg
        _reset()

    def test_create_all_day_event(self):
        _reset()
        from tools.karlender import calendar_create, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_create.invoke({
                "summary": "Holiday",
                "start_time": "2025-12-25T00:00:00",
                "end_time": "2025-12-26T00:00:00",
                "all_day": True,
            })
            assert "Event created" in result

            call_args = mock_dbus.call.call_args
            ical_arg = call_args[0][-1]
            assert "20251225" in ical_arg
        _reset()

    def test_create_dbus_error(self):
        _reset()
        from tools.karlender import calendar_create, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("EDS not available")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_create.invoke({
                "summary": "Test",
                "start_time": "2025-06-15T09:00:00",
                "end_time": "2025-06-15T10:00:00",
            })
            assert "Failed" in result
        _reset()


class TestCalendarUpdate:

    def test_update_event(self):
        _reset()
        from tools.karlender import calendar_update, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_update.invoke({
                "event_id": "evt-123",
                "summary": "Updated standup",
            })
            assert "Event updated" in result
            assert "evt-123" in result
        _reset()

    def test_update_dbus_error(self):
        _reset()
        from tools.karlender import calendar_update, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("update failed")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_update.invoke({
                "event_id": "evt-123",
                "summary": "New title",
            })
            assert "Failed" in result
        _reset()


class TestCalendarDelete:

    def test_delete_event(self):
        _reset()
        from tools.karlender import calendar_delete, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_delete.invoke({"event_id": "evt-456"})
            assert "Event deleted" in result
            assert "evt-456" in result
        _reset()

    def test_delete_dbus_error(self):
        _reset()
        from tools.karlender import calendar_delete, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("delete failed")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_delete.invoke({"event_id": "evt-456"})
            assert "Failed" in result
        _reset()


class TestCalendarSearch:

    def test_search_returns_results(self):
        _reset()
        from tools.karlender import calendar_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('Meeting with Alice @ 2pm',)"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_search.invoke({"query": "Alice"})
            assert "Alice" in result
        _reset()

    def test_search_no_results(self):
        _reset()
        from tools.karlender import calendar_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_search.invoke({"query": "nonexistent"})
            assert "no events matching" in result
        _reset()

    def test_search_dbus_error(self):
        _reset()
        from tools.karlender import calendar_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("EDS down")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = calendar_search.invoke({"query": "test"})
            assert "unavailable" in result
        _reset()


class TestICalGeneration:

    def test_to_ical_dt_datetime(self):
        _reset()
        from tools.karlender import _to_ical_dt
        result = _to_ical_dt("2025-06-15T14:30:00")
        assert result == "20250615T143000"
        _reset()

    def test_to_ical_dt_all_day(self):
        _reset()
        from tools.karlender import _to_ical_dt
        result = _to_ical_dt("2025-12-25T00:00:00", all_day=True)
        assert result == "20251225"
        _reset()


class TestRegistryIntegration:

    def test_karlender_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "calendar_list" in _ALLOWED_EXPOSED_TOOLS
        assert "calendar_create" in _ALLOWED_EXPOSED_TOOLS
        assert "calendar_update" in _ALLOWED_EXPOSED_TOOLS
        assert "calendar_delete" in _ALLOWED_EXPOSED_TOOLS
        assert "calendar_search" in _ALLOWED_EXPOSED_TOOLS
