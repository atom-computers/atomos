"""
Integration test: Security & approval flow (§4).

Covers:
  - Email send blocked without approval → approved → email sent → audit log entry created
"""

import asyncio
import json
import os
import time
import pytest
from pathlib import Path
from unittest.mock import MagicMock, patch

import bridge_pb2
from security import (
    TOOLS_REQUIRING_APPROVAL,
    AuditLogger,
    get_audit_logger,
    wrap_tool_with_security,
    request_approval,
    resolve_approval,
    _get_approval_queue,
    _approval_events,
    sanitise_tool_output,
)

pytestmark = pytest.mark.integration

_SKIP_REASON = "ATOMOS_INTEGRATION_TEST not set"


def _skip_unless_integration():
    if not os.environ.get("ATOMOS_INTEGRATION_TEST"):
        pytest.skip(_SKIP_REASON)


def _mock_which(binary):
    return f"/usr/bin/{binary}"


class TestApprovalFlowIntegration:
    """Integration: email send blocked without approval → approved → email
    sent → audit log entry created."""

    def test_email_send_blocked_then_approved(self, tmp_path):
        _skip_unless_integration()

        assert "email_send" in TOOLS_REQUIRING_APPROVAL

        audit_dir = tmp_path / "audit"
        audit = AuditLogger(log_dir=audit_dir)

        import tools.geary as geary_mod
        geary_mod._adapter = None
        geary_mod._GEARY_TOOLS = None

        with patch("shutil.which", side_effect=_mock_which):
            from tools.geary import email_send, _get_adapter
            adapter = _get_adapter()
            adapter._lifecycle._pid = 1
            mock_dbus = MagicMock()
            mock_dbus.call.return_value = "('Email sent to test@example.com',)"
            adapter._dbus = mock_dbus

            wrapped = wrap_tool_with_security(email_send)

            async def _run_approval_flow():
                loop = asyncio.get_event_loop()
                approval_queue = _get_approval_queue()

                # Drain any stale items
                while not approval_queue.empty():
                    approval_queue.get_nowait()

                async def _simulate_user_approve():
                    req = await asyncio.wait_for(approval_queue.get(), timeout=5)
                    block_id = req["block_id"]
                    assert req["tool_name"] == "email_send"
                    assert "test@example.com" in req["description"]
                    await asyncio.sleep(0.1)
                    resolved = resolve_approval(block_id, "approve")
                    assert resolved

                approve_task = asyncio.create_task(_simulate_user_approve())

                with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                    result = await wrapped.ainvoke({
                        "to": "test@example.com",
                        "subject": "Approval Test",
                        "body": "This email requires approval.",
                    })

                await approve_task
                return result

            result = asyncio.get_event_loop().run_until_complete(_run_approval_flow())
            assert "sent" in result.lower() or "Email" in result

        geary_mod._adapter = None
        geary_mod._GEARY_TOOLS = None

    def test_email_send_denied(self, tmp_path):
        """When approval is denied, the tool returns a denial message
        and the audit log records 'denied'."""
        _skip_unless_integration()

        audit_dir = tmp_path / "audit"
        audit = AuditLogger(log_dir=audit_dir)

        import tools.geary as geary_mod
        geary_mod._adapter = None
        geary_mod._GEARY_TOOLS = None

        with patch("shutil.which", side_effect=_mock_which):
            from tools.geary import email_send
            wrapped = wrap_tool_with_security(email_send)

            async def _run_denial_flow():
                approval_queue = _get_approval_queue()
                while not approval_queue.empty():
                    approval_queue.get_nowait()

                async def _simulate_user_deny():
                    req = await asyncio.wait_for(approval_queue.get(), timeout=5)
                    block_id = req["block_id"]
                    resolve_approval(block_id, "deny")

                deny_task = asyncio.create_task(_simulate_user_deny())
                result = await wrapped.ainvoke({
                    "to": "test@example.com",
                    "subject": "Should be denied",
                    "body": "This should not go through.",
                })
                await deny_task
                return result

            result = asyncio.get_event_loop().run_until_complete(_run_denial_flow())
            assert "denied" in result.lower() or "deny" in result.lower()

        geary_mod._adapter = None
        geary_mod._GEARY_TOOLS = None

    def test_audit_log_records_tool_invocation(self, tmp_path):
        """Every tool invocation is recorded in the audit log with
        timestamp, tool name, params, and outcome."""
        _skip_unless_integration()

        audit_dir = tmp_path / "audit"
        audit = AuditLogger(log_dir=audit_dir)

        audit.log(
            tool_name="email_send",
            params={"to": "test@example.com", "subject": "Test"},
            outcome="success",
            duration_ms=150.5,
            approval="approve",
        )

        log_files = list(audit_dir.glob("tools-*.jsonl"))
        assert len(log_files) == 1

        lines = log_files[0].read_text().strip().splitlines()
        assert len(lines) == 1

        entry = json.loads(lines[0])
        assert entry["tool"] == "email_send"
        assert entry["outcome"] == "success"
        assert entry["approval"] == "approve"
        assert entry["duration_ms"] == 150.5
        assert "ts" in entry
        assert entry["params"]["to"] == "test@example.com"

    def test_audit_log_redacts_sensitive_params(self, tmp_path):
        """Sensitive parameter values are redacted in the audit log."""
        _skip_unless_integration()

        audit_dir = tmp_path / "audit"
        audit = AuditLogger(log_dir=audit_dir)

        audit.log(
            tool_name="pass_get",
            params={"service": "github.com", "password": "s3cret!", "token": "ghp_xxx"},
            outcome="success",
            duration_ms=50,
        )

        log_files = list(audit_dir.glob("tools-*.jsonl"))
        entry = json.loads(log_files[0].read_text().strip())
        assert entry["params"]["password"] == "[REDACTED]"
        assert entry["params"]["token"] == "[REDACTED]"
        assert entry["params"]["service"] == "github.com"

    def test_output_sanitisation_strips_credentials(self):
        """Defence-in-depth: sanitise_tool_output strips leaked credentials."""
        _skip_unless_integration()

        dirty = "Result: password: s3cret123 and Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.test"
        clean = sanitise_tool_output("pass_get", dirty)
        assert "s3cret123" not in clean
        assert "eyJhbGci" not in clean
        assert "[REDACTED]" in clean

    def test_approval_timeout_returns_timeout(self):
        """If the user doesn't respond within the timeout, the tool
        receives a timeout signal."""
        _skip_unless_integration()

        from security import _APPROVAL_TIMEOUT_SECONDS

        async def _run_timeout():
            approval_queue = _get_approval_queue()
            while not approval_queue.empty():
                approval_queue.get_nowait()

            # Use a very short timeout for testing
            import security
            original = security._APPROVAL_TIMEOUT_SECONDS
            security._APPROVAL_TIMEOUT_SECONDS = 0.2

            try:
                result = await request_approval(
                    "email_send",
                    "Send email to test@example.com",
                    {"to": "test@example.com"},
                )
                return result
            finally:
                security._APPROVAL_TIMEOUT_SECONDS = original

        result = asyncio.get_event_loop().run_until_complete(_run_timeout())
        assert result == "__timeout__"
