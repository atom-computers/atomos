"""
LangChain tool for shell command execution via tmux + COSMIC Terminal.

Commands run inside a persistent tmux session (``atomos-agent``) using
a shared socket at ``/tmp/atomos-agent.sock``.  All tmux commands are
executed as the desktop user (via ``sudo -u``) so the tmux server and
socket are owned by that user — this allows COSMIC Terminal (also
running as the desktop user) to attach without uid-mismatch errors.

The agent captures stdout/stderr from a log file written by a
``script(1)`` wrapper inside the tmux pane.
"""

import logging
import os
import re
import shutil
import subprocess
import uuid
from pathlib import Path
from typing import Optional

from langchain_core.tools import tool

logger = logging.getLogger(__name__)

_DEFAULT_TIMEOUT = 120
_MAX_OUTPUT_BYTES = 100_000
_SESSION_NAME = "atomos-agent"
_TMUX_SOCKET = "/tmp/atomos-agent.sock"
_TMP_DIR = Path("/tmp/atomos-term")

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]|\x1b\].*?\x07|\r")

_session_ready = False
_desktop_user: Optional[str] = None


def _resolve_home() -> str:
    """Best-effort resolution of the real user's home directory.

    When the agent service runs as root via systemd, $HOME is /root.
    Try $SUDO_USER and /home/* scan (same logic as agent_factory).
    """
    home = Path.home()
    if home != Path("/root"):
        return str(home)
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        candidate = Path("/home") / sudo_user
        if candidate.is_dir():
            return str(candidate)
    try:
        for entry in sorted(Path("/home").iterdir()):
            if entry.is_dir() and not entry.name.startswith("."):
                return str(entry)
    except OSError:
        pass
    return str(home)


def _resolve_user() -> str:
    """Return the desktop user name.  Cached after first call."""
    global _desktop_user
    if _desktop_user is not None:
        return _desktop_user

    if os.getuid() != 0:
        _desktop_user = os.environ.get("USER", "")
        return _desktop_user

    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        _desktop_user = sudo_user
        return _desktop_user

    home = _resolve_home()
    if home.startswith("/home/"):
        _desktop_user = home.split("/")[2]
        return _desktop_user

    _desktop_user = ""
    return _desktop_user


def _tmux(*args: str, **kwargs) -> subprocess.CompletedProcess:
    """Run a tmux command using the shared socket.

    When the agent runs as root, all tmux commands are executed as the
    desktop user via ``sudo -u``.  This ensures the tmux server and
    socket are owned by the desktop user so COSMIC Terminal can attach
    (tmux rejects cross-uid socket connections).
    """
    user = _resolve_user()
    if user and os.getuid() == 0:
        return subprocess.run(
            ["sudo", "-u", user, "tmux", "-S", _TMUX_SOCKET, *args],
            capture_output=True,
            **kwargs,
        )
    return subprocess.run(
        ["tmux", "-S", _TMUX_SOCKET, *args],
        capture_output=True,
        **kwargs,
    )


def _ensure_session() -> bool:
    """Create the tmux session if it doesn't already exist.

    The session and socket are owned by the desktop user so that
    COSMIC Terminal can attach without uid-mismatch errors.
    """
    global _session_ready
    if _session_ready:
        if _tmux("has-session", "-t", _SESSION_NAME).returncode == 0:
            return True
        _session_ready = False

    _TMP_DIR.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(str(_TMP_DIR), 0o1777)
    except OSError:
        pass

    if _tmux("has-session", "-t", _SESSION_NAME).returncode != 0:
        home = _resolve_home()
        _tmux("new-session", "-d", "-s", _SESSION_NAME, "-c", home)
        logger.info("Created tmux session '%s' (socket=%s, user=%s)",
                     _SESSION_NAME, _TMUX_SOCKET, _resolve_user() or "current")

    _session_ready = True
    return True


def _strip_ansi(text: str) -> str:
    """Remove ANSI escape sequences and carriage returns."""
    return _ANSI_RE.sub("", text)


@tool("terminal")
def execute_command(
    command: str,
    working_directory: Optional[str] = None,
) -> str:
    """Run a shell command on the host and return its output.

    Use this to install packages, run scripts, manage files, compile code,
    or perform any task that requires a shell.  The command runs inside
    a tmux session that the user can see in COSMIC Terminal.

    Args:
        command: The shell command to execute.
        working_directory: Optional directory to run in.
                           Defaults to the user's home directory.

    Returns:
        Combined stdout/stderr with an exit-code summary line.
    """
    if not shutil.which("tmux"):
        return _fallback_execute(command, working_directory)

    if not _ensure_session():
        return _fallback_execute(command, working_directory)

    cwd = working_directory or _resolve_home()
    cwd_path = Path(cwd).expanduser().resolve()
    if not cwd_path.is_dir():
        return f"Error: working directory does not exist: {cwd_path}"

    cmd_id = uuid.uuid4().hex[:10]
    out_log = _TMP_DIR / f"out-{cmd_id}.log"
    exit_file = _TMP_DIR / f"exit-{cmd_id}"
    wrapper = _TMP_DIR / f"cmd-{cmd_id}.sh"
    signal_name = f"atomos-done-{cmd_id}"

    wrapper.write_text(
        f"#!/bin/bash\n"
        f"cd {_shell_quote(str(cwd_path))} 2>/dev/null\n"
        f"script -qfec {_shell_quote(command)} {_shell_quote(str(out_log))}\n"
        f"echo $? > {_shell_quote(str(exit_file))}\n"
        f"tmux -S {_shell_quote(_TMUX_SOCKET)} wait-for -S {signal_name}\n"
    )
    wrapper.chmod(0o755)

    try:
        _tmux(
            "send-keys", "-t", _SESSION_NAME,
            f"bash {_shell_quote(str(wrapper))}", "Enter",
            timeout=5,
        )
    except Exception as exc:
        _cleanup(wrapper, out_log, exit_file)
        return f"$ {command}\n[error sending to tmux: {exc}]"

    try:
        _tmux("wait-for", signal_name, timeout=_DEFAULT_TIMEOUT)
    except subprocess.TimeoutExpired:
        _tmux("send-keys", "-t", _SESSION_NAME, "C-c", "")
        _cleanup(wrapper, out_log, exit_file)
        return f"$ {command}\n[timed out after {_DEFAULT_TIMEOUT}s]"
    except Exception as exc:
        _cleanup(wrapper, out_log, exit_file)
        return f"$ {command}\n[error waiting for tmux: {exc}]"

    output = ""
    if out_log.exists():
        try:
            raw = out_log.read_text(errors="replace")
            output = _strip_ansi(raw).strip()
        except Exception:
            pass

    exit_code = 0
    if exit_file.exists():
        try:
            exit_code = int(exit_file.read_text().strip())
        except (ValueError, OSError):
            pass

    if len(output) > _MAX_OUTPUT_BYTES:
        output = output[:_MAX_OUTPUT_BYTES] + "\n... (output truncated)"

    _cleanup(wrapper, out_log, exit_file)

    prompt = f"$ {command}"
    if output:
        return f"{prompt}\n{output}" if exit_code == 0 else f"{prompt}\n{output}\n[exit {exit_code}]"
    return prompt if exit_code == 0 else f"{prompt}\n[exit {exit_code}]"


def _fallback_execute(command: str, working_directory: Optional[str] = None) -> str:
    """Direct subprocess execution when tmux is unavailable."""
    cwd = working_directory or _resolve_home()
    cwd_path = Path(cwd).expanduser().resolve()
    if not cwd_path.is_dir():
        return f"Error: working directory does not exist: {cwd_path}"

    env = os.environ.copy()
    env.setdefault("HOME", _resolve_home())
    env.setdefault("PATH", "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")

    try:
        result = subprocess.run(
            ["/bin/bash", "-c", command],
            capture_output=True,
            text=True,
            timeout=_DEFAULT_TIMEOUT,
            cwd=str(cwd_path),
            env=env,
        )
        output = (result.stdout + result.stderr).strip()
        if len(output) > _MAX_OUTPUT_BYTES:
            output = output[:_MAX_OUTPUT_BYTES] + "\n... (output truncated)"
        code = result.returncode
        prompt = f"$ {command}"
        if output:
            return f"{prompt}\n{output}" if code == 0 else f"{prompt}\n{output}\n[exit {code}]"
        return prompt if code == 0 else f"{prompt}\n[exit {code}]"
    except subprocess.TimeoutExpired:
        return f"$ {command}\n[timed out after {_DEFAULT_TIMEOUT}s]"
    except Exception as exc:
        return f"$ {command}\n[error: {exc}]"


def _shell_quote(s: str) -> str:
    """Shell-safe single-quoting."""
    return "'" + s.replace("'", "'\\''") + "'"


def _cleanup(*paths: Path) -> None:
    for p in paths:
        try:
            p.unlink(missing_ok=True)
        except OSError:
            pass


def get_shell_tools():
    """Return all shell execution tools."""
    return [execute_command]
