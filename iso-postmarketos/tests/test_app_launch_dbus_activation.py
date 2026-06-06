#!/usr/bin/env python3
"""TDD contracts for Firefox (Exec) vs Console (DBusActivatable) launch split.

Mirrors ``core/tests/app_launch_dbus_activation.rs``.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ISO_ROOT = Path(__file__).resolve().parents[1]
LAUNCH_EXEC_RS = (
    ISO_ROOT / "rust" / "atomos-app-handler" / "app-gtk" / "src" / "linux" / "launch_exec.rs"
).read_text(encoding="utf-8")
DESKTOP_LAUNCH_RS = (
    ISO_ROOT / "rust" / "atomos-app-handler" / "core" / "src" / "desktop_launch.rs"
).read_text(encoding="utf-8")
APP_TRACKER_C = (
    ISO_ROOT / "rust" / "phosh" / "phosh" / "src" / "app-tracker.c"
).read_text(encoding="utf-8")

FIXTURE_FIREFOX = """[Desktop Entry]
Exec=/usr/lib/firefox-esr/firefox-esr %u
StartupNotify=true
"""

FIXTURE_CONSOLE = """[Desktop Entry]
Exec=kgx
DBusActivatable=true
"""


def desktop_entry_has_exec(text: str) -> bool:
    return any(line.strip().startswith("Exec=") for line in text.splitlines())


def desktop_entry_is_dbus_activatable(text: str) -> bool:
    return any(line.strip().lower() == "dbusactivatable=true" for line in text.splitlines())


def spawn_desktop_app_body() -> str:
    marker = "pub fn spawn_desktop_app"
    start = LAUNCH_EXEC_RS.index(marker)
    return LAUNCH_EXEC_RS[start:].split("\nfn ", 1)[0]


class TestAppLaunchDBusActivation(unittest.TestCase):
    def test_firefox_fixture_is_exec_not_dbus(self) -> None:
        self.assertTrue(desktop_entry_has_exec(FIXTURE_FIREFOX))
        self.assertFalse(desktop_entry_is_dbus_activatable(FIXTURE_FIREFOX))

    def test_console_fixture_is_dbus_activatable(self) -> None:
        self.assertTrue(desktop_entry_is_dbus_activatable(FIXTURE_CONSOLE))
        self.assertTrue(desktop_entry_has_exec(FIXTURE_CONSOLE))

    def test_core_module_exports_regression_ids(self) -> None:
        self.assertIn("org.gnome.Console.desktop", DESKTOP_LAUNCH_RS)
        self.assertIn("firefox-esr.desktop", DESKTOP_LAUNCH_RS)

    def test_phosh_app_tracker_uses_gdk_launch_context(self) -> None:
        body = APP_TRACKER_C.split("phosh_app_tracker_launch_app_info", 1)[1]
        self.assertIn("gdk_display_get_app_launch_context", body)
        self.assertIn("g_desktop_app_info_launch_uris_as_manager", body)

    def test_spawn_desktop_app_uses_display_launch_context(self) -> None:
        self.assertIn("display_app_launch_context", LAUNCH_EXEC_RS)
        self.assertNotIn("Option::<&gio::AppLaunchContext>::None", LAUNCH_EXEC_RS)
        body = spawn_desktop_app_body()
        self.assertIn("launch_uris_as_manager", body)
        self.assertIn("sync_session_env_to_dbus_activation", body)
        self.assertIn("dbus activatable spawning desktop Exec", body)
        self.assertIn("dbus activatable via launch_uris_as_manager", body)
        self.assertIn("should_spawn_dbus_service_exec_directly", body)

    def test_no_per_app_special_cases(self) -> None:
        body = spawn_desktop_app_body()
        for needle in ("org.gnome.Console.desktop", "firefox-esr.desktop", "firefox-esr"):
            self.assertNotIn(needle, body)


if __name__ == "__main__":
    unittest.main()
