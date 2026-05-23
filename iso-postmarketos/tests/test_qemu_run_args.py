"""L1 args lint for scripts/qemu/run-local-qemu.sh.

The integration test plan reproduces the post-login segfault on the exact
default backend that crashes (cocoa + virtio-gpu-pci on macOS, gtk +
virtio-gpu-pci on Linux). These tests intentionally do NOT enforce a
"safer" display backend default — the launcher must keep faithfully
reproducing the crashing configuration so the bisection harness in
tests/integration/ can attribute the segfault to AtomOS guest deltas
(atomos-app-handler / phosh patches) rather than to a host workaround.

What this layer asserts:

* ``ATOMOS_QEMU_DRY_RUN=1`` prints the argv and exits zero (used by the
  integration suite to introspect the launcher without exec'ing QEMU).
* The default argv keeps ``-device virtio-gpu-pci`` (the device class
  observed in the crash trace) and ``-display default``.
* User overrides (``ATOMOS_QEMU_DISPLAY=...``, ``ATOMOS_QEMU_HEADLESS=1``)
  are honoured verbatim, so a future bisection can switch backends.
"""

from __future__ import annotations

import os
import pathlib
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ISO_ROOT = REPO_ROOT / "iso-postmarketos"
RUN_LOCAL_QEMU = ISO_ROOT / "scripts" / "qemu" / "run-local-qemu.sh"
PROFILE_ENV = ISO_ROOT / "config" / "arm64-virt.env"


def _run(env_overrides: dict[str, str]) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    env["ATOMOS_QEMU_DRY_RUN"] = "1"
    for stale in ("ATOMOS_QEMU_DISPLAY", "ATOMOS_QEMU_HEADLESS"):
        env.pop(stale, None)
    env.update(env_overrides)
    return subprocess.run(
        ["bash", str(RUN_LOCAL_QEMU), str(PROFILE_ENV)],
        capture_output=True,
        text=True,
        env=env,
        cwd=str(REPO_ROOT),
        timeout=30,
    )


class TestQemuRunArgs(unittest.TestCase):
    def _assert_argv_contains_sequence(
        self, argv: list[str], needle: list[str]
    ) -> None:
        for i in range(len(argv) - len(needle) + 1):
            if argv[i : i + len(needle)] == needle:
                return
        self.fail(f"argv missing sequence {needle!r}; got {argv!r}")

    def _argv(self, result: subprocess.CompletedProcess) -> list[str]:
        lines = result.stdout.splitlines()
        for i, line in enumerate(lines):
            if line == "qemu-system-aarch64":
                return lines[i:]
        self.fail(f"dry-run stdout never emitted argv:\n{result.stdout}")

    def test_dry_run_exits_zero(self) -> None:
        result = _run({})
        self.assertEqual(
            result.returncode,
            0,
            msg=f"dry-run should succeed; stderr={result.stderr}",
        )
        self.assertIn("qemu-system-aarch64", result.stdout)

    def test_default_keeps_virtio_gpu(self) -> None:
        """Default GPU must remain virtio-gpu-pci so the crash class is
        faithfully reproducible by the integration harness."""
        result = _run({})
        argv = self._argv(result)
        self._assert_argv_contains_sequence(argv, ["-device", "virtio-gpu-pci"])

    def test_default_display_is_default(self) -> None:
        """No silent VNC/ramfb fallback — host display defaults match upstream
        QEMU so we never accidentally mask a guest-side regression."""
        result = _run({})
        argv = self._argv(result)
        self._assert_argv_contains_sequence(argv, ["-display", "default"])
        self.assertNotIn("-vnc", argv)

    def test_display_override_is_honoured(self) -> None:
        """ATOMOS_QEMU_DISPLAY=<x> must pass through verbatim."""
        for mode in ("cocoa", "gtk", "none"):
            with self.subTest(mode=mode):
                result = _run({"ATOMOS_QEMU_DISPLAY": mode})
                argv = self._argv(result)
                self._assert_argv_contains_sequence(argv, ["-display", mode])

    def test_vnc_override_renders_correctly(self) -> None:
        """ATOMOS_QEMU_DISPLAY=vnc maps to -display none -vnc <addr>."""
        result = _run({"ATOMOS_QEMU_DISPLAY": "vnc"})
        argv = self._argv(result)
        self._assert_argv_contains_sequence(argv, ["-display", "none"])
        self.assertIn("-vnc", argv)

    def test_headless_override_renders_nographic(self) -> None:
        result = _run({"ATOMOS_QEMU_HEADLESS": "1"})
        argv = self._argv(result)
        self.assertIn("-nographic", argv)


if __name__ == "__main__":
    unittest.main()
