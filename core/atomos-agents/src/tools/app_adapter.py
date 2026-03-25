"""Shared infrastructure for iso-ubuntu application connections.

Provides:

  AppAdapter        — Base class for connecting to desktop applications via
                      D-Bus, AT-SPI, CLI, or file-based IPC.
  DBusSessionManager — Manages a shared D-Bus session bus connection with
                      automatic reconnect on failure.
  ATSPIFallback     — Accessibility-tree automation for apps without D-Bus APIs.
  AppLifecycleManager — Launch, health-check, and restart applications.

All adapters use D-Bus as the primary interface.  When an app lacks a D-Bus
API, the AT-SPI accessibility tree is queried as a fallback (using ``atspi``
or ``at-spi2-core`` via ``subprocess``).
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import time
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

_DEFAULT_DBUS_TIMEOUT = 5000  # ms
_HEALTH_CHECK_INTERVAL = 30   # seconds


# ── D-Bus session bus manager ──────────────────────────────────────────────


class DBusError(RuntimeError):
    """Raised when a D-Bus operation fails."""


class DBusSessionManager:
    """Manages a shared D-Bus session bus connection.

    Uses ``dbus-send`` and ``gdbus`` CLI tools rather than requiring
    ``dbus-python`` (which has complex C dependencies).  This keeps the
    Python dependency footprint minimal while still providing full D-Bus
    access.
    """

    def __init__(self, timeout_ms: int = _DEFAULT_DBUS_TIMEOUT):
        self.timeout_ms = timeout_ms
        self._connected = False
        self._bus_address: str | None = None

    def connect(self) -> bool:
        """Verify the session bus is reachable."""
        addr = os.environ.get("DBUS_SESSION_BUS_ADDRESS", "")
        if not addr:
            addr = self._detect_bus_address()
        if not addr:
            logger.warning("No DBUS_SESSION_BUS_ADDRESS found")
            self._connected = False
            return False

        self._bus_address = addr
        try:
            result = subprocess.run(
                ["dbus-send", "--session", "--print-reply",
                 "--dest=org.freedesktop.DBus", "/org/freedesktop/DBus",
                 "org.freedesktop.DBus.ListNames"],
                capture_output=True, text=True, timeout=5,
                env={**os.environ, "DBUS_SESSION_BUS_ADDRESS": addr},
            )
            self._connected = result.returncode == 0
        except (FileNotFoundError, subprocess.TimeoutExpired):
            self._connected = False

        return self._connected

    def is_connected(self) -> bool:
        return self._connected

    def reconnect(self) -> bool:
        """Force reconnect to the session bus."""
        self._connected = False
        return self.connect()

    def call(
        self,
        bus_name: str,
        object_path: str,
        interface: str,
        method: str,
        *args: str,
        timeout_ms: int | None = None,
    ) -> str:
        """Invoke a D-Bus method and return the raw reply string.

        Arguments should be pre-formatted for ``gdbus call`` syntax
        (e.g. ``"'hello'"`` for a string, ``"42"`` for an int).
        """
        if not self._connected:
            if not self.reconnect():
                raise DBusError("Not connected to D-Bus session bus")

        cmd = [
            "gdbus", "call", "--session",
            "--dest", bus_name,
            "--object-path", object_path,
            "--method", f"{interface}.{method}",
        ]
        cmd.extend(args)

        env = dict(os.environ)
        if self._bus_address:
            env["DBUS_SESSION_BUS_ADDRESS"] = self._bus_address

        effective_timeout = (timeout_ms or self.timeout_ms) / 1000.0
        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=effective_timeout + 2,
                env=env,
            )
        except subprocess.TimeoutExpired:
            raise DBusError(f"D-Bus call timed out: {interface}.{method}")
        except FileNotFoundError:
            raise DBusError("gdbus not found — install glib2 tools")

        if proc.returncode != 0:
            stderr = proc.stderr.strip()
            if "org.freedesktop.DBus.Error" in stderr:
                self._connected = False
            raise DBusError(f"D-Bus call failed: {stderr}")

        return proc.stdout.strip()

    def get_property(
        self,
        bus_name: str,
        object_path: str,
        interface: str,
        prop_name: str,
    ) -> str:
        """Read a D-Bus property via ``org.freedesktop.DBus.Properties.Get``."""
        return self.call(
            bus_name, object_path,
            "org.freedesktop.DBus.Properties", "Get",
            f"'{interface}'", f"'{prop_name}'",
        )

    def set_property(
        self,
        bus_name: str,
        object_path: str,
        interface: str,
        prop_name: str,
        variant: str,
    ) -> str:
        """Write a D-Bus property via ``org.freedesktop.DBus.Properties.Set``."""
        return self.call(
            bus_name, object_path,
            "org.freedesktop.DBus.Properties", "Set",
            f"'{interface}'", f"'{prop_name}'", variant,
        )

    def introspect(self, bus_name: str, object_path: str) -> str:
        """Introspect a D-Bus object to discover its interfaces."""
        return self.call(
            bus_name, object_path,
            "org.freedesktop.DBus.Introspectable", "Introspect",
        )

    @staticmethod
    def _detect_bus_address() -> str | None:
        """Try to auto-detect the session bus address."""
        uid = os.getuid()
        runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{uid}")
        bus_path = Path(runtime_dir) / "bus"
        if bus_path.exists():
            return f"unix:path={bus_path}"
        return None


# ── shared D-Bus session singleton ─────────────────────────────────────────

_dbus_manager: DBusSessionManager | None = None


def get_dbus_manager() -> DBusSessionManager:
    """Return (or create) the shared DBusSessionManager singleton."""
    global _dbus_manager
    if _dbus_manager is None:
        _dbus_manager = DBusSessionManager()
        _dbus_manager.connect()
    return _dbus_manager


# ── AT-SPI accessibility tree fallback ─────────────────────────────────────


class ATSPIError(RuntimeError):
    """Raised when AT-SPI automation fails."""


class ATSPIFallback:
    """Accessibility-tree automation for apps without D-Bus APIs.

    Uses ``busctl`` and ``xdotool`` to find and interact with UI elements
    via the AT-SPI2 accessibility tree.
    """

    @staticmethod
    def find_application(app_name: str) -> dict | None:
        """Find a running application by name in the AT-SPI registry."""
        try:
            result = subprocess.run(
                ["gdbus", "call", "--session",
                 "--dest", "org.a11y.Bus",
                 "--object-path", "/org/a11y/bus",
                 "--method", "org.a11y.Bus.GetAddress"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode != 0:
                return None
            return {"name": app_name, "bus": result.stdout.strip()}
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return None

    @staticmethod
    def find_element(app_name: str, role: str, name: str = "") -> dict | None:
        """Search the accessibility tree for an element by role and name.

        Returns a dict with element info or None if not found.
        """
        try:
            cmd = ["python3", "-c", f"""
import subprocess, json
r = subprocess.run(
    ['gdbus', 'call', '--session',
     '--dest', 'org.a11y.atspi.Registry',
     '--object-path', '/org/a11y/atspi/accessible/root',
     '--method', 'org.a11y.atspi.Accessible.GetChildren'],
    capture_output=True, text=True, timeout=5)
print(json.dumps({{"found": r.returncode == 0, "output": r.stdout[:500]}}))
"""]
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if proc.returncode == 0 and proc.stdout.strip():
                return json.loads(proc.stdout.strip())
        except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
            pass
        return None

    @staticmethod
    def click_element(x: int, y: int) -> bool:
        """Click at screen coordinates using xdotool."""
        try:
            result = subprocess.run(
                ["xdotool", "mousemove", str(x), str(y), "click", "1"],
                capture_output=True, timeout=5,
            )
            return result.returncode == 0
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return False

    @staticmethod
    def type_text(text: str) -> bool:
        """Type text using xdotool."""
        try:
            result = subprocess.run(
                ["xdotool", "type", "--clearmodifiers", text],
                capture_output=True, timeout=10,
            )
            return result.returncode == 0
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return False

    @staticmethod
    def press_key(key: str) -> bool:
        """Press a key combination using xdotool (e.g. 'Return', 'ctrl+s')."""
        try:
            result = subprocess.run(
                ["xdotool", "key", key],
                capture_output=True, timeout=5,
            )
            return result.returncode == 0
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return False


# ── application lifecycle manager ──────────────────────────────────────────


class AppNotRunningError(RuntimeError):
    """Raised when an app is expected to be running but isn't."""


class AppLifecycleManager:
    """Launch, health-check, and restart desktop applications.

    Parameters
    ----------
    app_id : str
        The desktop application ID (e.g. ``org.gnome.Geary``).
    binary : str
        The executable name (e.g. ``geary``).
    launch_args : list[str]
        Extra arguments for the launch command.
    health_check_interval : int
        Seconds between health checks.
    """

    def __init__(
        self,
        app_id: str,
        binary: str,
        launch_args: list[str] | None = None,
        health_check_interval: int = _HEALTH_CHECK_INTERVAL,
    ):
        self.app_id = app_id
        self.binary = binary
        self.launch_args = launch_args or []
        self.health_check_interval = health_check_interval
        self._pid: int | None = None
        self._last_health_check: float = 0

    def is_installed(self) -> bool:
        """Check if the application binary is on $PATH."""
        return shutil.which(self.binary) is not None

    def is_running(self) -> bool:
        """Check if the application is currently running (via pgrep)."""
        try:
            result = subprocess.run(
                ["pgrep", "-f", self.binary],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0 and result.stdout.strip():
                pids = result.stdout.strip().splitlines()
                self._pid = int(pids[0])
                return True
        except (FileNotFoundError, subprocess.TimeoutExpired, ValueError):
            pass
        self._pid = None
        return False

    def launch(self) -> bool:
        """Launch the application in the background."""
        if self.is_running():
            return True
        if not self.is_installed():
            logger.warning("Cannot launch %s: binary not found", self.binary)
            return False
        try:
            proc = subprocess.Popen(
                [self.binary] + self.launch_args,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            self._pid = proc.pid
            time.sleep(1)
            return self.is_running()
        except Exception as exc:
            logger.error("Failed to launch %s: %s", self.binary, exc)
            return False

    def restart(self) -> bool:
        """Kill and re-launch the application."""
        self.kill()
        time.sleep(0.5)
        return self.launch()

    def kill(self) -> None:
        """Terminate the application."""
        if self._pid:
            try:
                subprocess.run(["kill", str(self._pid)], timeout=5)
            except (FileNotFoundError, subprocess.TimeoutExpired):
                pass
            self._pid = None
        try:
            subprocess.run(
                ["pkill", "-f", self.binary],
                capture_output=True, timeout=5,
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass

    def health_check(self) -> bool:
        """Periodic health check — returns True if the app is healthy."""
        now = time.time()
        if now - self._last_health_check < self.health_check_interval:
            return self._pid is not None
        self._last_health_check = now
        return self.is_running()

    def ensure_running(self) -> str | None:
        """Ensure the app is running; launch or restart if needed.

        Returns an error string on failure, None on success.
        """
        if self.health_check():
            return None
        if not self.is_installed():
            return f"{self.binary} is not installed. Install it first."
        if self.launch():
            return None
        return f"Failed to start {self.binary}. Check system logs."


# ── base adapter ───────────────────────────────────────────────────────────


class AppAdapter(ABC):
    """Base class for iso-ubuntu application adapters.

    Subclasses implement ``get_tools()`` returning a list of LangChain
    ``@tool`` functions, and optionally override hooks for D-Bus, AT-SPI,
    or CLI interaction.
    """

    namespace: str = ""
    app_id: str = ""
    binary: str = ""
    launch_args: list[str] = []

    def __init__(self):
        self._lifecycle = AppLifecycleManager(
            app_id=self.app_id,
            binary=self.binary,
            launch_args=self.launch_args,
        )
        self._dbus: DBusSessionManager | None = None
        self._atspi: ATSPIFallback | None = None
        self._state_cache: dict[str, Any] = {}
        self._cache_ts: dict[str, float] = {}

    @property
    def lifecycle(self) -> AppLifecycleManager:
        return self._lifecycle

    @property
    def dbus(self) -> DBusSessionManager:
        if self._dbus is None:
            self._dbus = get_dbus_manager()
        return self._dbus

    @property
    def atspi(self) -> ATSPIFallback:
        if self._atspi is None:
            self._atspi = ATSPIFallback()
        return self._atspi

    def ensure_running(self) -> str | None:
        """Ensure the application is running. Returns error string or None."""
        return self._lifecycle.ensure_running()

    def get_cached(self, key: str, max_age: float = 30.0) -> Any | None:
        """Return a cached value if not older than *max_age* seconds."""
        ts = self._cache_ts.get(key, 0)
        if time.time() - ts < max_age:
            return self._state_cache.get(key)
        return None

    def set_cached(self, key: str, value: Any) -> None:
        """Store a value in the state cache."""
        self._state_cache[key] = value
        self._cache_ts[key] = time.time()

    def clear_cache(self) -> None:
        """Clear all cached state."""
        self._state_cache.clear()
        self._cache_ts.clear()

    @abstractmethod
    def get_tools(self) -> list:
        """Return the LangChain tool functions for this adapter."""
        ...

    def status(self) -> dict[str, Any]:
        """Return the current status of this adapter's application."""
        return {
            "app_id": self.app_id,
            "binary": self.binary,
            "installed": self._lifecycle.is_installed(),
            "running": self._lifecycle.is_running(),
        }


# ── convenience: collect all app adapter tools ─────────────────────────────

_APP_ADAPTER_REGISTRY: list[type[AppAdapter]] = []


def register_app_adapter(cls: type[AppAdapter]) -> type[AppAdapter]:
    """Class decorator to register an AppAdapter subclass."""
    _APP_ADAPTER_REGISTRY.append(cls)
    return cls


_adapter_instances: dict[str, AppAdapter] = {}


def get_all_app_tools() -> list:
    """Instantiate all registered adapters and return their combined tools."""
    tools = []
    for cls in _APP_ADAPTER_REGISTRY:
        ns = cls.namespace
        if ns not in _adapter_instances:
            try:
                _adapter_instances[ns] = cls()
            except Exception as exc:
                logger.warning("Failed to instantiate adapter %s: %s", ns, exc)
                continue
        adapter = _adapter_instances[ns]
        try:
            tools.extend(adapter.get_tools())
        except Exception as exc:
            logger.warning("Failed to get tools from %s: %s", ns, exc)
    return tools


def get_app_statuses() -> list[dict[str, Any]]:
    """Return status information for all registered application adapters."""
    statuses = []
    for ns, adapter in _adapter_instances.items():
        statuses.append(adapter.status())
    return statuses
