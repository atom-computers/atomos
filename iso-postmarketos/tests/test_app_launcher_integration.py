#!/usr/bin/env python3
"""Integration contracts for the chat-ui app launcher hang regression.

Mirrors ``core/tests/app_launcher_integration.rs`` so CI can run the same
pinning via ``python3 -m unittest tests.test_app_launcher_integration`` on
any host without cargo.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ISO_ROOT = Path(__file__).resolve().parents[1]
UI_RS = (
    ISO_ROOT
    / "rust"
    / "atomos-overview-chat-ui"
    / "app-gtk"
    / "src"
    / "ui.rs"
).read_text(encoding="utf-8")
APP_GRID_RS = (
    ISO_ROOT
    / "rust"
    / "atomos-overview-chat-ui"
    / "app-gtk"
    / "src"
    / "app_grid.rs"
).read_text(encoding="utf-8")
STYLE_RS = (
    ISO_ROOT
    / "rust"
    / "atomos-overview-chat-ui"
    / "app-gtk"
    / "src"
    / "style.rs"
).read_text(encoding="utf-8")
INSTALL_SCRIPT = (
    ISO_ROOT / "scripts" / "overview-chat-ui" / "install-overview-chat-ui.sh"
).read_text(encoding="utf-8")
LAUNCH_EXEC_RS = (
    ISO_ROOT
    / "rust"
    / "atomos-app-handler"
    / "app-gtk"
    / "src"
    / "linux"
    / "launch_exec.rs"
).read_text(encoding="utf-8")


def click_handler_body() -> str:
    marker = "app_grid_btn.connect_clicked"
    start = UI_RS.index(marker)
    return UI_RS[start:]


def schedule_app_grid_build_body() -> str:
    marker = "fn schedule_app_grid_build"
    start = UI_RS.index(marker)
    return UI_RS[start:]


def connect_dock_toggle_body() -> str:
    marker = "fn connect_dock_toggle"
    start = UI_RS.index(marker)
    return UI_RS[start:]


def eager_app_grid_block() -> str:
    marker = "if eager_app_grid_enabled()"
    start = UI_RS.index(marker)
    return UI_RS[start : start + 600]


class TestAppLauncherIntegration(unittest.TestCase):
    def test_click_handler_defers_grid_build_to_idle(self) -> None:
        body = click_handler_body()
        self.assertIn("schedule_app_grid_build", body)
        self.assertNotIn("let app_sheet = build_app_grid_sheet()", body)

    def test_schedule_uses_idle_add_local_once(self) -> None:
        body = schedule_app_grid_build_body()
        self.assertIn("glib::idle_add_local_once", body)
        self.assertIn("build_app_grid_sheet(", body)

    def test_schedule_shows_loading_placeholder(self) -> None:
        body = schedule_app_grid_build_body()
        self.assertIn("Loading apps", body)

    def test_eager_repro_also_schedules_idle_build(self) -> None:
        block = eager_app_grid_block()
        self.assertIn("schedule_app_grid_build", block)
        self.assertNotIn("let app_sheet = build_app_grid_sheet()", block)

    def test_dock_toggle_on_button_not_window_capture_gesture(self) -> None:
        body = connect_dock_toggle_body()
        self.assertIn("app_grid_btn.connect_clicked", body)
        self.assertNotIn("dock_hit_tap", body)
        self.assertNotIn("PropagationPhase::Capture", body)
        self.assertNotIn("win.add_controller(dock_hit_tap)", UI_RS)

    def test_visible_apps_sort_by_id_only(self) -> None:
        self.assertIn("app.id()", APP_GRID_RS)
        self.assertIn("sort_by_key", APP_GRID_RS)
        self.assertNotIn("sort_by_key(|app| app_label", APP_GRID_RS)
        self.assertIn("normalized_id_label(&id)", APP_GRID_RS)

    def test_app_label_avoids_glib_display_metadata(self) -> None:
        label_fn = APP_GRID_RS.split("fn app_label", 1)[1].split("\nfn ", 1)[0]
        self.assertNotIn("display_name()", label_fn)
        self.assertNotIn(".name()", label_fn)

    def test_tile_click_spawns_app_handler_subprocess(self) -> None:
        self.assertIn(
            "Command::new(&program).args(&args).spawn()",
            APP_GRID_RS,
        )

    def test_tile_click_uses_decide_launch_invocation(self) -> None:
        self.assertIn("decide_launch_invocation", APP_GRID_RS)

    def test_app_tile_labels_have_explicit_theme_colors(self) -> None:
        decorative = STYLE_RS.split("fn stylesheet", 1)[1].split("#[cfg(test)]", 1)[0]
        self.assertIn(
            "window.atomos-chat-root.atomos-dark label.atomos-app-label", decorative
        )
        self.assertIn("color: #ffffff", decorative)
        self.assertIn(
            "window.atomos-chat-root.atomos-light label.atomos-app-label", decorative
        )
        self.assertIn("color: #121212", decorative)
        self.assertIn("button.atomos-app-tile image", decorative)
        self.assertNotIn("label.atomos-app-label {\n  color: inherit", decorative)

    def test_install_defaults_app_icons_on(self) -> None:
        self.assertIn(
            'ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS:-1}"',
            INSTALL_SCRIPT,
        )

    def test_launch_exec_prefers_enumerated_app_info(self) -> None:
        self.assertIn("find_enumerated_desktop_app_info", LAUNCH_EXEC_RS)
        self.assertIn("app_ids_match", LAUNCH_EXEC_RS)
        body = LAUNCH_EXEC_RS.split("pub fn spawn_desktop_app", 1)[1].split("\nfn ", 1)[0]
        self.assertIn("find_enumerated_desktop_app_info(app_id)", body)

    def test_tile_click_dismisses_sheet_before_launch(self) -> None:
        tile_handler = APP_GRID_RS.split("tile_btn.connect_clicked", 1)[1].split(
            "flow.insert", 1
        )[0]
        self.assertIn("dismiss_for_tile()", tile_handler)
        self.assertIn("dismissing app sheet for launch", UI_RS)
        self.assertLess(
            tile_handler.index("dismiss_for_tile()"),
            tile_handler.index("tile_click_launch("),
        )


if __name__ == "__main__":
    unittest.main()
