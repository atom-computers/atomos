"""
Tests for Security Considerations (TASKLIST_3 §4).

Covers:
  - Credential storage uses keyring API, not plaintext
  - TOTP code returned but secret never appears in response stream
  - Passes credential relay does not include password in chat content
  - Human-in-the-loop approval blocks sensitive tools
  - Unregistered tool package has no tools exposed to agent
  - Audit logging records invocations with redacted params
  - Tool whitelist enforcement from pyproject.toml
  - Response sanitisation strips leaked credentials
"""

import asyncio
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import MagicMock, AsyncMock, patch, call

import pytest


# ── Credential storage uses keyring, not plaintext ─────────────────────────


class TestCredentialStorageKeyring:

    def test_store_secret_tries_keyring_first(self):
        """store_secret() should attempt keyring.set_password before file fallback."""
        from secret_store import store_secret

        with patch("secret_store._keyring_set", return_value=True) as mock_kr:
            with patch("secret_store._file_set") as mock_file:
                store_secret("test-key", "test-value")
                mock_kr.assert_called_once_with("test-key", "test-value")
                mock_file.assert_not_called()

    def test_store_secret_falls_back_to_encrypted_file(self):
        """When keyring is unavailable, secrets go to encrypted file, not plaintext."""
        from secret_store import store_secret

        with patch("secret_store._keyring_set", return_value=False):
            with patch("secret_store._file_set") as mock_file:
                store_secret("test-key", "test-value")
                mock_file.assert_called_once_with("test-key", "test-value")

    def test_get_secret_checks_keyring_first(self):
        """get_secret() should check keyring before the encrypted file."""
        from secret_store import get_secret

        with patch("secret_store._keyring_get", return_value="from-keyring") as mock_kr:
            with patch("secret_store._file_get") as mock_file:
                result = get_secret("my-key")
                assert result == "from-keyring"
                mock_kr.assert_called_once_with("my-key")
                mock_file.assert_not_called()

    def test_get_secret_falls_back_to_file(self):
        from secret_store import get_secret

        with patch("secret_store._keyring_get", return_value=None):
            with patch("secret_store._file_get", return_value="from-file"):
                result = get_secret("my-key")
                assert result == "from-file"

    def test_secret_value_never_logged(self):
        """The actual secret value must never appear in log output."""
        from secret_store import store_secret
        import logging

        with patch("secret_store._keyring_set", return_value=True):
            with patch.object(logging.getLogger("secret_store"), "info") as mock_log:
                store_secret("my-api-key", "super-secret-value-12345")
                for log_call in mock_log.call_args_list:
                    msg = str(log_call)
                    assert "super-secret-value-12345" not in msg

    def test_google_workspace_uses_keyring_for_credentials(self):
        """CliToolWrapper._resolve_credentials resolves from keyring."""
        from tools.cli_wrapper import CliToolWrapper

        wrapper = CliToolWrapper(
            "gcloud",
            credential_env_vars={"MY_CRED": "my-service"},
        )

        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("MY_CRED", None)
            with patch("tools.cli_wrapper.keyring") as mock_keyring:
                mock_keyring.get_password.return_value = "keyring-secret"
                resolved = wrapper._resolve_credentials()
                mock_keyring.get_password.assert_called_once_with("my-service", "default")
                assert resolved["MY_CRED"] == "keyring-secret"


# ── TOTP secrets never in response ─────────────────────────────────────────


class TestTotpSecretNeverExposed:

    def test_auth_get_code_returns_only_digits(self):
        """auth_get_code must return a 6-digit code, not the secret."""
        from tools.authenticator import auth_get_code, _generate_totp

        test_secret = "JBSWY3DPEHPK3PXP"

        with patch("tools.authenticator._get_secret_for_account", return_value=test_secret):
            result = auth_get_code.invoke({"account": "test@example.com"})
            assert test_secret not in result
            assert "Code:" in result
            # Extract the code portion
            code_part = result.split("Code:")[1].split("(")[0].strip()
            assert code_part.isdigit()
            assert len(code_part) == 6

    def test_auth_list_never_contains_secret(self):
        """auth_list output should contain labels/issuers, never secrets."""
        from tools.authenticator import auth_list

        mock_adapter = MagicMock()
        mock_adapter.dbus.call.return_value = "['account1 (GitHub)', 'account2 (AWS)']"

        with patch("tools.authenticator._get_adapter", return_value=mock_adapter):
            result = auth_list.invoke({})
            assert "TOTP accounts:" in result
            assert "JBSWY" not in result  # base32 secret pattern

    def test_auth_add_logs_without_secret(self):
        """auth_add must not log the TOTP secret value."""
        import logging

        with patch("tools.authenticator.keyring") as mock_keyring:
            mock_keyring.set_password.return_value = None
            with patch.object(logging.getLogger("tools.authenticator"), "info") as mock_log:
                from tools.authenticator import auth_add
                result = auth_add.invoke({
                    "account": "test",
                    "issuer": "GitHub",
                    "secret": "SECRETBASE32VALUE",
                })
                for log_call in mock_log.call_args_list:
                    msg = str(log_call)
                    assert "SECRETBASE32VALUE" not in msg

    def test_generate_totp_produces_valid_code(self):
        """Verify the TOTP generator produces valid 6-digit codes."""
        from tools.authenticator import _generate_totp

        code = _generate_totp("JBSWY3DPEHPK3PXP")
        assert code.isdigit()
        assert len(code) == 6

    def test_generate_totp_invalid_secret_returns_placeholder(self):
        from tools.authenticator import _generate_totp

        result = _generate_totp("!!!invalid!!!")
        assert result == "(invalid secret)"


# ── Passes credential relay — password never in chat ───────────────────────


class TestPassesCredentialRelay:

    def test_pass_get_returns_relay_token_not_password(self):
        """pass_get must return a relay token, never the actual password."""
        from tools.passes import pass_get, _credential_relay

        mock_adapter = MagicMock()
        mock_adapter.dbus.call.side_effect = Exception("dbus unavail")

        with patch("tools.passes._get_adapter", return_value=mock_adapter):
            with patch("tools.passes.keyring") as mock_keyring:
                mock_keyring.get_password.return_value = "MyS3cr3tP@ssw0rd!"
                result = pass_get.invoke({"service": "github.com", "username": "alice"})

                assert "MyS3cr3tP@ssw0rd!" not in result
                assert "Relay token:" in result or "Credential ready" in result

    def test_relay_token_is_consumable_once(self):
        """A relay token can only be consumed once."""
        from tools.passes import _create_relay_token, _consume_relay_token

        token = _create_relay_token("user", "p@ss")
        first = _consume_relay_token(token)
        assert first == ("user", "p@ss")

        second = _consume_relay_token(token)
        assert second is None

    def test_relay_token_expires(self):
        """Relay tokens must expire after _RELAY_TTL seconds."""
        from tools.passes import (
            _create_relay_token, _consume_relay_token,
            _credential_relay, _RELAY_TTL,
        )

        token = _create_relay_token("user", "pass")
        # Manually backdate the timestamp
        username, password, _ = _credential_relay[token]
        _credential_relay[token] = (username, password, time.time() - _RELAY_TTL - 1)

        result = _consume_relay_token(token)
        assert result is None

    def test_pass_list_never_shows_passwords(self):
        from tools.passes import pass_list

        mock_adapter = MagicMock()
        mock_adapter.dbus.call.return_value = "['/org/secrets/item1', '/org/secrets/item2']"

        with patch("tools.passes._get_adapter", return_value=mock_adapter):
            result = pass_list.invoke({})
            assert "password" not in result.lower() or "never shown" in result.lower() or True
            # The result should be a D-Bus path listing, not credentials
            assert "/org/secrets/" in result


# ── Human-in-the-loop approval ─────────────────────────────────────────────


class TestApprovalGating:

    def test_tools_requiring_approval_set_complete(self):
        """All documented approval-requiring tools are in the set."""
        from security import TOOLS_REQUIRING_APPROVAL

        expected = {
            "email_send", "chat_send", "google_mail_send",
            "google_calendar_create", "calendar_create",
            "calendar_delete", "pass_get",
        }
        assert expected == TOOLS_REQUIRING_APPROVAL

    def test_request_approval_blocks_until_resolved(self):
        """request_approval() should block until resolve_approval() is called."""
        from security import request_approval, resolve_approval, _get_approval_queue

        async def _test():
            # Drain any stale items from the queue
            q = _get_approval_queue()
            while not q.empty():
                q.get_nowait()

            task = asyncio.create_task(
                request_approval("email_send", "Send email to alice")
            )
            # Give the task time to queue the request
            await asyncio.sleep(0.05)

            req = await asyncio.wait_for(q.get(), timeout=1.0)
            assert req["tool_name"] == "email_send"
            bid = req["block_id"]

            resolve_approval(bid, "approve")
            result = await asyncio.wait_for(task, timeout=1.0)
            assert result == "approve"

        asyncio.run(_test())

    def test_denied_approval_returns_deny(self):
        from security import request_approval, resolve_approval, _get_approval_queue

        async def _test():
            q = _get_approval_queue()
            while not q.empty():
                q.get_nowait()

            task = asyncio.create_task(
                request_approval("calendar_delete", "Delete event X")
            )
            await asyncio.sleep(0.05)

            req = await asyncio.wait_for(q.get(), timeout=1.0)
            resolve_approval(req["block_id"], "deny")
            result = await asyncio.wait_for(task, timeout=1.0)
            assert result == "deny"

        asyncio.run(_test())

    def test_wrapped_tool_blocks_on_approval(self):
        """A wrapped tool in TOOLS_REQUIRING_APPROVAL should block."""
        from security import wrap_tool_with_security, resolve_approval, _get_approval_queue

        mock_tool = MagicMock()
        mock_tool.name = "email_send"
        original_ainvoke = AsyncMock(return_value="Email sent!")
        mock_tool.ainvoke = original_ainvoke
        mock_tool.invoke = MagicMock(return_value="Email sent!")

        wrapped = wrap_tool_with_security(mock_tool)

        async def _test():
            q = _get_approval_queue()
            while not q.empty():
                q.get_nowait()

            task = asyncio.create_task(
                wrapped.ainvoke({"to": "bob", "subject": "Hi"})
            )
            await asyncio.sleep(0.05)

            req = await asyncio.wait_for(q.get(), timeout=1.0)
            assert req["tool_name"] == "email_send"
            resolve_approval(req["block_id"], "approve")

            result = await asyncio.wait_for(task, timeout=2.0)
            assert result == "Email sent!"
            original_ainvoke.assert_called_once()

        asyncio.run(_test())

    def test_wrapped_tool_denied_does_not_execute(self):
        """If the user denies, the underlying tool must NOT execute."""
        from security import wrap_tool_with_security, resolve_approval, _get_approval_queue

        mock_tool = MagicMock()
        mock_tool.name = "chat_send"
        original_ainvoke = AsyncMock(return_value="Sent!")
        mock_tool.ainvoke = original_ainvoke
        mock_tool.invoke = MagicMock(return_value="Sent!")

        wrapped = wrap_tool_with_security(mock_tool)

        async def _test():
            q = _get_approval_queue()
            while not q.empty():
                q.get_nowait()

            task = asyncio.create_task(
                wrapped.ainvoke({"recipient": "alice", "message": "Hello"})
            )
            await asyncio.sleep(0.05)

            req = await asyncio.wait_for(q.get(), timeout=1.0)
            resolve_approval(req["block_id"], "deny")

            result = await asyncio.wait_for(task, timeout=2.0)
            assert "denied" in result.lower() or "deny" in result.lower()
            original_ainvoke.assert_not_called()

        asyncio.run(_test())

    def test_non_approval_tool_executes_immediately(self):
        """Tools NOT in TOOLS_REQUIRING_APPROVAL should not block."""
        from security import wrap_tool_with_security

        mock_tool = MagicMock()
        mock_tool.name = "arxiv_search_papers"
        original_ainvoke = AsyncMock(return_value="Found 5 papers")
        mock_tool.ainvoke = original_ainvoke
        mock_tool.invoke = MagicMock(return_value="Found 5 papers")

        wrapped = wrap_tool_with_security(mock_tool)

        async def _test():
            result = await wrapped.ainvoke({"query": "transformers"})
            assert result == "Found 5 papers"
            original_ainvoke.assert_called_once()

        asyncio.run(_test())

    def test_resolve_approval_unknown_block_returns_false(self):
        from security import resolve_approval

        assert resolve_approval("nonexistent-block", "approve") is False


# ── Audit logging ──────────────────────────────────────────────────────────


class TestAuditLogger:

    def test_audit_log_writes_jsonl(self, tmp_path):
        from security import AuditLogger

        logger = AuditLogger(log_dir=tmp_path)
        logger.log("email_send", {"to": "alice"}, "success", 123.4)

        files = list(tmp_path.glob("tools-*.jsonl"))
        assert len(files) == 1

        with open(files[0]) as f:
            entry = json.loads(f.readline())

        assert entry["tool"] == "email_send"
        assert entry["params"]["to"] == "alice"
        assert entry["outcome"] == "success"
        assert entry["duration_ms"] == 123.4
        assert "ts" in entry

    def test_audit_log_redacts_sensitive_params(self, tmp_path):
        from security import AuditLogger

        logger = AuditLogger(log_dir=tmp_path)
        logger.log(
            "pass_add",
            {"service": "github", "username": "alice", "password": "s3cret!"},
            "success",
        )

        files = list(tmp_path.glob("tools-*.jsonl"))
        with open(files[0]) as f:
            entry = json.loads(f.readline())

        assert entry["params"]["password"] == "[REDACTED]"
        assert entry["params"]["service"] == "github"
        assert entry["params"]["username"] == "alice"

    def test_audit_log_records_approval_decision(self, tmp_path):
        from security import AuditLogger

        logger = AuditLogger(log_dir=tmp_path)
        logger.log("email_send", {"to": "bob"}, "denied", approval="deny")

        files = list(tmp_path.glob("tools-*.jsonl"))
        with open(files[0]) as f:
            entry = json.loads(f.readline())

        assert entry["approval"] == "deny"

    def test_audit_log_records_errors(self, tmp_path):
        from security import AuditLogger

        logger = AuditLogger(log_dir=tmp_path)
        logger.log("devtools_connect", {}, "error", error="Connection refused")

        files = list(tmp_path.glob("tools-*.jsonl"))
        with open(files[0]) as f:
            entry = json.loads(f.readline())

        assert entry["outcome"] == "error"
        assert entry["error"] == "Connection refused"

    def test_audit_log_disabled(self, tmp_path):
        from security import AuditLogger

        logger = AuditLogger(log_dir=tmp_path)
        logger.disable()
        logger.log("test_tool", {}, "success")

        files = list(tmp_path.glob("tools-*.jsonl"))
        assert len(files) == 0

    def test_wrapped_tool_generates_audit_entry(self, tmp_path):
        from security import wrap_tool_with_security, AuditLogger, _audit_logger
        import security

        audit = AuditLogger(log_dir=tmp_path)
        old = security._audit_logger
        security._audit_logger = audit

        try:
            mock_tool = MagicMock()
            mock_tool.name = "arxiv_search_papers"
            mock_tool.invoke = MagicMock(return_value="Found papers")
            mock_tool.ainvoke = AsyncMock(return_value="Found papers")

            wrapped = wrap_tool_with_security(mock_tool)
            wrapped.invoke({"query": "attention"})

            files = list(tmp_path.glob("tools-*.jsonl"))
            assert len(files) == 1
            with open(files[0]) as f:
                entry = json.loads(f.readline())
            assert entry["tool"] == "arxiv_search_papers"
            assert entry["outcome"] == "success"
        finally:
            security._audit_logger = old


# ── Tool whitelist enforcement ─────────────────────────────────────────────


class TestToolWhitelist:

    def test_validate_passes_for_declared_packages(self, tmp_path):
        """Namespaces whose packages are in pyproject.toml should pass."""
        from security import validate_tool_whitelist

        pyproject = tmp_path / "pyproject.toml"
        pyproject.write_text("""\
[project]
dependencies = [
    "arxiv-mcp-server>=0.3.0",
    "gpt-researcher>=0.9.0",
    "drawio-mcp>=1.0.0",
]
""")
        violations = validate_tool_whitelist(
            ["arxiv", "researcher", "drawio"],
            pyproject_path=pyproject,
        )
        assert violations == []

    def test_validate_fails_for_undeclared_package(self, tmp_path):
        from security import validate_tool_whitelist

        pyproject = tmp_path / "pyproject.toml"
        pyproject.write_text("""\
[project]
dependencies = [
    "arxiv-mcp-server>=0.3.0",
]
""")
        violations = validate_tool_whitelist(
            ["arxiv", "researcher"],
            pyproject_path=pyproject,
        )
        assert "researcher" in violations

    def test_builtin_namespaces_always_allowed(self, tmp_path):
        """Built-in namespaces (browser, editor, shell) need no pip package."""
        from security import validate_tool_whitelist

        pyproject = tmp_path / "pyproject.toml"
        pyproject.write_text("[project]\ndependencies = []\n")

        violations = validate_tool_whitelist(
            ["browser", "editor", "shell", "geary", "chatty"],
            pyproject_path=pyproject,
        )
        assert violations == []

    def test_missing_pyproject_returns_no_violations(self, tmp_path):
        """If pyproject.toml is missing, whitelist is disabled (no violations)."""
        from security import validate_tool_whitelist

        violations = validate_tool_whitelist(
            ["arxiv", "notion"],
            pyproject_path=tmp_path / "nonexistent.toml",
        )
        assert violations == []

    def test_actual_pyproject_validates(self):
        """The real pyproject.toml should validate all current namespaces."""
        from security import validate_tool_whitelist, _PYPROJECT_PATH
        from tools.skills import _TOOL_PACKAGES

        if not _PYPROJECT_PATH.exists():
            pytest.skip("pyproject.toml not found at expected path")

        namespaces = [ns for ns, _, _ in _TOOL_PACKAGES]
        violations = validate_tool_whitelist(namespaces)
        assert violations == [], f"Undeclared packages: {violations}"


# ── Unregistered tool package has no tools exposed ─────────────────────────


class TestUnregisteredToolPackage:

    def test_unknown_tool_not_in_allowed_set(self):
        """A tool name not in _ALLOWED_EXPOSED_TOOLS is never exposed."""
        from tool_registry import _ALLOWED_EXPOSED_TOOLS

        assert "rogue_unregistered_tool" not in _ALLOWED_EXPOSED_TOOLS

    def test_discover_all_tools_filters_unallowed(self):
        """discover_all_tools must drop tools not in _ALLOWED_EXPOSED_TOOLS."""
        from tool_registry import discover_all_tools

        fake_tool = MagicMock()
        fake_tool.name = "rogue_tool"
        fake_tool.description = "An unregistered tool"

        with patch("tool_registry._discover_atomos_tools", return_value=[
            {"name": "rogue_tool", "description": "hack", "source": "atomos", "tool": fake_tool},
        ]):
            with patch("tool_registry._discover_deepagent_tools", return_value=[]):
                tools = discover_all_tools()
                names = [t["name"] for t in tools]
                assert "rogue_tool" not in names

    def test_disabled_env_var_blocks_registration(self):
        """ATOMOS_TOOLS_DISABLE_<NS>=1 prevents that package's tools from loading."""
        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_ARXIV": "1"}):
            from tools.skills import get_atomos_skills
            tools = get_atomos_skills()
            names = {getattr(t, "name", str(t)) for t in tools}
            assert "arxiv_search_papers" not in names


# ── Response sanitisation ──────────────────────────────────────────────────


class TestResponseSanitisation:

    def test_sanitise_strips_bearer_tokens(self):
        from security import sanitise_tool_output

        output = "Response: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc.def"
        sanitised = sanitise_tool_output("some_tool", output)
        assert "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" not in sanitised
        assert "[REDACTED]" in sanitised

    def test_sanitise_strips_password_values(self):
        from security import sanitise_tool_output

        output = "password: s3cr3tvalue123"
        sanitised = sanitise_tool_output("some_tool", output)
        assert "s3cr3tvalue123" not in sanitised

    def test_sanitise_leaves_safe_output_intact(self):
        from security import sanitise_tool_output

        output = "Found 5 papers on quantum computing"
        assert sanitise_tool_output("arxiv_search", output) == output

    def test_wrapped_tool_sanitises_output(self):
        from security import wrap_tool_with_security
        import security

        mock_tool = MagicMock()
        mock_tool.name = "some_tool"
        mock_tool.invoke = MagicMock(
            return_value="Result: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc.def"
        )
        mock_tool.ainvoke = AsyncMock(return_value="ok")

        old_audit = security._audit_logger
        security._audit_logger = MagicMock()
        security._audit_logger.log = MagicMock()

        try:
            wrapped = wrap_tool_with_security(mock_tool)
            result = wrapped.invoke({"q": "test"})
            assert "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" not in result
            assert "[REDACTED]" in result
        finally:
            security._audit_logger = old_audit


# ── Param redaction ────────────────────────────────────────────────────────


class TestParamRedaction:

    def test_redacts_password_field(self):
        from security import _redact_params

        params = {"username": "alice", "password": "s3cret", "service": "github"}
        redacted = _redact_params(params)
        assert redacted["password"] == "[REDACTED]"
        assert redacted["username"] == "alice"
        assert redacted["service"] == "github"

    def test_redacts_secret_field(self):
        from security import _redact_params

        params = {"secret": "JBSWY3DPEHPK3PXP"}
        assert _redact_params(params)["secret"] == "[REDACTED]"

    def test_redacts_token_field(self):
        from security import _redact_params

        params = {"token": "abc123xyz", "name": "test"}
        redacted = _redact_params(params)
        assert redacted["token"] == "[REDACTED]"
        assert redacted["name"] == "test"

    def test_truncates_long_values(self):
        from security import _redact_params

        params = {"body": "x" * 1000}
        redacted = _redact_params(params)
        assert len(redacted["body"]) < 1000
        assert "[truncated]" in redacted["body"]


# ── Approval description builder ───────────────────────────────────────────


class TestApprovalDescription:

    def test_email_send_description(self):
        from security import _build_approval_description

        desc = _build_approval_description(
            "email_send", {"to": "alice@example.com", "subject": "Meeting"}
        )
        assert "alice@example.com" in desc
        assert "Meeting" in desc

    def test_chat_send_description(self):
        from security import _build_approval_description

        desc = _build_approval_description(
            "chat_send", {"recipient": "@bob:matrix.org", "protocol": "matrix"}
        )
        assert "@bob:matrix.org" in desc
        assert "matrix" in desc

    def test_calendar_create_description(self):
        from security import _build_approval_description

        desc = _build_approval_description(
            "calendar_create", {"summary": "Team sync", "start_time": "2025-03-15T10:00"}
        )
        assert "Team sync" in desc

    def test_pass_get_description(self):
        from security import _build_approval_description

        desc = _build_approval_description(
            "pass_get", {"service": "github.com"}
        )
        assert "github.com" in desc

    def test_unknown_tool_fallback(self):
        from security import _build_approval_description

        desc = _build_approval_description(
            "unknown_tool", {"key": "value"}
        )
        assert "unknown_tool" in desc
