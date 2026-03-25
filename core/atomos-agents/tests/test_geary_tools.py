"""
Tests for the Geary email adapter (tools/geary.py).

Covers:
  - Tool registration and discovery via get_geary_tools()
  - Tool names and argument schemas
  - Handler invocation round-trip (mock D-Bus)
  - Error handling when Geary is unavailable
  - Registry integration
"""

import json
import pytest
from unittest.mock import MagicMock, patch

from tools.app_adapter import DBusError


def _reset():
    import tools.geary as mod
    mod._adapter = None
    mod._GEARY_TOOLS = None


class TestGearyToolRegistration:

    def test_get_geary_tools_returns_four(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/geary"):
            from tools.geary import get_geary_tools
            result = get_geary_tools()
            assert len(result) == 4
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/geary"):
            from tools.geary import get_geary_tools
            names = {t.name for t in get_geary_tools()}
            assert names == {"email_compose", "email_send", "email_search", "email_read"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        with patch("shutil.which", return_value=None):
            from tools.geary import get_geary_tools
            result = get_geary_tools()
            assert result == []
        _reset()


class TestEmailCompose:

    def test_compose_via_dbus(self):
        _reset()
        from tools.geary import email_compose, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = email_compose.invoke({
                "to": "test@example.com",
                "subject": "Hello",
                "body": "World",
            })
            assert "Draft composed" in result
            assert "test@example.com" in result
        _reset()


class TestEmailSend:

    def test_send_via_dbus(self):
        _reset()
        from tools.geary import email_send, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = email_send.invoke({
                "to": "test@example.com",
                "subject": "Hello",
                "body": "World",
            })
            assert "sent" in result.lower() or "Email" in result
        _reset()

    def test_send_dbus_error(self):
        _reset()
        from tools.geary import email_send, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("test error")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = email_send.invoke({
                "to": "test@example.com",
                "subject": "Hello",
                "body": "World",
            })
            assert "Failed" in result
        _reset()


class TestEmailSearch:

    def test_search_returns_results(self):
        _reset()
        from tools.geary import email_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('Subject: Test email',)"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = email_search.invoke({"query": "test"})
            assert "Test email" in result
        _reset()

    def test_search_empty(self):
        _reset()
        from tools.geary import email_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = email_search.invoke({"query": "nonexistent"})
            assert "no matching" in result
        _reset()


class TestEmailRead:

    def test_read_by_id(self):
        _reset()
        from tools.geary import email_read, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "From: sender@test.com\nSubject: Hello\n\nBody text"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = email_read.invoke({"message_id": "msg-123"})
            assert "sender@test.com" in result
        _reset()

    def test_read_not_found(self):
        _reset()
        from tools.geary import email_read, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = email_read.invoke({"message_id": "missing"})
            assert "not found" in result
        _reset()


class TestRegistryIntegration:

    def test_email_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "email_compose" in _ALLOWED_EXPOSED_TOOLS
        assert "email_send" in _ALLOWED_EXPOSED_TOOLS
        assert "email_search" in _ALLOWED_EXPOSED_TOOLS
        assert "email_read" in _ALLOWED_EXPOSED_TOOLS
