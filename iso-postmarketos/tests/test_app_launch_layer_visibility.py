#!/usr/bin/env python3
"""Presence / layering contracts for chat-ui tile launches.

Mirrors ``core/tests/app_launch_layer_visibility.rs`` so CI can pin the
Console-hidden / Firefox-masks-it regression without cargo.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ISO_ROOT = Path(__file__).resolve().parents[1]
LINUX_RS = (
    ISO_ROOT / "rust" / "atomos-app-handler" / "app-gtk" / "src" / "linux.rs"
).read_text(encoding="utf-8")
APP_GRID_RS = (
    ISO_ROOT
    / "rust"
    / "atomos-overview-chat-ui"
    / "app-gtk"
    / "src"
    / "app_grid.rs"
).read_text(encoding="utf-8")
UI_RS = (
    ISO_ROOT
    / "rust"
    / "atomos-overview-chat-ui"
    / "app-gtk"
    / "src"
    / "ui.rs"
).read_text(encoding="utf-8")
DIAGNOSE_LAUNCH_SH = (
    ISO_ROOT / "scripts" / "app-handler" / "diagnose-app-launch.sh"
).read_text(encoding="utf-8")
CHAT_UI_LIB_RS = (
    ISO_ROOT / "rust" / "atomos-overview-chat-ui" / "core" / "src" / "lib.rs"
).read_text(encoding="utf-8")
LAUNCH_VISIBILITY_RS = (
    ISO_ROOT / "rust" / "atomos-app-handler" / "core" / "src" / "launch_visibility.rs"
).read_text(encoding="utf-8")

CHAT_UI_LAYER_AFTER_SUCCESSFUL_LAUNCH = "bottom"
CHAT_UI_LAYER_APP_GRID_OPEN = "overlay"
REGRESSION_APP_DBUS_ACTIVATABLE = "org.gnome.Console.desktop"
REGRESSION_APP_EXISTING_TOLEVEL = "firefox-esr.desktop"

LAYER_Z = {"background": 0, "bottom": 1, "top": 2, "overlay": 3}


def foreground_visible(layer: str) -> bool:
    return LAYER_Z[layer] < LAYER_Z["overlay"]


def run_launch_once_body() -> str:
    marker = "fn run_launch_once"
    start = LINUX_RS.index(marker)
    end = LINUX_RS.index("fn promote_overview_chat_ui_to_bottom_layer", start)
    return LINUX_RS[start:end]


def tile_click_body() -> str:
    marker = "tile_btn.connect_clicked"
    start = APP_GRID_RS.index(marker)
    end = APP_GRID_RS.index("flow.insert", start)
    return APP_GRID_RS[start:end]


class TestAppLaunchLayerVisibility(unittest.TestCase):
    def test_overlay_z_index_above_bottom(self) -> None:
        self.assertGreater(LAYER_Z["overlay"], LAYER_Z["bottom"])

    def test_core_policy_overlay_hides_foreground_apps(self) -> None:
        self.assertFalse(foreground_visible("overlay"))
        self.assertTrue(foreground_visible("bottom"))

    def test_launch_visibility_module_documents_regression(self) -> None:
        self.assertIn("org.gnome.Console.desktop", LAUNCH_VISIBILITY_RS)
        self.assertIn("foreground_xdg_toplevel_visible_with_chat_ui_layer", LAUNCH_VISIBILITY_RS)

    def test_chat_ui_default_layer_is_overlay_for_app_grid(self) -> None:
        self.assertIn('DEFAULT_LAYER_NAME: &str = "overlay"', CHAT_UI_LIB_RS)
        self.assertEqual(CHAT_UI_LAYER_APP_GRID_OPEN, "overlay")

    def test_promotion_constant_is_bottom(self) -> None:
        self.assertIn(
            f'CHAT_UI_LAYER_AFTER_SUCCESSFUL_LAUNCH: &str = "{CHAT_UI_LAYER_AFTER_SUCCESSFUL_LAUNCH}"',
            LAUNCH_VISIBILITY_RS,
        )

    def test_run_launch_once_promotes_on_spawn_and_activate(self) -> None:
        body = run_launch_once_body()
        self.assertIn("let finish_launch", body)
        self.assertGreaterEqual(body.count("finish_launch("), 2)
        self.assertIn("promote_overview_chat_ui_to_bottom_layer()", body)

    def test_promotion_uses_core_constant(self) -> None:
        self.assertIn("CHAT_UI_LAYER_AFTER_SUCCESSFUL_LAUNCH", LINUX_RS)
        self.assertIn("launch: promoting overview-chat-ui to bottom layer", LINUX_RS)

    def test_no_per_app_layer_exceptions(self) -> None:
        body = run_launch_once_body()
        for needle in (
            REGRESSION_APP_DBUS_ACTIVATABLE,
            REGRESSION_APP_EXISTING_TOLEVEL,
            "firefox",
            "Console",
        ):
            self.assertNotIn(
                needle,
                body,
                f"run_launch_once must not special-case {needle}",
            )

    def test_tile_click_dismisses_before_launch(self) -> None:
        body = tile_click_body()
        self.assertIn("dismiss_for_tile()", body)
        dismiss_at = body.index("dismiss_for_tile()")
        launch_at = body.index("tile_click_launch(")
        self.assertLess(dismiss_at, launch_at)
        self.assertIn("dismissing app sheet for launch", UI_RS)

    def test_diagnose_warns_on_overlay_after_launch(self) -> None:
        self.assertIn(
            "Chat-ui layer vs foreground app (overlay hides xdg-toplevel)",
            DIAGNOSE_LAUNCH_SH,
        )
        self.assertIn("chat-ui still on overlay after successful launch", DIAGNOSE_LAUNCH_SH)
        self.assertIn("launch: promoting overview-chat-ui to bottom layer", DIAGNOSE_LAUNCH_SH)


if __name__ == "__main__":
    unittest.main()
