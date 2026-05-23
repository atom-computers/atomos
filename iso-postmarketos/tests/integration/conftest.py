"""Shared fixtures + helpers for QEMU integration tests (L2..L5).

The integration suite reproduces the AtomOS post-login QEMU segfault by
running the real launcher (``scripts/qemu/run-local-qemu.sh``) with its
upstream defaults — ``-display default`` + ``-device virtio-gpu-pci`` —
i.e. the exact backend that crashes today on macOS HVF. We do NOT swap
in VNC or ramfb for the assertion: the goal is to attribute the crash
to AtomOS guest deltas (atomos-app-handler / phosh patches) by toggling
those *guest* knobs across runs, not to mask the crash by changing the
host.

Design constraints:

* Tests need a real macOS host (HVF) to reproduce the host-visible
  symptom (``-[QemuCocoaView switchSurface:]`` SIGSEGV). Skipping on
  non-Darwin is the contract.
* Tests must never leak a QEMU process. ``QemuProcess`` always terminates
  and waits, even on failure.
* The crash-report sentinel reads ``~/Library/Logs/DiagnosticReports``
  and diffs against a snapshot taken before launch, so a stale entry
  from a prior run does not poison the assertion.
* SSH uses the same ``sshpass -p $PMOS_INSTALL_PASSWORD`` pattern as the
  app-handler hotfix scripts so behaviour matches what a developer sees.
"""

from __future__ import annotations

import contextlib
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import time
import typing
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
ISO_ROOT = REPO_ROOT / "iso-postmarketos"
RUN_LOCAL_QEMU = ISO_ROOT / "scripts" / "qemu" / "run-local-qemu.sh"
DEFAULT_PROFILE_ENV = ISO_ROOT / "config" / "arm64-virt.env"

DIAGNOSTIC_REPORTS_DIR = pathlib.Path.home() / "Library" / "Logs" / "DiagnosticReports"
CRASH_GLOB = "qemu-system-aarch64*.crash"
IPS_GLOB = "qemu-system-aarch64*.ips"

DEFAULT_SSH_PORT = int(os.environ.get("ATOMOS_DEVICE_SSH_PORT", "2222"))
DEFAULT_SSH_USER = os.environ.get("ATOMOS_DEVICE_SSH_USER", "user")
DEFAULT_SSH_PASSWORD = os.environ.get(
    "ATOMOS_DEVICE_SSHPASS",
    os.environ.get("PMOS_INSTALL_PASSWORD", "147147"),
)


def require_darwin() -> None:
    """Skip the calling test if not on macOS HVF."""
    if os.uname().sysname != "Darwin":
        raise unittest.SkipTest(
            "QEMU integration tests need macOS + HVF to reproduce the host crash"
        )


def require_image(profile_env: pathlib.Path = DEFAULT_PROFILE_ENV) -> pathlib.Path:
    """Skip the test if the QEMU image hasn't been built yet."""
    profile_name = _read_profile_name(profile_env)
    image = ISO_ROOT / "build" / f"host-export-{profile_name}" / f"{profile_name}.img"
    if not image.is_file():
        raise unittest.SkipTest(
            f"QEMU image not built: {image}. Run: make build-qemu"
        )
    return image


def require_binary(name: str) -> None:
    if shutil.which(name) is None:
        raise unittest.SkipTest(f"required binary not on PATH: {name}")


def _read_profile_name(profile_env: pathlib.Path) -> str:
    for line in profile_env.read_text().splitlines():
        line = line.strip()
        if line.startswith("PROFILE_NAME="):
            value = line.split("=", 1)[1].strip()
            return value.strip("\"'")
    raise RuntimeError(f"PROFILE_NAME not found in {profile_env}")


def snapshot_crash_reports() -> set[pathlib.Path]:
    """Take a snapshot of existing QEMU crash report file paths.

    A test failure manifests as new files appearing in this set after
    the QEMU run completes.
    """
    if not DIAGNOSTIC_REPORTS_DIR.is_dir():
        return set()
    snapshot: set[pathlib.Path] = set()
    for pattern in (CRASH_GLOB, IPS_GLOB):
        snapshot.update(DIAGNOSTIC_REPORTS_DIR.glob(pattern))
    return snapshot


def new_crash_reports(before: set[pathlib.Path]) -> list[pathlib.Path]:
    """Return crash/IPS reports created since the snapshot was taken."""
    after = snapshot_crash_reports()
    return sorted(after - before, key=lambda p: p.stat().st_mtime)


class QemuProcess:
    """Context manager spawning QEMU via scripts/qemu/run-local-qemu.sh.

    Usage::

        with QemuProcess(display="vnc") as qemu:
            qemu.wait_alive(seconds=30)
            qemu.assert_no_crash_report()
    """

    def __init__(
        self,
        *,
        profile_env: pathlib.Path = DEFAULT_PROFILE_ENV,
        display: str | None = None,
        ssh_port: int = DEFAULT_SSH_PORT,
        vnc_port: int = 5900,
        extra_env: typing.Mapping[str, str] | None = None,
    ) -> None:
        self.profile_env = profile_env
        self.display = display
        self.ssh_port = ssh_port
        self.vnc_port = vnc_port
        self.extra_env = dict(extra_env or {})
        self.proc: subprocess.Popen[bytes] | None = None
        self.crash_snapshot: set[pathlib.Path] = set()
        self._log_path: pathlib.Path | None = None
        self._log_handle: typing.IO[bytes] | None = None

    def __enter__(self) -> "QemuProcess":
        require_darwin()
        require_binary("qemu-system-aarch64")
        require_image(self.profile_env)

        if _tcp_open("127.0.0.1", self.ssh_port):
            raise unittest.SkipTest(
                f"127.0.0.1:{self.ssh_port} is already bound (another QEMU?); "
                f"set ATOMOS_QEMU_TEST_SSH_PORT=<free port> to run the suite."
            )

        self.crash_snapshot = snapshot_crash_reports()

        env = os.environ.copy()
        # Drop any stale display knobs from the dev's shell so the test
        # observes pristine launcher defaults unless it set them explicitly.
        for stale in ("ATOMOS_QEMU_DISPLAY", "ATOMOS_QEMU_HEADLESS"):
            env.pop(stale, None)
        if self.display is not None:
            env["ATOMOS_QEMU_DISPLAY"] = self.display
        env["ATOMOS_QEMU_SSH_FWD_PORT"] = str(self.ssh_port)
        env["ATOMOS_QEMU_VNC_PORT"] = str(self.vnc_port)
        env.update(self.extra_env)

        log_dir = ISO_ROOT / "build" / "qemu-integration-logs"
        log_dir.mkdir(parents=True, exist_ok=True)
        self._log_path = log_dir / f"qemu-{int(time.time())}.log"
        self._log_handle = self._log_path.open("wb")

        self.proc = subprocess.Popen(
            ["bash", str(RUN_LOCAL_QEMU), str(self.profile_env)],
            stdout=self._log_handle,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            env=env,
            cwd=str(REPO_ROOT),
            start_new_session=True,
        )
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.terminate()

    def terminate(self) -> None:
        proc = self.proc
        if proc is not None:
            if proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    pass
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError, PermissionError):
                        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    proc.wait(timeout=5)
            self.proc = None
        if getattr(self, "_log_handle", None) is not None:
            with contextlib.suppress(Exception):
                self._log_handle.close()
            self._log_handle = None

    @property
    def log_path(self) -> pathlib.Path | None:
        return self._log_path

    def is_alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def wait_alive(self, seconds: float, poll_interval: float = 1.0) -> None:
        """Assert the QEMU pid stays alive for ``seconds``."""
        assert self.proc is not None
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            rc = self.proc.poll()
            if rc is not None:
                raise AssertionError(
                    f"QEMU exited early after "
                    f"~{seconds - (deadline - time.monotonic()):.1f}s with rc={rc}; "
                    f"log={self._log_path}"
                )
            time.sleep(poll_interval)

    def assert_no_crash_report(self, *, settle_seconds: float = 3.0) -> None:
        """Assert macOS has not written a new QEMU crash report.

        Reports are written asynchronously; we wait briefly so a crash that
        happened just before ``terminate()`` has time to land on disk.
        """
        time.sleep(settle_seconds)
        new = new_crash_reports(self.crash_snapshot)
        if not new:
            return
        details = "\n".join(f"  {p}" for p in new)
        raise AssertionError(
            "macOS wrote new QEMU crash report(s) during the test:\n"
            + details
            + f"\nQEMU log: {self._log_path}"
        )


def ssh_argv(
    *,
    port: int = DEFAULT_SSH_PORT,
    user: str = DEFAULT_SSH_USER,
    password: str = DEFAULT_SSH_PASSWORD,
    timeout: int = 5,
) -> list[str]:
    """Build the SSH argv used by every integration test.

    Mirrors the app-handler hotfix scripts so the same credentials and
    options apply across the suite.
    """
    require_binary("sshpass")
    return [
        "sshpass",
        "-p",
        password,
        "ssh",
        "-p",
        str(port),
        "-o",
        f"ConnectTimeout={timeout}",
        "-o",
        "PreferredAuthentications=password",
        "-o",
        "PubkeyAuthentication=no",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "LogLevel=ERROR",
        f"{user}@127.0.0.1",
    ]


def ssh(
    command: str,
    *,
    port: int = DEFAULT_SSH_PORT,
    user: str = DEFAULT_SSH_USER,
    password: str = DEFAULT_SSH_PASSWORD,
    timeout: int = 30,
    check: bool = True,
) -> subprocess.CompletedProcess:
    """Run a shell command on the guest over SSH."""
    argv = ssh_argv(port=port, user=user, password=password) + [command]
    return subprocess.run(
        argv,
        capture_output=True,
        text=True,
        check=check,
        timeout=timeout,
    )


def wait_for_ssh(
    *,
    port: int = DEFAULT_SSH_PORT,
    user: str = DEFAULT_SSH_USER,
    password: str = DEFAULT_SSH_PASSWORD,
    timeout: float = 120.0,
    qemu: QemuProcess | None = None,
) -> None:
    """Poll until SSH responds or ``timeout`` elapses.

    If ``qemu`` is provided, bail out fast when its pid exits.
    """
    require_binary("sshpass")
    deadline = time.monotonic() + timeout
    last_err: str = ""
    while time.monotonic() < deadline:
        if qemu is not None and not qemu.is_alive():
            raise AssertionError(
                f"QEMU exited before SSH came up; log={qemu.log_path}"
            )
        if not _tcp_open("127.0.0.1", port):
            time.sleep(2)
            continue
        try:
            result = ssh(
                "true",
                port=port,
                user=user,
                password=password,
                timeout=10,
                check=False,
            )
            if result.returncode == 0:
                return
            last_err = result.stderr.strip() or result.stdout.strip()
        except subprocess.TimeoutExpired as exc:
            last_err = f"timeout: {exc}"
        time.sleep(2)
    raise AssertionError(
        f"SSH did not respond within {timeout:.0f}s on 127.0.0.1:{port} "
        f"(last error: {last_err!r})"
    )


def _tcp_open(host: str, port: int, *, timeout: float = 1.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False
