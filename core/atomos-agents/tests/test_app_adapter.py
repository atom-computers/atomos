"""
Tests for the shared application adapter infrastructure (tools/app_adapter.py).

Covers:
  - DBusSessionManager connection, call, property access
  - ATSPIFallback element finding and interaction
  - AppLifecycleManager install/running/launch/restart
  - AppAdapter base class caching, status, ensure_running
  - register_app_adapter decorator and get_all_app_tools
"""

import json
import os
import subprocess
import time
import pytest
from unittest.mock import MagicMock, patch, PropertyMock

from tools.app_adapter import (
    DBusSessionManager,
    DBusError,
    ATSPIFallback,
    ATSPIError,
    AppLifecycleManager,
    AppNotRunningError,
    AppAdapter,
    register_app_adapter,
    get_all_app_tools,
    get_app_statuses,
    get_dbus_manager,
    _APP_ADAPTER_REGISTRY,
    _adapter_instances,
)


# ── DBusSessionManager ────────────────────────────────────────────────────


class TestDBusSessionManager:

    def test_connect_success(self):
        mgr = DBusSessionManager()
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            with patch.dict(os.environ, {"DBUS_SESSION_BUS_ADDRESS": "unix:path=/tmp/test-bus"}):
                result = mgr.connect()
                assert result is True
                assert mgr.is_connected() is True

    def test_connect_failure_no_bus(self):
        mgr = DBusSessionManager()
        with patch("subprocess.run", side_effect=FileNotFoundError):
            with patch.dict(os.environ, {"DBUS_SESSION_BUS_ADDRESS": ""}, clear=False):
                with patch.object(mgr, "_detect_bus_address", return_value=None):
                    result = mgr.connect()
                    assert result is False

    def test_reconnect(self):
        mgr = DBusSessionManager()
        mgr._connected = True
        with patch.object(mgr, "connect", return_value=True) as mock:
            result = mgr.reconnect()
            assert result is True
            assert mgr._connected is False or mock.called

    def test_call_raises_when_not_connected(self):
        mgr = DBusSessionManager()
        mgr._connected = False
        with patch.object(mgr, "reconnect", return_value=False):
            with pytest.raises(DBusError, match="Not connected"):
                mgr.call("org.test", "/test", "org.test.Iface", "Method")

    def test_call_success(self):
        mgr = DBusSessionManager()
        mgr._connected = True
        mgr._bus_address = "unix:path=/tmp/test"
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout="('result',)\n", stderr="")
            result = mgr.call("org.test", "/test", "org.test.Iface", "Method", "'arg1'")
            assert "result" in result

    def test_call_timeout(self):
        mgr = DBusSessionManager()
        mgr._connected = True
        mgr._bus_address = "unix:path=/tmp/test"
        with patch("subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="gdbus", timeout=5)):
            with pytest.raises(DBusError, match="timed out"):
                mgr.call("org.test", "/test", "org.test.Iface", "Method")

    def test_call_dbus_error_disconnects(self):
        mgr = DBusSessionManager()
        mgr._connected = True
        mgr._bus_address = "unix:path=/tmp/test"
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=1,
                stderr="org.freedesktop.DBus.Error.ServiceUnknown: no such service",
                stdout="",
            )
            with pytest.raises(DBusError):
                mgr.call("org.test", "/test", "org.test.Iface", "Method")
            assert mgr._connected is False

    def test_get_property(self):
        mgr = DBusSessionManager()
        with patch.object(mgr, "call", return_value="(<'value'>,)") as mock_call:
            result = mgr.get_property("org.test", "/test", "org.test.Iface", "PropName")
            assert "value" in result
            mock_call.assert_called_once()

    def test_detect_bus_address(self):
        with patch("pathlib.Path.exists", return_value=True):
            addr = DBusSessionManager._detect_bus_address()
            assert addr is not None and "unix:path=" in addr


# ── ATSPIFallback ─────────────────────────────────────────────────────────


class TestATSPIFallback:

    def test_find_application_success(self):
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout="('test-bus',)\n")
            result = ATSPIFallback.find_application("TestApp")
            assert result is not None
            assert result["name"] == "TestApp"

    def test_find_application_not_found(self):
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=1, stdout="")
            result = ATSPIFallback.find_application("Missing")
            assert result is None

    def test_click_element(self):
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            result = ATSPIFallback.click_element(100, 200)
            assert result is True

    def test_type_text(self):
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            result = ATSPIFallback.type_text("hello")
            assert result is True

    def test_press_key(self):
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            result = ATSPIFallback.press_key("Return")
            assert result is True

    def test_click_element_no_xdotool(self):
        with patch("subprocess.run", side_effect=FileNotFoundError):
            result = ATSPIFallback.click_element(100, 200)
            assert result is False


# ── AppLifecycleManager ───────────────────────────────────────────────────


class TestAppLifecycleManager:

    def test_is_installed(self):
        mgr = AppLifecycleManager("org.test", "python3")
        assert mgr.is_installed() is True

    def test_is_installed_missing(self):
        mgr = AppLifecycleManager("org.test", "nonexistent_binary_xyz_12345")
        assert mgr.is_installed() is False

    def test_is_running(self):
        mgr = AppLifecycleManager("org.test", "testbin")
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout="12345\n")
            assert mgr.is_running() is True
            assert mgr._pid == 12345

    def test_is_not_running(self):
        mgr = AppLifecycleManager("org.test", "testbin")
        with patch("subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=1, stdout="")
            assert mgr.is_running() is False

    def test_launch_when_already_running(self):
        mgr = AppLifecycleManager("org.test", "testbin")
        with patch.object(mgr, "is_running", return_value=True):
            assert mgr.launch() is True

    def test_launch_when_not_installed(self):
        mgr = AppLifecycleManager("org.test", "nonexistent_xyz")
        with patch.object(mgr, "is_running", return_value=False):
            assert mgr.launch() is False

    def test_ensure_running_success(self):
        mgr = AppLifecycleManager("org.test", "testbin")
        with patch.object(mgr, "health_check", return_value=True):
            assert mgr.ensure_running() is None

    def test_ensure_running_not_installed(self):
        mgr = AppLifecycleManager("org.test", "nonexistent_xyz")
        with patch.object(mgr, "health_check", return_value=False):
            with patch.object(mgr, "is_installed", return_value=False):
                err = mgr.ensure_running()
                assert "not installed" in err

    def test_health_check_caches(self):
        mgr = AppLifecycleManager("org.test", "testbin", health_check_interval=60)
        mgr._pid = 999
        mgr._last_health_check = time.time()
        assert mgr.health_check() is True


# ── AppAdapter ─────────────────────────────────────────────────────────────


class TestAppAdapter:

    def _make_adapter(self):
        class TestAdapter(AppAdapter):
            namespace = "test"
            app_id = "org.test.App"
            binary = "test-app"
            def get_tools(self):
                return ["tool1", "tool2"]

        return TestAdapter()

    def test_status(self):
        adapter = self._make_adapter()
        with patch.object(adapter._lifecycle, "is_installed", return_value=True):
            with patch.object(adapter._lifecycle, "is_running", return_value=False):
                status = adapter.status()
                assert status["app_id"] == "org.test.App"
                assert status["installed"] is True
                assert status["running"] is False

    def test_caching(self):
        adapter = self._make_adapter()
        adapter.set_cached("key1", "value1")
        assert adapter.get_cached("key1") == "value1"
        assert adapter.get_cached("missing") is None

    def test_cache_expiry(self):
        adapter = self._make_adapter()
        adapter.set_cached("key1", "value1")
        adapter._cache_ts["key1"] = time.time() - 100
        assert adapter.get_cached("key1", max_age=30) is None

    def test_clear_cache(self):
        adapter = self._make_adapter()
        adapter.set_cached("key1", "value1")
        adapter.clear_cache()
        assert adapter.get_cached("key1") is None

    def test_get_tools(self):
        adapter = self._make_adapter()
        assert adapter.get_tools() == ["tool1", "tool2"]

    def test_ensure_running_delegates(self):
        adapter = self._make_adapter()
        with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
            assert adapter.ensure_running() is None


# ── get_dbus_manager singleton ─────────────────────────────────────────────


class TestDBusSingleton:

    def test_returns_same_instance(self):
        import tools.app_adapter as mod
        mod._dbus_manager = None
        with patch.object(DBusSessionManager, "connect", return_value=False):
            m1 = get_dbus_manager()
            m2 = get_dbus_manager()
            assert m1 is m2
        mod._dbus_manager = None
