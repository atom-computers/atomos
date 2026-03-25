"""
Tests for the tmux-based shell tool (tools/shell.py).

Covers:
  - Fallback to direct subprocess when tmux is unavailable
  - tmux session creation with shared socket
  - Output capture and exit code extraction
  - Timeout handling
  - ANSI escape stripping
  - Nonexistent working directory handling
"""

import os
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest


class TestResolveHome:

    def test_non_root_returns_pathlib_home(self):
        from tools.shell import _resolve_home
        with patch("tools.shell.Path.home", return_value=Path("/home/testuser")):
            assert _resolve_home() == "/home/testuser"

    def test_root_uses_sudo_user(self, tmp_path):
        from tools.shell import _resolve_home
        sudo_home = tmp_path / "sudouser"
        sudo_home.mkdir()
        with (
            patch("tools.shell.Path.home", return_value=Path("/root")),
            patch.dict(os.environ, {"SUDO_USER": "sudouser"}),
            patch("tools.shell.Path.__truediv__", return_value=sudo_home),
        ):
            result = _resolve_home()
            assert result != "/root" or os.environ.get("SUDO_USER") is None


class TestStripAnsi:

    def test_strips_colour_codes(self):
        from tools.shell import _strip_ansi
        assert _strip_ansi("\x1b[32mgreen\x1b[0m") == "green"

    def test_strips_carriage_returns(self):
        from tools.shell import _strip_ansi
        assert _strip_ansi("hello\rworld") == "helloworld"

    def test_preserves_plain_text(self):
        from tools.shell import _strip_ansi
        assert _strip_ansi("hello world") == "hello world"

    def test_strips_osc_sequences(self):
        from tools.shell import _strip_ansi
        assert _strip_ansi("\x1b]0;title\x07text") == "text"


class TestFallbackExecute:

    def test_simple_command(self):
        from tools.shell import _fallback_execute
        result = _fallback_execute("echo hello")
        assert "$ echo hello" in result
        assert "hello" in result

    def test_nonzero_exit(self):
        from tools.shell import _fallback_execute
        result = _fallback_execute("exit 42")
        assert "[exit 42]" in result

    def test_nonexistent_directory(self):
        from tools.shell import _fallback_execute
        result = _fallback_execute("ls", "/nonexistent/path/abc123")
        assert "Error" in result

    def test_timeout(self):
        from tools.shell import _fallback_execute
        with patch("tools.shell._DEFAULT_TIMEOUT", 1):
            result = _fallback_execute("sleep 30")
            assert "timed out" in result

    def test_output_truncation(self):
        from tools.shell import _fallback_execute
        with patch("tools.shell._MAX_OUTPUT_BYTES", 50):
            result = _fallback_execute("python3 -c 'print(\"x\" * 200)'")
            assert "truncated" in result


class TestTmuxHelper:

    def test_tmux_uses_shared_socket(self):
        from tools.shell import _tmux, _TMUX_SOCKET
        with (
            patch("tools.shell.subprocess.run") as mock_run,
            patch("tools.shell.os.getuid", return_value=1000),
        ):
            mock_run.return_value = MagicMock(returncode=0)
            _tmux("has-session", "-t", "test")
            args = mock_run.call_args[0][0]
            assert args[0] == "tmux"
            assert args[1] == "-S"
            assert args[2] == _TMUX_SOCKET
            assert "has-session" in args

    def test_tmux_uses_sudo_when_root(self):
        import tools.shell as shell_mod
        shell_mod._desktop_user = "george"
        from tools.shell import _tmux, _TMUX_SOCKET
        with (
            patch("tools.shell.subprocess.run") as mock_run,
            patch("tools.shell.os.getuid", return_value=0),
        ):
            mock_run.return_value = MagicMock(returncode=0)
            _tmux("has-session", "-t", "test")
            args = mock_run.call_args[0][0]
            assert args[0] == "sudo"
            assert args[1] == "-u"
            assert args[2] == "george"
            assert args[3] == "tmux"
            assert args[4] == "-S"
            assert args[5] == _TMUX_SOCKET
        shell_mod._desktop_user = None


class TestEnsureSession:

    def test_creates_session_when_missing(self):
        import tools.shell as shell_mod
        shell_mod._session_ready = False

        with patch("tools.shell.subprocess.run") as mock_run:
            mock_run.side_effect = [
                MagicMock(returncode=1),  # has-session: not found
                MagicMock(returncode=0),  # new-session: created
            ]
            result = shell_mod._ensure_session()
            assert result is True
            assert shell_mod._session_ready is True
            assert mock_run.call_count == 2
            new_session_call = mock_run.call_args_list[1]
            assert "new-session" in new_session_call[0][0]
            assert "-S" in new_session_call[0][0]

    def test_reuses_existing_session(self):
        import tools.shell as shell_mod
        shell_mod._session_ready = True

        with patch("tools.shell.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            result = shell_mod._ensure_session()
            assert result is True
            assert mock_run.call_count == 1
            assert "has-session" in mock_run.call_args[0][0]

    def test_tmp_dir_is_world_writable(self):
        import tools.shell as shell_mod
        shell_mod._session_ready = False

        with (
            patch("tools.shell.subprocess.run") as mock_run,
            patch("tools.shell.os.chmod") as mock_chmod,
        ):
            mock_run.side_effect = [
                MagicMock(returncode=1),
                MagicMock(returncode=0),
            ]
            shell_mod._ensure_session()
            mock_chmod.assert_called_once_with(str(shell_mod._TMP_DIR), 0o1777)


class TestExecuteCommandTmux:
    """Test execute_command when tmux is available."""

    def test_falls_back_without_tmux(self):
        from tools.shell import execute_command
        with (
            patch("tools.shell.shutil.which", return_value=None),
            patch("tools.shell._fallback_execute", return_value="$ echo hi\nhi") as fb,
        ):
            result = execute_command.invoke({"command": "echo hi"})
            fb.assert_called_once()
            assert "echo hi" in result

    def test_nonexistent_working_directory(self):
        from tools.shell import execute_command
        with (
            patch("tools.shell.shutil.which", return_value="/usr/bin/tmux"),
            patch("tools.shell._ensure_session", return_value=True),
        ):
            result = execute_command.invoke({
                "command": "ls",
                "working_directory": "/nonexistent/path/xyz",
            })
            assert "Error" in result

    def test_tmux_send_keys_failure(self, tmp_path):
        import tools.shell as shell_mod
        shell_mod._TMP_DIR = tmp_path

        from tools.shell import execute_command
        with (
            patch("tools.shell.shutil.which", return_value="/usr/bin/tmux"),
            patch("tools.shell._ensure_session", return_value=True),
            patch("tools.shell.subprocess.run", side_effect=Exception("connection refused")),
        ):
            result = execute_command.invoke({"command": "echo test"})
            assert "error sending to tmux" in result

    def test_tmux_timeout(self, tmp_path):
        import tools.shell as shell_mod
        shell_mod._TMP_DIR = tmp_path

        from tools.shell import execute_command

        def mock_run(args, **kwargs):
            if "send-keys" in args:
                return MagicMock(returncode=0)
            if "wait-for" in args:
                raise subprocess.TimeoutExpired(cmd=args, timeout=120)
            return MagicMock(returncode=0)

        with (
            patch("tools.shell.shutil.which", return_value="/usr/bin/tmux"),
            patch("tools.shell._ensure_session", return_value=True),
            patch("tools.shell.subprocess.run", side_effect=mock_run),
        ):
            result = execute_command.invoke({"command": "sleep 999"})
            assert "timed out" in result

    def test_successful_execution(self, tmp_path):
        import tools.shell as shell_mod
        shell_mod._TMP_DIR = tmp_path

        from tools.shell import execute_command

        def mock_run(args, **kwargs):
            if "send-keys" in args:
                for f in tmp_path.glob("cmd-*.sh"):
                    cmd_id = f.stem.replace("cmd-", "")
                    out_log = tmp_path / f"out-{cmd_id}.log"
                    exit_file = tmp_path / f"exit-{cmd_id}"
                    out_log.write_text("file1\nfile2\n")
                    exit_file.write_text("0\n")
                return MagicMock(returncode=0)
            if "wait-for" in args:
                return MagicMock(returncode=0)
            return MagicMock(returncode=0)

        with (
            patch("tools.shell.shutil.which", return_value="/usr/bin/tmux"),
            patch("tools.shell._ensure_session", return_value=True),
            patch("tools.shell.subprocess.run", side_effect=mock_run),
        ):
            result = execute_command.invoke({"command": "ls"})
            assert "$ ls" in result
            assert "file1" in result
            assert "file2" in result
            assert "[exit" not in result


class TestShellQuote:

    def test_simple_string(self):
        from tools.shell import _shell_quote
        assert _shell_quote("hello") == "'hello'"

    def test_string_with_single_quotes(self):
        from tools.shell import _shell_quote
        result = _shell_quote("it's")
        assert "it" in result and "s" in result

    def test_empty_string(self):
        from tools.shell import _shell_quote
        assert _shell_quote("") == "''"


class TestGetShellTools:

    def test_returns_one_tool(self):
        from tools.shell import get_shell_tools
        tools = get_shell_tools()
        assert len(tools) == 1
        assert tools[0].name == "terminal"
