"""
Tests for the Passes password manager adapter (tools/passes.py).

Covers:
  - Tool registration and discovery via get_passes_tools()
  - Tool names and argument schemas
  - Secret Service D-Bus integration (mock)
  - Credential relay token creation and consumption
  - Security: passwords never appear in tool output
  - Error handling
  - Registry integration
"""

import json
import time
import pytest
from unittest.mock import MagicMock, patch

from tools.app_adapter import DBusError


def _reset():
    import tools.passes as mod
    mod._adapter = None
    mod._PASSES_TOOLS = None
    mod._credential_relay.clear()


class TestPassesToolRegistration:

    def test_get_passes_tools_returns_four(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/passes"):
            from tools.passes import get_passes_tools
            result = get_passes_tools()
            assert len(result) == 4
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/passes"):
            from tools.passes import get_passes_tools
            names = {t.name for t in get_passes_tools()}
            assert names == {"pass_list", "pass_get", "pass_add", "pass_search"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        with patch("shutil.which", return_value=None):
            from tools.passes import get_passes_tools
            result = get_passes_tools()
            assert result == []
        _reset()


class TestPassList:

    def test_list_credentials(self):
        _reset()
        from tools.passes import pass_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('github.com:user', 'gitlab.com:user')"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = pass_list.invoke({"limit": 50})
            assert "github.com" in result
        _reset()

    def test_list_empty(self):
        _reset()
        from tools.passes import pass_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = pass_list.invoke({"limit": 50})
            assert "no stored credentials" in result
        _reset()

    def test_list_dbus_error(self):
        _reset()
        from tools.passes import pass_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("keyring locked")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch.dict("sys.modules", {"keyring": None}):
            result = pass_list.invoke({"limit": 50})
            assert "not accessible" in result
        _reset()


class TestPassGet:

    def test_get_returns_relay_token(self):
        _reset()
        from tools.passes import pass_get, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "'s3cretPa55'"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = pass_get.invoke({"service": "github.com", "username": "user"})
            assert "Relay token" in result
            assert "Credential ready" in result
        _reset()

    def test_get_password_never_in_output(self):
        _reset()
        from tools.passes import pass_get, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        password = "MyS3cretP@ssw0rd!"
        mock_dbus.call.return_value = f"'{password}'"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = pass_get.invoke({"service": "github.com", "username": "user"})
            assert password not in result
            assert "S3cret" not in result
            assert "P@ssw0rd" not in result
        _reset()

    def test_get_no_credentials(self):
        _reset()
        from tools.passes import pass_get, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch.dict("sys.modules", {"keyring": None}):
            result = pass_get.invoke({"service": "unknown.com"})
            assert "no credentials found" in result
        _reset()


class TestPassAdd:

    def test_add_credential(self):
        _reset()
        from tools.passes import pass_add

        mock_keyring = MagicMock()
        mock_keyring.set_password = MagicMock()

        with patch.dict("sys.modules", {"keyring": mock_keyring}):
            result = pass_add.invoke({
                "service": "github.com",
                "username": "user",
                "password": "s3cret",
            })
            assert "Credentials stored" in result
            assert "github.com" in result
            assert "user" in result
        _reset()

    def test_add_password_not_in_output(self):
        _reset()
        from tools.passes import pass_add

        mock_keyring = MagicMock()
        mock_keyring.set_password = MagicMock()
        password = "MySuperSecret123!"

        with patch.dict("sys.modules", {"keyring": mock_keyring}):
            result = pass_add.invoke({
                "service": "example.com",
                "username": "admin",
                "password": password,
            })
            assert password not in result
        _reset()

    def test_add_keyring_failure(self):
        _reset()
        from tools.passes import pass_add

        mock_keyring = MagicMock()
        mock_keyring.set_password.side_effect = Exception("keyring unavailable")

        with patch.dict("sys.modules", {"keyring": mock_keyring}):
            result = pass_add.invoke({
                "service": "example.com",
                "username": "user",
                "password": "pass",
            })
            assert "Failed" in result
        _reset()


class TestPassSearch:

    def test_search_returns_matches(self):
        _reset()
        from tools.passes import pass_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('github.com:user',)"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = pass_search.invoke({"query": "github"})
            assert "github" in result
        _reset()

    def test_search_no_matches(self):
        _reset()
        from tools.passes import pass_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = pass_search.invoke({"query": "nonexistent"})
            assert "no credentials matching" in result
        _reset()

    def test_search_dbus_error(self):
        _reset()
        from tools.passes import pass_search, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("keyring down")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = pass_search.invoke({"query": "test"})
            assert "unavailable" in result
        _reset()


class TestCredentialRelay:

    def test_create_and_consume_token(self):
        _reset()
        from tools.passes import _create_relay_token, _consume_relay_token
        token = _create_relay_token("user", "pass123")
        assert len(token) == 12

        creds = _consume_relay_token(token)
        assert creds is not None
        assert creds == ("user", "pass123")
        _reset()

    def test_token_consumed_only_once(self):
        _reset()
        from tools.passes import _create_relay_token, _consume_relay_token
        token = _create_relay_token("user", "pass")
        assert _consume_relay_token(token) is not None
        assert _consume_relay_token(token) is None
        _reset()

    def test_expired_token_returns_none(self):
        _reset()
        from tools.passes import _create_relay_token, _consume_relay_token, _credential_relay
        token = _create_relay_token("user", "pass")

        username, password, _ = _credential_relay[token]
        _credential_relay[token] = (username, password, time.time() - 120)

        assert _consume_relay_token(token) is None
        _reset()

    def test_cleanup_expired_tokens(self):
        _reset()
        from tools.passes import _create_relay_token, _cleanup_expired_tokens, _credential_relay

        token1 = _create_relay_token("user1", "pass1")
        token2 = _create_relay_token("user2", "pass2")

        u, p, _ = _credential_relay[token1]
        _credential_relay[token1] = (u, p, time.time() - 120)

        _cleanup_expired_tokens()
        assert token1 not in _credential_relay
        assert token2 in _credential_relay
        _reset()


class TestRegistryIntegration:

    def test_passes_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "pass_list" in _ALLOWED_EXPOSED_TOOLS
        assert "pass_get" in _ALLOWED_EXPOSED_TOOLS
        assert "pass_add" in _ALLOWED_EXPOSED_TOOLS
        assert "pass_search" in _ALLOWED_EXPOSED_TOOLS
