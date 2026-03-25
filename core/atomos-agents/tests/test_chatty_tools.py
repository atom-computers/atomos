"""
Tests for the Chatty messaging adapter (tools/chatty.py).

Covers:
  - Tool registration and discovery
  - Tool names and argument schemas
  - Handler invocation round-trip (mock D-Bus)
  - Error handling
  - Registry integration
"""

import pytest
from unittest.mock import MagicMock, patch

from tools.app_adapter import DBusError


def _reset():
    import tools.chatty as mod
    mod._adapter = None
    mod._CHATTY_TOOLS = None


class TestChattyToolRegistration:

    def test_get_chatty_tools_returns_four(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/chatty"):
            from tools.chatty import get_chatty_tools
            result = get_chatty_tools()
            assert len(result) == 4
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/chatty"):
            from tools.chatty import get_chatty_tools
            names = {t.name for t in get_chatty_tools()}
            assert names == {"chat_send", "chat_read", "chat_list", "chat_search"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        with patch("shutil.which", return_value=None):
            from tools.chatty import get_chatty_tools
            assert get_chatty_tools() == []
        _reset()


class TestChatSend:

    def test_send_success(self):
        _reset()
        from tools.chatty import chat_send, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = chat_send.invoke({"recipient": "@alice:matrix.org", "message": "hi"})
            assert "sent" in result.lower()
        _reset()

    def test_send_dbus_error(self):
        _reset()
        from tools.chatty import chat_send, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("fail")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = chat_send.invoke({"recipient": "@alice:matrix.org", "message": "hi"})
            assert "Failed" in result
        _reset()


class TestChatRead:

    def test_read_by_recipient(self):
        _reset()
        from tools.chatty import chat_read, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('Alice: hello', 'Bob: hi')"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = chat_read.invoke({"recipient": "Alice"})
            assert "Alice" in result
        _reset()

    def test_read_requires_id_or_recipient(self):
        _reset()
        from tools.chatty import chat_read, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = chat_read.invoke({})
            assert "Error" in result or "provide" in result
        _reset()


class TestChatList:

    def test_list_conversations(self):
        _reset()
        from tools.chatty import chat_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('conv1', 'conv2')"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = chat_list.invoke({})
            assert "conv" in result
        _reset()

    def test_list_empty(self):
        _reset()
        from tools.chatty import chat_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = chat_list.invoke({})
            assert "no conversations" in result
        _reset()


class TestChatSearch:

    def test_search_matches(self):
        _reset()
        from tools.chatty import chat_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('matched message',)"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = chat_search.invoke({"query": "hello"})
            assert "matched" in result
        _reset()


class TestRegistryIntegration:

    def test_chatty_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "chat_send" in _ALLOWED_EXPOSED_TOOLS
        assert "chat_read" in _ALLOWED_EXPOSED_TOOLS
        assert "chat_list" in _ALLOWED_EXPOSED_TOOLS
        assert "chat_search" in _ALLOWED_EXPOSED_TOOLS
