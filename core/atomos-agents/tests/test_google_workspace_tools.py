"""
Tests for the Google Workspace CLI tools (§2.1).

Covers:
  - Tool registration returns 8 tools with correct namespaced names
  - CLI wrapper constructs correct command-line arguments for each operation
  - Output parsing extracts structured data from CLI JSON output
  - Credential refresh triggers re-auth flow
  - Graceful degradation when gcloud is not installed
  - Integration with tool_registry allowed-tools list
"""

import json
import os
import subprocess
import sys
import types as builtin_types
import pytest
from unittest.mock import MagicMock, patch, call


# ── helpers ────────────────────────────────────────────────────────────────


def _patch_gcloud_available():
    """Patch shutil.which to make gcloud appear available."""
    return patch("tools.cli_wrapper.shutil.which", return_value="/usr/bin/gcloud")


def _patch_subprocess_success(stdout: str = "", stderr: str = ""):
    """Patch subprocess.run to return a successful result."""
    mock_result = MagicMock(
        stdout=stdout,
        stderr=stderr,
        returncode=0,
    )
    return patch("tools.cli_wrapper.subprocess.run", return_value=mock_result)


def _patch_subprocess_failure(stderr: str = "error", exit_code: int = 1):
    mock_result = MagicMock(
        stdout="",
        stderr=stderr,
        returncode=exit_code,
    )
    return patch("tools.cli_wrapper.subprocess.run", return_value=mock_result)


def _reset_module_state():
    """Reset the google_workspace module's cached tools list and wrapper."""
    import tools.google_workspace as mod
    mod._GOOGLE_WORKSPACE_TOOLS = None
    mod._wrapper = None


# ── tool registration ─────────────────────────────────────────────────────


class TestGoogleWorkspaceRegistration:

    def test_returns_eight_tools(self):
        with _patch_gcloud_available():
            import tools.google_workspace as mod
            _reset_module_state()
            result = mod.get_google_workspace_tools()
            assert len(result) == 8

    def test_tool_names_are_namespaced(self):
        with _patch_gcloud_available():
            import tools.google_workspace as mod
            _reset_module_state()
            result = mod.get_google_workspace_tools()
            names = {t.name for t in result}
            assert names == {
                "google_mail_search",
                "google_mail_send",
                "google_calendar_list",
                "google_calendar_create",
                "google_drive_list",
                "google_drive_download",
                "google_docs_read",
                "google_docs_write",
            }

    def test_graceful_when_gcloud_missing(self):
        with patch("tools.cli_wrapper.shutil.which", return_value=None):
            import tools.google_workspace as mod
            _reset_module_state()
            result = mod.get_google_workspace_tools()
            assert result == []

    def test_caches_tool_list(self):
        with _patch_gcloud_available():
            import tools.google_workspace as mod
            _reset_module_state()
            first = mod.get_google_workspace_tools()
            second = mod.get_google_workspace_tools()
            assert first is second

    def test_tool_descriptions_present(self):
        with _patch_gcloud_available():
            import tools.google_workspace as mod
            _reset_module_state()
            for tool in mod.get_google_workspace_tools():
                assert tool.description, f"{tool.name} has empty description"


# ── CLI argument construction ──────────────────────────────────────────────


class TestGmailArgumentConstruction:

    def test_mail_search_constructs_args(self):
        with _patch_gcloud_available(), _patch_subprocess_success('[]') as mock_run:
            import tools.google_workspace as mod
            _reset_module_state()
            mod.google_mail_search.invoke({
                "query": "from:alice subject:meeting",
                "max_results": 10,
            })
            cmd = mock_run.call_args[0][0]
            assert "workspace" in cmd
            assert "gmail" in cmd
            assert "messages" in cmd
            assert "--query=from:alice subject:meeting" in cmd
            assert "--max-results=10" in cmd
            assert "--format" in cmd

    def test_mail_send_constructs_args_with_cc(self):
        with _patch_gcloud_available(), _patch_subprocess_success('sent') as mock_run:
            import tools.google_workspace as mod
            _reset_module_state()
            mod.google_mail_send.invoke({
                "to": "bob@example.com",
                "subject": "Hello",
                "body": "Hi Bob!",
                "cc": "carol@example.com",
            })
            cmd = mock_run.call_args[0][0]
            assert "--to=bob@example.com" in cmd
            assert "--subject=Hello" in cmd
            assert "--body=Hi Bob!" in cmd
            assert "--cc=carol@example.com" in cmd

    def test_mail_send_omits_optional_when_none(self):
        with _patch_gcloud_available(), _patch_subprocess_success('sent') as mock_run:
            import tools.google_workspace as mod
            _reset_module_state()
            mod.google_mail_send.invoke({
                "to": "bob@example.com",
                "subject": "Test",
                "body": "Body text",
            })
            cmd = mock_run.call_args[0][0]
            cc_args = [a for a in cmd if a.startswith("--cc")]
            bcc_args = [a for a in cmd if a.startswith("--bcc")]
            assert len(cc_args) == 0
            assert len(bcc_args) == 0


class TestCalendarArgumentConstruction:

    def test_calendar_list_with_time_range(self):
        with _patch_gcloud_available(), _patch_subprocess_success('[]') as mock_run:
            import tools.google_workspace as mod
            _reset_module_state()
            mod.google_calendar_list.invoke({
                "time_min": "2024-03-01T00:00:00Z",
                "time_max": "2024-03-31T23:59:59Z",
            })
            cmd = mock_run.call_args[0][0]
            assert "--time-min=2024-03-01T00:00:00Z" in cmd
            assert "--time-max=2024-03-31T23:59:59Z" in cmd

    def test_calendar_create_constructs_full_args(self):
        with _patch_gcloud_available(), _patch_subprocess_success('{}') as mock_run:
            import tools.google_workspace as mod
            _reset_module_state()
            mod.google_calendar_create.invoke({
                "summary": "Team Standup",
                "start_time": "2024-03-15T10:00:00Z",
                "end_time": "2024-03-15T10:30:00Z",
                "description": "Daily sync",
                "location": "Room A",
                "attendees": "alice@co.com,bob@co.com",
            })
            cmd = mock_run.call_args[0][0]
            assert "--summary=Team Standup" in cmd
            assert "--start-time=2024-03-15T10:00:00Z" in cmd
            assert "--end-time=2024-03-15T10:30:00Z" in cmd
            assert "--description=Daily sync" in cmd
            assert "--location=Room A" in cmd
            assert "--attendees=alice@co.com,bob@co.com" in cmd


class TestDriveArgumentConstruction:

    def test_drive_list_with_query(self):
        with _patch_gcloud_available(), _patch_subprocess_success('[]') as mock_run:
            import tools.google_workspace as mod
            _reset_module_state()
            mod.google_drive_list.invoke({
                "query": "name contains 'report'",
            })
            cmd = mock_run.call_args[0][0]
            assert "--query=name contains 'report'" in cmd

    def test_drive_download_constructs_args(self):
        with _patch_gcloud_available(), _patch_subprocess_success('ok') as mock_run:
            import tools.google_workspace as mod
            _reset_module_state()
            mod.google_drive_download.invoke({
                "file_id": "abc123",
                "destination": "/tmp/report.pdf",
            })
            cmd = mock_run.call_args[0][0]
            assert "--file-id=abc123" in cmd
            assert "--destination=/tmp/report.pdf" in cmd


class TestDocsArgumentConstruction:

    def test_docs_read_constructs_args(self):
        with _patch_gcloud_available(), _patch_subprocess_success('{}') as mock_run:
            import tools.google_workspace as mod
            _reset_module_state()
            mod.google_docs_read.invoke({"document_id": "doc-xyz"})
            cmd = mock_run.call_args[0][0]
            assert "--document-id=doc-xyz" in cmd

    def test_docs_write_constructs_args(self):
        with _patch_gcloud_available(), _patch_subprocess_success('ok') as mock_run:
            import tools.google_workspace as mod
            _reset_module_state()
            mod.google_docs_write.invoke({
                "document_id": "doc-xyz",
                "content": "New paragraph",
                "insert_at": "end",
            })
            cmd = mock_run.call_args[0][0]
            assert "--document-id=doc-xyz" in cmd
            assert "--content=New paragraph" in cmd
            assert "--insert-at=end" in cmd


# ── output parsing ─────────────────────────────────────────────────────────


class TestOutputParsing:

    def test_json_output_parsed_into_dict(self):
        json_out = json.dumps({"messages": [{"id": "1", "subject": "Hi"}]})
        with _patch_gcloud_available(), _patch_subprocess_success(json_out):
            import tools.google_workspace as mod
            _reset_module_state()
            result = mod.google_mail_search.invoke({
                "query": "test",
            })
            parsed = json.loads(result)
            assert parsed["messages"][0]["subject"] == "Hi"

    def test_empty_json_array(self):
        with _patch_gcloud_available(), _patch_subprocess_success("[]"):
            import tools.google_workspace as mod
            _reset_module_state()
            result = mod.google_mail_search.invoke({"query": "nothing"})
            assert result == "[]"

    def test_error_output_includes_stderr(self):
        with _patch_gcloud_available(), \
             _patch_subprocess_failure("ERROR: permission denied"):
            import tools.google_workspace as mod
            _reset_module_state()
            result = mod.google_mail_search.invoke({"query": "secret"})
            assert "permission denied" in result


# ── credential refresh ─────────────────────────────────────────────────────


class TestCredentialRefresh:

    def test_retries_on_auth_failure(self):
        """When the first call fails with a credential error, the wrapper
        retries after attempting a token refresh."""
        import tools.google_workspace as mod
        _reset_module_state()

        call_count = 0

        def side_effect(cmd, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return MagicMock(
                    stdout="",
                    stderr="ERROR: token has been expired or revoked",
                    returncode=1,
                )
            if call_count == 2:
                return MagicMock(
                    stdout="Refreshed credentials",
                    stderr="",
                    returncode=0,
                )
            return MagicMock(
                stdout='{"events": []}',
                stderr="",
                returncode=0,
            )

        with _patch_gcloud_available():
            with patch("tools.cli_wrapper.subprocess.run", side_effect=side_effect):
                result = mod.google_calendar_list.invoke({})
                assert call_count == 3
                assert "events" in result

    def test_gives_up_after_failed_refresh(self):
        """When token refresh itself fails, returns a descriptive error."""
        import tools.google_workspace as mod
        _reset_module_state()

        call_count = 0

        def side_effect(cmd, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return MagicMock(
                    stdout="",
                    stderr="ERROR: token has been expired or revoked",
                    returncode=1,
                )
            # Refresh command fails with a hard error
            raise OSError("Network is unreachable")

        with _patch_gcloud_available():
            with patch("tools.cli_wrapper.subprocess.run", side_effect=side_effect):
                result = mod.google_calendar_list.invoke({})
                assert "refresh failed" in result.lower() or "re-authenticate" in result.lower()


# ── tool_registry integration ──────────────────────────────────────────────


class TestRegistryIntegration:

    def test_all_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS

        expected = [
            "google_mail_search",
            "google_mail_send",
            "google_calendar_list",
            "google_calendar_create",
            "google_drive_list",
            "google_drive_download",
            "google_docs_read",
            "google_docs_write",
        ]
        for name in expected:
            assert name in _ALLOWED_EXPOSED_TOOLS

    def test_tools_in_system_prompt(self):
        """Prompt source includes guidance for dynamic tool-detail expansion."""
        import pathlib

        prompt_file = pathlib.Path(__file__).resolve().parent.parent / "src" / "agent_factory.py"
        source = prompt_file.read_text()
        assert "_should_expand_tool_help" in source
        assert "Tool details for this turn:" in source

    def test_google_workspace_in_skills_package_list(self):
        from tools.skills import _TOOL_PACKAGES

        namespaces = [ns for ns, _, _ in _TOOL_PACKAGES]
        assert "google_workspace" in namespaces

    def test_disabled_google_workspace_not_in_skills(self):
        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_GOOGLE_WORKSPACE": "1"}):
            from tools.skills import get_atomos_skills
            tools = get_atomos_skills()
            names = {getattr(t, "name", str(t)) for t in tools}
            for tool_name in [
                "google_mail_search", "google_mail_send",
                "google_calendar_list", "google_calendar_create",
                "google_drive_list", "google_drive_download",
                "google_docs_read", "google_docs_write",
            ]:
                assert tool_name not in names
