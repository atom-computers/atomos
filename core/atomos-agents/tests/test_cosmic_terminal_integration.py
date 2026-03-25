"""
Integration tests for COSMIC Terminal + tmux: terminal opens, input is sent,
output is read.

These tests verify that:
  1. The terminal tool runs commands in the shared tmux session.
  2. Output returned by the tool matches what is visible in the tmux pane
     (so COSMIC Terminal, when attached to the same session, would show it).
  3. Optionally: cosmic-term can be driven from a script (see Rust integration
     tests in cosmic-ext-applet-ollama for spawn + send-keys + capture-pane).

Run only when tmux is available and (for full E2E) on a COSMIC desktop:
  ATOMOS_COSMIC_TERMINAL_INTEGRATION=1 pytest tests/test_cosmic_terminal_integration.py -v
"""

import os
import shutil
import subprocess
import pytest

# Socket and session must match shell.py and app.rs
_TMUX_SOCKET = "/tmp/atomos-agent.sock"
_TMUX_SESSION = "atomos-agent"


def _tmux_in_path() -> bool:
    return shutil.which("tmux") is not None


def _tmux_available() -> bool:
    try:
        r = subprocess.run(
            ["tmux", "-S", _TMUX_SOCKET, "has-session", "-t", _TMUX_SESSION],
            capture_output=True,
            timeout=5,
        )
        return r.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return False


def _capture_tmux_pane() -> str:
    """Capture current pane content of the agent tmux session."""
    r = subprocess.run(
        ["tmux", "-S", _TMUX_SOCKET, "capture-pane", "-t", _TMUX_SESSION, "-p"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    return r.stdout if r.returncode == 0 else ""


@pytest.mark.skipif(
    os.environ.get("ATOMOS_COSMIC_TERMINAL_INTEGRATION") != "1",
    reason="Set ATOMOS_COSMIC_TERMINAL_INTEGRATION=1 to run",
)
@pytest.mark.skipif(
    os.getuid() == 0,
    reason="Run as desktop user so tmux session is owned by you",
)
@pytest.mark.skipif(
    not _tmux_in_path(),
    reason="tmux not in PATH",
)
class TestCosmicTerminalIntegration:
    """Integration tests: terminal tool and tmux session agree on input/output."""

    def test_terminal_tool_output_appears_in_tmux_pane(self):
        """Run a command via the terminal tool; verify same output in tmux pane."""
        from tools.shell import execute_command

        marker = "COSMIC_INTEGRATION_MARKER_7"
        result = execute_command.invoke({"command": f"echo {marker}"})

        assert marker in result, f"terminal tool should return command output; got: {result}"

        pane = _capture_tmux_pane()
        assert marker in pane, (
            f"tmux pane should show command output (so COSMIC Terminal would too); "
            f"pane snippet:\n{pane[-2000:] if len(pane) > 2000 else pane}"
        )

    def test_terminal_tool_exit_code_reflected_in_output(self):
        """Exit code is captured and reported by the tool."""
        from tools.shell import execute_command

        result = execute_command.invoke({"command": "exit 42"})
        assert "[exit 42]" in result or "exit 42" in result

    def test_tmux_session_has_clients_after_tool_use(self):
        """After running a command, the session exists and can list clients (optional)."""
        from tools.shell import execute_command

        execute_command.invoke({"command": "echo session_check"})

        r = subprocess.run(
            ["tmux", "-S", _TMUX_SOCKET, "list-clients", "-t", _TMUX_SESSION],
            capture_output=True,
            text=True,
            timeout=5,
        )
        # Session must exist; client count may be 0 if cosmic-term is not open
        r2 = subprocess.run(
            ["tmux", "-S", _TMUX_SOCKET, "has-session", "-t", _TMUX_SESSION],
            capture_output=True,
            timeout=5,
        )
        assert r2.returncode == 0, "tmux session atomos-agent should exist after tool use"
