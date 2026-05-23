"""L4 + L5 integration: Phosh survives the post-login window.

This is the *primary reproducer* for the AtomOS post-login QEMU segfault
(``virtio_gpu_simple_process_cmd`` → ``iov_to_buf_full`` ↔ Cocoa
``-[QemuCocoaView switchSurface:]``). It runs against the launcher's
upstream defaults — ``-display default`` + ``-device virtio-gpu-pci`` —
so the crash is observed in the same configuration as ``make qemu``.

The host-side display backend is NOT a workaround knob in this layer:
swapping it would mask the bug we're trying to attribute. Instead the
test parameterises over *guest-side* knobs (the AtomOS Phosh patches
and the atomos-app-handler autostart) so that a bisection across runs
can pinpoint which patch reintroduces the regression. See the L4b/L4c
controls below.

L4a (post-login Phosh lifetime, full AtomOS stack — the reproducer)
    Boots the auto-login QEMU image (ATOMOS_AUTOLOGIN=1 / PMOS_AUTOLOGIN=1
    in arm64-virt.env), waits for SSH, then polls ``pgrep -x phosh`` over
    SSH until phosh-session has handed control to the Phosh shell. Holds
    for 60s, re-checking that both the QEMU host pid and the guest phosh
    pid are still alive. Reads /var/log/messages / journalctl over SSH
    for ``virtio_gpu`` / ``phosh.*segfault`` / ``signal 11`` lines.

L4b (control: AtomOS-app-handler autostart disabled)
    Same image, but the test stops the user-level autostart unit on the
    guest before phosh-session starts. If L4a crashes and L4b survives,
    the cause is in atomos-app-handler.

L4c (control: AtomOS Phosh runtime knobs disabled)
    Same image, but the test rewrites ``/etc/atomos/phosh-profile.env``
    to neuter ``ATOMOS_APP_HANDLER_TAKES_OVER`` and
    ``ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG`` before phosh-session
    starts. If L4a crashes and L4c survives, the cause is in the
    runtime branches of the vendored phosh C patches rather than in
    the compile-time changes.

L5 (scanout resize stress)
    Once L4 settles, SSH-triggers a ``wlr-randr`` mode cycle so phoc
    emits fresh SET_SCANOUT commands. The whole stack must survive a
    further 60s. ``wlr-randr`` is optional; if it is not installed in
    the guest, that subtest is skipped.

All tests skip automatically when:
    * sysname != Darwin
    * qemu / sshpass not on PATH
    * the QEMU image has not been built
    * /etc/atomos/autologin-user is absent on the guest (image predates
      the autologin overlay)
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
import unittest


sys.path.insert(0, os.path.dirname(__file__))
from conftest import (  # noqa: E402
    DEFAULT_SSH_PORT,
    QemuProcess,
    require_binary,
    require_darwin,
    require_image,
    ssh,
    wait_for_ssh,
)


PHOSH_BOOT_TIMEOUT_S = float(os.environ.get("ATOMOS_QEMU_TEST_PHOSH_TIMEOUT", "240"))
PHOSH_HOLD_S = float(os.environ.get("ATOMOS_QEMU_TEST_PHOSH_HOLD", "60"))
RESIZE_HOLD_S = float(os.environ.get("ATOMOS_QEMU_TEST_RESIZE_HOLD", "60"))


def _wait_for_phosh(qemu: QemuProcess, timeout: float) -> str:
    """Poll guest pgrep until Phosh is running, return its pid string."""
    deadline = time.monotonic() + timeout
    last: str = ""
    while time.monotonic() < deadline:
        if not qemu.is_alive():
            raise AssertionError(
                f"QEMU exited while waiting for Phosh; log={qemu.log_path}"
            )
        try:
            result = ssh("pgrep -x phosh", timeout=10, check=False)
        except subprocess.TimeoutExpired as exc:
            last = f"timeout: {exc}"
            time.sleep(3)
            continue
        if result.returncode == 0:
            pid = result.stdout.strip().splitlines()[0] if result.stdout.strip() else ""
            if pid:
                return pid
        last = f"rc={result.returncode} stdout={result.stdout!r} stderr={result.stderr!r}"
        time.sleep(3)
    raise AssertionError(
        f"Phosh did not start within {timeout:.0f}s post-boot (last: {last})"
    )


def _check_autologin_image() -> None:
    result = ssh(
        "test -f /etc/atomos/autologin-user && cat /etc/atomos/autologin-user",
        check=False,
    )
    if result.returncode != 0:
        raise unittest.SkipTest(
            "Image has no /etc/atomos/autologin-user marker; rebuild with "
            "PMOS_AUTOLOGIN=1 (set in iso-postmarketos/config/arm64-virt.env)."
        )


def _grep_journal_for_segfault() -> None:
    """Pull /var/log/messages and rg for crash markers. Best-effort."""
    needles = "virtio_gpu|phosh.*segfault|gpu.*reset|signal 11"
    cmd = (
        "if [ -r /var/log/messages ]; then "
        f"  grep -E '{needles}' /var/log/messages | tail -30 || true; "
        "elif command -v journalctl >/dev/null 2>&1; then "
        f"  journalctl --no-pager -b -p err 2>/dev/null | grep -E '{needles}' | tail -30 || true; "
        "else "
        "  echo 'no /var/log/messages or journalctl available' >&2; "
        "fi"
    )
    result = ssh(cmd, check=False, timeout=15)
    if result.stdout.strip():
        raise AssertionError(
            "Guest log shows GPU / phosh crash markers:\n" + result.stdout
        )


class _PhoshLifetimeBase(unittest.TestCase):
    """Spin up a QEMU + autologin guest. Subclasses tweak the guest profile."""

    PROFILE_ENV_REWRITES: dict[str, str] = {}
    DISABLE_APP_HANDLER_AUTOSTART: bool = False

    def setUp(self) -> None:
        require_darwin()
        require_binary("qemu-system-aarch64")
        require_binary("sshpass")
        require_image()
        ssh_port = int(os.environ.get("ATOMOS_QEMU_TEST_SSH_PORT", DEFAULT_SSH_PORT))
        # No display override: this layer must reproduce the crash on the
        # launcher's default backend.
        self._qemu = QemuProcess(ssh_port=ssh_port)
        self._qemu.__enter__()
        self.addCleanup(self._qemu.__exit__, None, None, None)
        wait_for_ssh(port=ssh_port, timeout=180.0, qemu=self._qemu)
        _check_autologin_image()
        self._apply_guest_overrides()

    def _apply_guest_overrides(self) -> None:
        """Apply per-subclass guest tweaks BEFORE phosh-session restarts.

        The autologin image starts greetd → user session → phosh-session
        early. Tests that need to neutralise a specific AtomOS knob do so
        by editing /etc/atomos/phosh-profile.env and restarting the user
        session, so phosh re-execs with the modified env.
        """
        if not self.PROFILE_ENV_REWRITES and not self.DISABLE_APP_HANDLER_AUTOSTART:
            return

        if self.PROFILE_ENV_REWRITES:
            lines = "\n".join(
                f"{k}={v}" for k, v in self.PROFILE_ENV_REWRITES.items()
            )
            cmd = (
                "doas -n sh -eu <<'EOF'\n"
                "install -d /etc/atomos\n"
                "cat > /etc/atomos/phosh-profile.env <<'ENVEOF'\n"
                f"{lines}\n"
                "ENVEOF\n"
                "chmod 0644 /etc/atomos/phosh-profile.env\n"
                "EOF\n"
            )
            ssh(cmd, check=False, timeout=20)

        if self.DISABLE_APP_HANDLER_AUTOSTART:
            ssh(
                "doas -n rm -f /etc/xdg/autostart/atomos-app-handler.desktop "
                "|| true",
                check=False,
                timeout=10,
            )

        # Re-launch phosh-session with the new env. greetd's initial_session
        # auto-restarts the user session when the previous one exits.
        ssh(
            "doas -n pkill -f phosh-session || true; "
            "doas -n systemctl restart greetd.service || true",
            check=False,
            timeout=15,
        )
        # Give greetd a moment to spin a fresh session.
        time.sleep(5)


class TestL4aPhoshLifetimeFullStack(_PhoshLifetimeBase):
    """L4a (reproducer): full AtomOS stack, default QEMU backend."""

    def test_phosh_alive_for_full_hold_window(self) -> None:
        phosh_pid = _wait_for_phosh(self._qemu, PHOSH_BOOT_TIMEOUT_S)
        deadline = time.monotonic() + PHOSH_HOLD_S
        while time.monotonic() < deadline:
            self.assertTrue(
                self._qemu.is_alive(),
                msg=f"QEMU exited mid-hold; log={self._qemu.log_path}",
            )
            result = ssh(f"kill -0 {phosh_pid}", check=False, timeout=10)
            self.assertEqual(
                result.returncode,
                0,
                msg=(
                    f"phosh pid {phosh_pid} died mid-hold "
                    f"({PHOSH_HOLD_S - (deadline - time.monotonic()):.0f}s in)"
                ),
            )
            time.sleep(3)
        _grep_journal_for_segfault()
        self._qemu.terminate()
        self._qemu.assert_no_crash_report()


class TestL4bAppHandlerAutostartDisabled(_PhoshLifetimeBase):
    """L4b control: same image, no atomos-app-handler autostart.

    If L4a fails and this passes, the regression is in atomos-app-handler
    (the layer-shell surface, the IPC, or its lifetime against phoc).
    """

    DISABLE_APP_HANDLER_AUTOSTART = True

    def test_phosh_alive_without_app_handler_autostart(self) -> None:
        phosh_pid = _wait_for_phosh(self._qemu, PHOSH_BOOT_TIMEOUT_S)
        deadline = time.monotonic() + PHOSH_HOLD_S
        while time.monotonic() < deadline:
            self.assertTrue(self._qemu.is_alive(), msg="QEMU exited mid-hold")
            result = ssh(f"kill -0 {phosh_pid}", check=False, timeout=10)
            self.assertEqual(result.returncode, 0, msg="phosh died mid-hold")
            time.sleep(3)
        _grep_journal_for_segfault()
        self._qemu.terminate()
        self._qemu.assert_no_crash_report()


class TestL4cPhoshRuntimeKnobsDisabled(_PhoshLifetimeBase):
    """L4c control: AtomOS Phosh runtime branches neutered.

    Strips the runtime knobs that gate atomos_phosh_sync_app_handler_lifecycle,
    bottom-edge-drag claim, and app-handler takeover. The C patches still
    ship in the binary, but the runtime branches that talk to phoc / spawn
    handlers stay off.

    If L4a fails and this passes, the regression is in the *runtime*
    branches of the Phosh patches. If L4a and L4c both fail, the
    regression is in the always-on changes (compile-time deletions like
    on_num_toplevels_changed stubs, overview force-hide-on-init, the
    usable-area arithmetic).
    """

    PROFILE_ENV_REWRITES = {
        "ATOMOS_UI_PROFILE": "phosh",
        "ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG": "0",
        "ATOMOS_APP_HANDLER_TAKES_OVER": "0",
        "ATOMOS_APP_HANDLER_ENABLE_RUNTIME": "0",
    }

    def test_phosh_alive_with_runtime_knobs_off(self) -> None:
        phosh_pid = _wait_for_phosh(self._qemu, PHOSH_BOOT_TIMEOUT_S)
        deadline = time.monotonic() + PHOSH_HOLD_S
        while time.monotonic() < deadline:
            self.assertTrue(self._qemu.is_alive(), msg="QEMU exited mid-hold")
            result = ssh(f"kill -0 {phosh_pid}", check=False, timeout=10)
            self.assertEqual(result.returncode, 0, msg="phosh died mid-hold")
            time.sleep(3)
        _grep_journal_for_segfault()
        self._qemu.terminate()
        self._qemu.assert_no_crash_report()


class TestL5PhoshScanoutResizeStress(_PhoshLifetimeBase):
    """L5: scanout resize triggers the SET_SCANOUT path repeatedly."""

    def test_wlr_randr_toggle_holds_for_60s(self) -> None:
        phosh_pid = _wait_for_phosh(self._qemu, PHOSH_BOOT_TIMEOUT_S)

        which = ssh("command -v wlr-randr", check=False, timeout=10)
        if which.returncode != 0:
            self.skipTest("wlr-randr not installed in guest")

        cycle_cmd = (
            "set +e; "
            "export WAYLAND_DISPLAY=wayland-0; "
            "export XDG_RUNTIME_DIR=/run/user/$(id -u); "
            "wlr-randr 2>/dev/null | awk '/^[A-Za-z]/{out=$1} /^\\s+[0-9]+x[0-9]+/{print out, $1}' "
            "  | while read out mode; do "
            "      wlr-randr --output \"$out\" --mode \"$mode\" >/dev/null 2>&1 || true; "
            "      sleep 1; "
            "    done; "
            "true"
        )
        ssh(cycle_cmd, check=False, timeout=60)

        deadline = time.monotonic() + RESIZE_HOLD_S
        while time.monotonic() < deadline:
            self.assertTrue(self._qemu.is_alive(), "QEMU exited after resize")
            result = ssh(f"kill -0 {phosh_pid}", check=False, timeout=10)
            self.assertEqual(result.returncode, 0, "phosh died after resize")
            time.sleep(3)
        _grep_journal_for_segfault()
        self._qemu.terminate()
        self._qemu.assert_no_crash_report()


if __name__ == "__main__":
    unittest.main()
