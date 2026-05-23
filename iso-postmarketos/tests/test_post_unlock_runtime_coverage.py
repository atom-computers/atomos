"""Meta-tests: post-unlock phoc/runtime failures require device smoke, not unit tests."""

from __future__ import annotations

import pathlib
import unittest

ISO_ROOT = pathlib.Path(__file__).resolve().parents[1]
S_APP_HANDLER = ISO_ROOT / "scripts" / "app-handler"

# Patterns the runtime smoke must grep after lockscreen unlock.
PHOC_RUNTIME_JOURNAL_MARKERS = (
    "permission denied",
    "atomos_post_unlock_check_phoc_journal_since",
    "atomos_post_unlock_check_phoc_process_stable",
    "atomos_smoke_wait_for_phosh_session",
    "atomos_session_busctl",
)

# Post-login crash coverage (introduced with tests/integration/
# test_qemu_phosh_login_lifetime.py). The runtime smoke must hold phosh for
# the watch window and grep dmesg / messages for the virtio-gpu / GPU reset
# signatures that brought down QEMU on macOS.
POST_LOGIN_CRASH_MARKERS = (
    "atomos_post_unlock_check_phosh_runtime_hold",
    "atomos_post_unlock_check_gpu_segfault_dmesg",
)


class TestPostUnlockRuntimeCoverage(unittest.TestCase):
    def test_smoke_script_scans_phoc_journal_after_unlock(self):
        text = (S_APP_HANDLER / "smoke-post-unlock.sh").read_text(encoding="utf-8")
        for marker in PHOC_RUNTIME_JOURNAL_MARKERS:
            self.assertIn(
                marker,
                text,
                msg=f"smoke-post-unlock.sh must check phoc runtime ({marker})",
            )

    def test_diagnose_script_scans_phoc_journal(self):
        diagnose = (S_APP_HANDLER / "diagnose-app-handler.sh").read_text(encoding="utf-8")
        runtime_lib = (
            S_APP_HANDLER / "_lib-post-unlock-runtime-checks.remote.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("_lib-post-unlock-runtime-checks.remote.sh", diagnose)
        self.assertIn("atomos_post_unlock_check_phoc_journal_since", diagnose)
        for marker in PHOC_RUNTIME_JOURNAL_MARKERS:
            self.assertIn(marker, runtime_lib)

    def test_remote_runtime_lib_documents_limitation(self):
        text = (
            S_APP_HANDLER / "_lib-post-unlock-runtime-checks.remote.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("static/unit tests cannot", text)
        self.assertIn("journalctl", text)

    def test_smoke_runs_post_login_crash_probes(self):
        """L6 parity: same probes as tests/integration/test_qemu_phosh_login_lifetime.py."""
        smoke = (S_APP_HANDLER / "smoke-post-unlock.sh").read_text(encoding="utf-8")
        runtime_lib = (
            S_APP_HANDLER / "_lib-post-unlock-runtime-checks.remote.sh"
        ).read_text(encoding="utf-8")
        for marker in POST_LOGIN_CRASH_MARKERS:
            self.assertIn(
                marker,
                smoke,
                msg=f"smoke-post-unlock.sh must invoke {marker}",
            )
            self.assertIn(
                marker,
                runtime_lib,
                msg=f"_lib-post-unlock-runtime-checks.remote.sh must define {marker}",
            )

    def test_gpu_segfault_probe_greps_virtio_gpu(self):
        """The dmesg/messages probe must look for the macOS QEMU crash signature."""
        runtime_lib = (
            S_APP_HANDLER / "_lib-post-unlock-runtime-checks.remote.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("virtio_gpu", runtime_lib)
        self.assertIn("phosh.*segfault", runtime_lib)
        self.assertIn("dmesg", runtime_lib)

    def test_home_handler_contract_does_not_claim_phoc_coverage(self):
        text = (
            ISO_ROOT
            / "rust"
            / "atomos-app-handler"
            / "core"
            / "tests"
            / "home_handler_contract.rs"
        ).read_text(encoding="utf-8")
        self.assertIn("Does **not** prove Phosh", text)
        self.assertNotIn("would have caught", text)


if __name__ == "__main__":
    unittest.main()
