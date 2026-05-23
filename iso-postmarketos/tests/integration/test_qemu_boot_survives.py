"""L2 + L3 integration: QEMU boot survives, then SSH comes up.

L2 (boot survives pre-greetd)
    Spawn QEMU with the launcher's *upstream* defaults (``-display
    default``, ``-device virtio-gpu-pci``). Poll the pid for 30s and
    require it to stay alive *up to greetd*. The known crash today
    happens AFTER greetd login (post phoc scanout + post
    atomos-app-handler autostart), not at boot, so this stage should
    pass even with the buggy guest deltas in place; if it ever fails,
    the regression is in the launcher or the rootfs build, not in the
    AtomOS Phosh/handler patches.

L3 (SSH reachable post-boot)
    Same fixture; poll port 2222 via sshpass until it accepts a
    connection or 180s elapses. Asserts that the guest userspace
    reaches openssh-server. This stage isolates "the image boots and
    networks" from "phosh comes up cleanly", which is the next stage
    (L4) where the segfault is expected to land.

Both tests are SKIPPED automatically unless:
    * sysname == "Darwin"
    * qemu-system-aarch64 is installed (Homebrew)
    * build/host-export-arm64-virt/arm64-virt.img exists
    * sshpass is installed
"""

from __future__ import annotations

import os
import sys
import unittest


sys.path.insert(0, os.path.dirname(__file__))
from conftest import (  # noqa: E402
    DEFAULT_SSH_PORT,
    QemuProcess,
    require_binary,
    require_darwin,
    require_image,
    wait_for_ssh,
)


class TestQemuBootSurvives(unittest.TestCase):
    """L2: QEMU stays alive 30s on the *default* (crash-class) backend."""

    def setUp(self) -> None:
        require_darwin()
        require_binary("qemu-system-aarch64")
        require_image()

    def test_default_backend_boot_survives_30s(self) -> None:
        """Boot should reach greetd before any AtomOS scanout regression
        manifests. If this stage already segfaults, the regression is not
        in the Phosh patches — bisection skips straight to launcher/image."""
        with QemuProcess() as qemu:
            qemu.wait_alive(seconds=30)
            qemu.terminate()
            qemu.assert_no_crash_report()


class TestQemuBootReachesSsh(unittest.TestCase):
    """L3: openssh-server is up within 180s of QEMU start."""

    def setUp(self) -> None:
        require_darwin()
        require_binary("qemu-system-aarch64")
        require_binary("sshpass")
        require_image()

    def test_ssh_responds_within_budget(self) -> None:
        ssh_port = int(os.environ.get("ATOMOS_QEMU_TEST_SSH_PORT", DEFAULT_SSH_PORT))
        with QemuProcess(ssh_port=ssh_port) as qemu:
            wait_for_ssh(port=ssh_port, timeout=180.0, qemu=qemu)
            qemu.terminate()
            qemu.assert_no_crash_report()


if __name__ == "__main__":
    unittest.main()
