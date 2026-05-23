"""Cross-layer contract: Phosh home.c must match Rust shell lifecycle policy.

Rust ``shell_lifecycle_action_for_home_state`` is not called from Phosh C.
Phosh implements ``atomos_phosh_sync_app_handler_lifecycle`` directly — grep-only
checks and Rust unit tests do not prove they stay aligned.
"""

from __future__ import annotations

import pathlib
import sys
import unittest

_TESTS_DIR = pathlib.Path(__file__).resolve().parent
if str(_TESTS_DIR) not in sys.path:
    sys.path.insert(0, str(_TESTS_DIR))

from phosh_home_c_lifecycle import (
    BUGGY_ATOMOS_PHOSH_SYNC_APP_HANDLER_LIFECYCLE,
    assert_phosh_home_c_shell_lifecycle_contract,
    extract_c_function,
)

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
HOME_C = REPO_ROOT / "iso-postmarketos" / "rust" / "phosh" / "phosh" / "src" / "home.c"
SESSION_RS = (
    REPO_ROOT
    / "iso-postmarketos"
    / "rust"
    / "atomos-app-handler"
    / "core"
    / "src"
    / "session.rs"
)


class TestPhoshHomeCLifecycleContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.home_src = HOME_C.read_text(encoding="utf-8")
        cls.lifecycle_fn = extract_c_function(
            cls.home_src, "atomos_phosh_sync_app_handler_lifecycle"
        )

    def test_parses_lifecycle_function_from_home_c(self) -> None:
        self.assertIn("PHOSH_HOME_STATE_UNFOLDED", self.lifecycle_fn)
        self.assertIn("PHOSH_HOME_STATE_FOLDED", self.lifecycle_fn)

    def test_unfolded_never_spawns_show(self) -> None:
        assert_phosh_home_c_shell_lifecycle_contract(self.lifecycle_fn)

    def test_regression_fixture_proves_test_catches_unlock_show_bug(self) -> None:
        buggy_fn = extract_c_function(
            BUGGY_ATOMOS_PHOSH_SYNC_APP_HANDLER_LIFECYCLE,
            "atomos_phosh_sync_app_handler_lifecycle",
        )
        with self.assertRaises(AssertionError) as ctx:
            assert_phosh_home_c_shell_lifecycle_contract(buggy_fn)
        msg = str(ctx.exception)
        self.assertIn("UNFOLDED", msg)
        self.assertTrue("--show" in msg or "action" in msg)

    def test_session_rs_documents_same_policy(self) -> None:
        session = SESSION_RS.read_text(encoding="utf-8")
        self.assertIn("never `--show` on", session)
        self.assertIn("HideSwitcherOverlay => Some(\"--hide\")", session)
        self.assertIn("Unfolded | PhoshHomeShellState::Transition", session)

    def test_home_c_calls_lifecycle_sync_on_state_change(self) -> None:
        self.assertIn(
            "atomos_phosh_sync_app_handler_lifecycle (self->state);",
            self.home_src,
        )


if __name__ == "__main__":
    unittest.main()
