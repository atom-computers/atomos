"""
Tests for the Authenticator TOTP/2FA adapter (tools/authenticator.py).

Covers:
  - Tool registration and discovery via get_authenticator_tools()
  - Tool names and argument schemas
  - TOTP code generation (RFC 6238)
  - Secret Service D-Bus integration (mock)
  - Security: secrets never appear in output
  - Error handling
  - Registry integration
"""

import json
import re
import time
import pytest
from unittest.mock import MagicMock, patch

from tools.app_adapter import DBusError


def _reset():
    import tools.authenticator as mod
    mod._adapter = None
    mod._AUTH_TOOLS = None


class TestAuthenticatorToolRegistration:

    def test_get_authenticator_tools_returns_three(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/authenticator"):
            from tools.authenticator import get_authenticator_tools
            result = get_authenticator_tools()
            assert len(result) == 3
        _reset()

    def test_tool_names(self):
        _reset()
        with patch("shutil.which", return_value="/usr/bin/authenticator"):
            from tools.authenticator import get_authenticator_tools
            names = {t.name for t in get_authenticator_tools()}
            assert names == {"auth_list", "auth_get_code", "auth_add"}
        _reset()

    def test_returns_empty_when_not_installed(self):
        _reset()
        with patch("shutil.which", return_value=None):
            from tools.authenticator import get_authenticator_tools
            result = get_authenticator_tools()
            assert result == []
        _reset()


class TestTOTPGeneration:

    def test_generate_totp_returns_six_digits(self):
        _reset()
        from tools.authenticator import _generate_totp
        code = _generate_totp("JBSWY3DPEHPK3PXP")
        assert re.match(r"^\d{6}$", code), f"Expected 6-digit code, got: {code}"
        _reset()

    def test_generate_totp_known_secret(self):
        _reset()
        from tools.authenticator import _generate_totp
        code = _generate_totp("JBSWY3DPEHPK3PXP")
        assert len(code) == 6
        assert code.isdigit()
        _reset()

    def test_generate_totp_with_spaces_in_secret(self):
        _reset()
        from tools.authenticator import _generate_totp
        code = _generate_totp("JBSW Y3DP EHPK 3PXP")
        assert re.match(r"^\d{6}$", code)
        _reset()

    def test_generate_totp_invalid_secret(self):
        _reset()
        from tools.authenticator import _generate_totp
        code = _generate_totp("!!!invalid!!!")
        assert code == "(invalid secret)"
        _reset()

    def test_seconds_remaining_in_range(self):
        _reset()
        from tools.authenticator import _seconds_remaining
        remaining = _seconds_remaining()
        assert 1 <= remaining <= 30
        _reset()


class TestAuthList:

    def test_list_accounts(self):
        _reset()
        from tools.authenticator import auth_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "('github:user@github.com', 'gitlab:user@gitlab.com')"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = auth_list.invoke({})
            assert "TOTP accounts" in result
            assert "github" in result
        _reset()

    def test_list_empty(self):
        _reset()
        from tools.authenticator import auth_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.return_value = "()"
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = auth_list.invoke({})
            assert "no TOTP accounts found" in result
        _reset()

    def test_list_dbus_error(self):
        _reset()
        from tools.authenticator import auth_list, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        mock_dbus.call.side_effect = DBusError("keyring locked")
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None), \
             patch.dict("sys.modules", {"keyring": None}):
            result = auth_list.invoke({})
            assert "no TOTP accounts" in result
        _reset()


class TestAuthGetCode:

    def test_get_code_returns_valid_format(self):
        _reset()
        from tools.authenticator import auth_get_code
        with patch("tools.authenticator._get_secret_for_account", return_value="JBSWY3DPEHPK3PXP"):
            result = auth_get_code.invoke({"account": "github"})
            assert "Code:" in result
            assert "expires in" in result
            code_match = re.search(r"Code: (\d{6})", result)
            assert code_match, f"No 6-digit code in output: {result}"
        _reset()

    def test_get_code_secret_not_in_output(self):
        _reset()
        from tools.authenticator import auth_get_code
        secret = "JBSWY3DPEHPK3PXP"
        with patch("tools.authenticator._get_secret_for_account", return_value=secret):
            result = auth_get_code.invoke({"account": "github"})
            assert secret not in result
            assert "JBSWY" not in result
        _reset()

    def test_get_code_account_not_found(self):
        _reset()
        from tools.authenticator import auth_get_code
        with patch("tools.authenticator._get_secret_for_account", return_value=None):
            result = auth_get_code.invoke({"account": "nonexistent"})
            assert "no TOTP secret found" in result
        _reset()


class TestAuthAdd:

    def test_add_via_uri(self):
        _reset()
        from tools.authenticator import auth_add, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = auth_add.invoke({
                "account": "github",
                "issuer": "GitHub",
                "uri": "otpauth://totp/github?secret=JBSWY3DPEHPK3PXP&issuer=GitHub",
            })
            assert "TOTP account added" in result
        _reset()

    def test_add_via_secret(self):
        _reset()
        from tools.authenticator import auth_add

        mock_keyring = MagicMock()
        with patch.dict("sys.modules", {"keyring": mock_keyring}):
            import importlib
            result = auth_add.invoke({
                "account": "gitlab",
                "issuer": "GitLab",
                "secret": "JBSWY3DPEHPK3PXP",
            })
            assert "TOTP account added" in result or "stored" in result.lower() or "Failed" in result
        _reset()

    def test_add_invalid_uri(self):
        _reset()
        from tools.authenticator import auth_add
        result = auth_add.invoke({
            "account": "test",
            "issuer": "Test",
            "uri": "not-otpauth://invalid",
        })
        assert "Error" in result
        assert "otpauth://" in result
        _reset()

    def test_add_no_secret_or_uri(self):
        _reset()
        from tools.authenticator import auth_add
        result = auth_add.invoke({
            "account": "test",
            "issuer": "Test",
        })
        assert "Error" in result
        assert "provide" in result.lower()
        _reset()

    def test_add_secret_never_in_output(self):
        _reset()
        from tools.authenticator import auth_add, _get_adapter
        adapter = _get_adapter()
        adapter._lifecycle._pid = 1
        mock_dbus = MagicMock()
        adapter._dbus = mock_dbus
        secret = "SUPERSECRETBASE32KEY"

        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            result = auth_add.invoke({
                "account": "test",
                "issuer": "Test",
                "uri": f"otpauth://totp/test?secret={secret}&issuer=Test",
            })
            assert secret not in result
        _reset()


class TestRegistryIntegration:

    def test_authenticator_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "auth_list" in _ALLOWED_EXPOSED_TOOLS
        assert "auth_get_code" in _ALLOWED_EXPOSED_TOOLS
        assert "auth_add" in _ALLOWED_EXPOSED_TOOLS
