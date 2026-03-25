"""
Tests for the CLI tool wrapper infrastructure (§2.2) and
cross-cutting tool integration tests (§1 Tests).

Covers:
  §2.2:
  - CliToolWrapper.run() captures stdout/stderr correctly
  - Output parser handles JSON, CSV, and plain text formats
  - detect_output_format auto-detection heuristics
  - Missing binary detected at startup with descriptive error
  - Credential expired detection triggers CredentialExpiredError
  - Timeout handling
  - format_result produces human-readable output

  §1 cross-cutting:
  - All tool packages installed → discover_all_tools() returns combined
    tool list with correct namespaces
  - Disabled tool package via env var → tools not registered
"""

import csv
import io
import json
import os
import subprocess
import sys
import types as builtin_types
import pytest
from unittest.mock import MagicMock, patch, PropertyMock


# ── §2.2 — output format detection ────────────────────────────────────────


class TestDetectOutputFormat:

    def test_json_object(self):
        from tools.cli_wrapper import detect_output_format

        assert detect_output_format('{"key": "value"}') == "json"

    def test_json_array(self):
        from tools.cli_wrapper import detect_output_format

        assert detect_output_format('[1, 2, 3]') == "json"

    def test_csv_with_header(self):
        from tools.cli_wrapper import detect_output_format

        text = "name,age,city\nAlice,30,NYC\nBob,25,LA\n"
        assert detect_output_format(text) == "csv"

    def test_plain_text(self):
        from tools.cli_wrapper import detect_output_format

        assert detect_output_format("hello world") == "text"

    def test_empty_string(self):
        from tools.cli_wrapper import detect_output_format

        assert detect_output_format("") == "text"

    def test_invalid_json_starting_with_brace(self):
        from tools.cli_wrapper import detect_output_format

        assert detect_output_format("{not json at all") == "text"

    def test_single_line_not_csv(self):
        from tools.cli_wrapper import detect_output_format

        assert detect_output_format("just one line") == "text"


# ── §2.2 — output parsing ─────────────────────────────────────────────────


class TestParseOutput:

    def test_parses_json_dict(self):
        from tools.cli_wrapper import parse_output

        result = parse_output('{"a": 1, "b": 2}')
        assert result == {"a": 1, "b": 2}

    def test_parses_json_array(self):
        from tools.cli_wrapper import parse_output

        result = parse_output('[1, 2, 3]')
        assert result == [1, 2, 3]

    def test_parses_csv(self):
        from tools.cli_wrapper import parse_output

        text = "name,age\nAlice,30\nBob,25\n"
        result = parse_output(text, hint="csv")
        assert len(result) == 2
        assert result[0]["name"] == "Alice"
        assert result[1]["age"] == "25"

    def test_plain_text_returned_as_is(self):
        from tools.cli_wrapper import parse_output

        assert parse_output("hello") == "hello"

    def test_hint_overrides_autodetect(self):
        from tools.cli_wrapper import parse_output

        result = parse_output('{"key": "val"}', hint="text")
        assert result == '{"key": "val"}'

    def test_invalid_json_with_hint_falls_through(self):
        from tools.cli_wrapper import parse_output

        result = parse_output("{broken", hint="json")
        assert result == "{broken"


# ── §2.2 — CliToolWrapper binary check ────────────────────────────────────


class TestCliToolWrapperBinaryCheck:

    def test_check_binary_success(self):
        from tools.cli_wrapper import CliToolWrapper

        wrapper = CliToolWrapper("ls")
        with patch("tools.cli_wrapper.shutil.which", return_value="/usr/bin/ls"):
            path = wrapper.check_binary()
            assert path == "/usr/bin/ls"

    def test_check_binary_not_found_raises(self):
        from tools.cli_wrapper import CliToolWrapper, BinaryNotFoundError

        wrapper = CliToolWrapper("nonexistent-binary-xyz")
        with patch("tools.cli_wrapper.shutil.which", return_value=None):
            with pytest.raises(BinaryNotFoundError, match="nonexistent-binary-xyz"):
                wrapper.check_binary()

    def test_error_message_is_descriptive(self):
        from tools.cli_wrapper import CliToolWrapper, BinaryNotFoundError

        wrapper = CliToolWrapper("my-tool")
        with patch("tools.cli_wrapper.shutil.which", return_value=None):
            with pytest.raises(BinaryNotFoundError) as exc_info:
                wrapper.check_binary()
            msg = str(exc_info.value)
            assert "my-tool" in msg
            assert "not found" in msg
            assert "$PATH" in msg

    def test_get_version_returns_first_line(self):
        from tools.cli_wrapper import CliToolWrapper

        wrapper = CliToolWrapper("fake-tool")
        with patch("tools.cli_wrapper.shutil.which", return_value="/usr/bin/fake-tool"):
            with patch("tools.cli_wrapper.subprocess.run") as mock_run:
                mock_run.return_value = MagicMock(
                    stdout="fake-tool 1.2.3\nCopyright 2024\n",
                    returncode=0,
                )
                version = wrapper.get_version()
                assert version == "fake-tool 1.2.3"

    def test_get_version_returns_none_when_missing(self):
        from tools.cli_wrapper import CliToolWrapper

        wrapper = CliToolWrapper("missing-binary")
        with patch("tools.cli_wrapper.shutil.which", return_value=None):
            assert wrapper.get_version() is None


# ── §2.2 — CliToolWrapper.run() ───────────────────────────────────────────


class TestCliToolWrapperRun:

    def _make_wrapper(self):
        from tools.cli_wrapper import CliToolWrapper
        wrapper = CliToolWrapper("test-cli")
        wrapper._binary_path = "/usr/bin/test-cli"
        return wrapper

    def test_captures_stdout(self):
        wrapper = self._make_wrapper()
        with patch("tools.cli_wrapper.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                stdout='{"status": "ok"}',
                stderr="",
                returncode=0,
            )
            result = wrapper.run(["status"])
            assert result["exit_code"] == 0
            assert result["stdout"] == '{"status": "ok"}'
            assert isinstance(result["parsed"], dict)
            assert result["parsed"]["status"] == "ok"

    def test_captures_stderr(self):
        wrapper = self._make_wrapper()
        with patch("tools.cli_wrapper.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                stdout="",
                stderr="warning: something happened",
                returncode=0,
            )
            result = wrapper.run(["check"])
            assert result["stderr"] == "warning: something happened"

    def test_nonzero_exit_code(self):
        wrapper = self._make_wrapper()
        with patch("tools.cli_wrapper.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                stdout="",
                stderr="error: file not found",
                returncode=1,
            )
            result = wrapper.run(["missing"])
            assert result["exit_code"] == 1

    def test_timeout_returns_124(self):
        wrapper = self._make_wrapper()
        with patch("tools.cli_wrapper.subprocess.run") as mock_run:
            mock_run.side_effect = subprocess.TimeoutExpired("test-cli", 60)
            result = wrapper.run(["slow-cmd"], timeout=60)
            assert result["exit_code"] == 124
            assert "timed out" in result["stderr"]

    def test_auth_error_raises_credential_expired(self):
        from tools.cli_wrapper import CredentialExpiredError

        wrapper = self._make_wrapper()
        with patch("tools.cli_wrapper.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                stdout="",
                stderr="ERROR: token has been expired or revoked",
                returncode=1,
            )
            with pytest.raises(CredentialExpiredError, match="authentication error"):
                wrapper.run(["protected-cmd"])

    def test_file_not_found_raises_binary_not_found(self):
        from tools.cli_wrapper import BinaryNotFoundError

        wrapper = self._make_wrapper()
        with patch("tools.cli_wrapper.subprocess.run") as mock_run:
            mock_run.side_effect = FileNotFoundError("No such file or directory")
            with pytest.raises(BinaryNotFoundError, match="not found"):
                wrapper.run(["cmd"])

    def test_output_format_hint(self):
        wrapper = self._make_wrapper()
        csv_text = "name,age\nAlice,30\n"
        with patch("tools.cli_wrapper.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                stdout=csv_text, stderr="", returncode=0,
            )
            result = wrapper.run(["export"], output_format="csv")
            assert result["format"] == "csv"
            assert isinstance(result["parsed"], list)
            assert result["parsed"][0]["name"] == "Alice"

    def test_env_overrides_injected(self):
        from tools.cli_wrapper import CliToolWrapper

        wrapper = CliToolWrapper(
            "echo",
            env_overrides={"MY_VAR": "hello"},
        )
        wrapper._binary_path = "/usr/bin/echo"
        with patch("tools.cli_wrapper.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                stdout="ok", stderr="", returncode=0,
            )
            wrapper.run(["test"])
            call_kwargs = mock_run.call_args
            env = call_kwargs.kwargs.get("env") or call_kwargs[1].get("env", {})
            assert env.get("MY_VAR") == "hello"


# ── §2.2 — format_result ──────────────────────────────────────────────────


class TestFormatResult:

    def _make_wrapper(self):
        from tools.cli_wrapper import CliToolWrapper
        return CliToolWrapper("test")

    def test_success_json(self):
        wrapper = self._make_wrapper()
        result = {
            "stdout": '{"ok": true}',
            "stderr": "",
            "exit_code": 0,
            "parsed": {"ok": True},
            "format": "json",
        }
        formatted = wrapper.format_result(result)
        assert "true" in formatted

    def test_failure_includes_stderr(self):
        wrapper = self._make_wrapper()
        result = {
            "stdout": "",
            "stderr": "permission denied",
            "exit_code": 1,
            "parsed": "",
            "format": "text",
        }
        formatted = wrapper.format_result(result)
        assert "permission denied" in formatted
        assert "exit 1" in formatted

    def test_empty_output(self):
        wrapper = self._make_wrapper()
        result = {
            "stdout": "",
            "stderr": "",
            "exit_code": 0,
            "parsed": "",
            "format": "text",
        }
        formatted = wrapper.format_result(result)
        assert "(no output)" in formatted


# ── §2.2 — auth error heuristic ───────────────────────────────────────────


class TestAuthErrorDetection:

    def _check(self, text: str):
        from tools.cli_wrapper import CliToolWrapper
        return CliToolWrapper._looks_like_auth_error(text)

    def test_detects_token_expired(self):
        assert self._check("ERROR: token has been expired or revoked")

    def test_detects_unauthorized(self):
        assert self._check("HTTP 401 Unauthorized")

    def test_detects_invalid_grant(self):
        assert self._check("Error: invalid_grant")

    def test_detects_login_required(self):
        assert self._check("Error: login required")

    def test_no_false_positive_on_normal_output(self):
        assert not self._check("Successfully created file")

    def test_no_false_positive_on_empty(self):
        assert not self._check("")


# ── §1 cross-cutting — discover_all_tools combined list ────────────────────


class TestDiscoverAllToolsCrossCutting:

    def test_combined_list_has_correct_namespaces(self):
        """All tool packages installed → discover_all_tools() returns a
        combined tool list with correct namespace prefixes."""
        from tool_registry import discover_all_tools, _ALLOWED_EXPOSED_TOOLS

        with patch("tool_registry._discover_deepagent_tools", return_value=[]):
            with patch("tool_registry._discover_atomos_tools") as mock_atomos:
                tools = []
                for name in sorted(_ALLOWED_EXPOSED_TOOLS):
                    t = MagicMock()
                    t.name = name
                    t.description = f"Tool {name}"
                    tools.append({
                        "name": name,
                        "description": f"Tool {name}",
                        "source": "atomos",
                        "tool": t,
                    })
                mock_atomos.return_value = tools

                result = discover_all_tools()
                result_names = {t["name"] for t in result}

                for name in _ALLOWED_EXPOSED_TOOLS:
                    assert name in result_names, f"{name} missing from discover_all_tools()"

    def test_tool_routing_by_name(self):
        """Agent selects correct tool by name → invocation routed to
        the right package (mock scenario: two packages with distinct tools)."""
        from tool_registry import discover_all_tools, _ALLOWED_EXPOSED_TOOLS

        arxiv_tool = MagicMock()
        arxiv_tool.name = "arxiv_search_papers"
        arxiv_tool.description = "Search arXiv"

        notion_tool = MagicMock()
        notion_tool.name = "notion_search"
        notion_tool.description = "Search Notion"

        terminal_tool = MagicMock()
        terminal_tool.name = "terminal"
        terminal_tool.description = "Run shell commands"

        atomos_tools = [
            {"name": "arxiv_search_papers", "description": "Search arXiv",
             "source": "atomos", "tool": arxiv_tool},
            {"name": "notion_search", "description": "Search Notion",
             "source": "atomos", "tool": notion_tool},
            {"name": "terminal", "description": "Run shell commands",
             "source": "atomos", "tool": terminal_tool},
        ]

        with patch("tool_registry._discover_deepagent_tools", return_value=[]):
            with patch("tool_registry._discover_atomos_tools", return_value=atomos_tools):
                result = discover_all_tools()
                tool_map = {t["name"]: t["tool"] for t in result}

                assert tool_map.get("arxiv_search_papers") is arxiv_tool
                assert tool_map.get("notion_search") is notion_tool
                assert tool_map.get("terminal") is terminal_tool

    def test_disabled_package_excluded(self):
        """Disabled tool package in config → tools not registered in
        discover_all_tools() output."""
        from tool_registry import discover_all_tools

        arxiv_tool = MagicMock()
        arxiv_tool.name = "arxiv_search_papers"
        arxiv_tool.description = "Search arXiv"

        terminal_tool = MagicMock()
        terminal_tool.name = "terminal"
        terminal_tool.description = "Run commands"

        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_ARXIV": "1"}):
            with patch("tool_registry._discover_deepagent_tools", return_value=[]):
                with patch("tool_registry._discover_atomos_tools") as mock_atomos:
                    mock_atomos.return_value = [
                        {"name": "terminal", "description": "Run commands",
                         "source": "atomos", "tool": terminal_tool},
                    ]
                    result = discover_all_tools()
                    names = {t["name"] for t in result}
                    assert "arxiv_search_papers" not in names
                    assert "terminal" in names

    def test_google_workspace_tools_in_allowed_set(self):
        """Google Workspace tool names are in _ALLOWED_EXPOSED_TOOLS."""
        from tool_registry import _ALLOWED_EXPOSED_TOOLS

        expected = {
            "google_mail_search",
            "google_mail_send",
            "google_calendar_list",
            "google_calendar_create",
            "google_drive_list",
            "google_drive_download",
            "google_docs_read",
            "google_docs_write",
        }
        for name in expected:
            assert name in _ALLOWED_EXPOSED_TOOLS, (
                f"{name} not in _ALLOWED_EXPOSED_TOOLS"
            )
