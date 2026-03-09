"""
LangChain tool for shell command execution on the host.

Provides ``terminal`` — a standalone shell execution tool that
runs commands via subprocess with timeout and output-size guards.
This is an atomos-native implementation for terminal command execution.

Security: this runs commands with the service user's permissions.
The COSMIC applet's agent-mode toggle is the user-facing gate.
"""

import logging
import os
import subprocess
from pathlib import Path
from typing import Optional

from langchain_core.tools import tool

logger = logging.getLogger(__name__)

_DEFAULT_TIMEOUT = 120
_MAX_OUTPUT_BYTES = 100_000


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


@tool("terminal")
def execute_command(
    command: str,
    working_directory: Optional[str] = None,
) -> str:
    """Run a shell command on the host and return its output.

    Use this to install packages, run scripts, manage files, compile code,
    or perform any task that requires a shell.  The command runs with
    ``/bin/bash -c`` so pipes, redirects, and shell builtins work.

    When creating files the user asked for (e.g. notes, markdown documents),
    you MUST use either this tool or the ``create_file`` tool — never just
    describe the file content in your response text.

    Args:
        command: The shell command to execute.
        working_directory: Optional directory to run in.
                           Defaults to the user's home directory.

    Returns:
        Combined stdout/stderr with an exit-code summary line.
    """
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


def get_shell_tools():
    """Return all shell execution tools."""
    return [execute_command]
