"""Security infrastructure for atomos-agents (TASKLIST_3 §4).

Provides:

  TOOLS_REQUIRING_APPROVAL — frozenset of tool names that require human
      confirmation before execution (email send, message send, calendar
      create/delete, credential retrieval).

  request_approval()  — called by tools; queues a request and blocks
      until the user approves or denies via the UI.

  resolve_approval()  — called by the gRPC SendApproval handler to
      unblock the waiting tool.

  AuditLogger         — records every external tool invocation with
      timestamp, tool name, parameters (sensitive fields redacted),
      and outcome.

  validate_tool_whitelist() — ensures that only tool packages declared
      in pyproject.toml can register tools.

  wrap_tool_with_security() — wraps a LangChain tool with audit logging
      and (where required) approval gating.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from langchain_core.tools import BaseTool, StructuredTool

logger = logging.getLogger(__name__)

# ── tools requiring human-in-the-loop approval ────────────────────────────

TOOLS_REQUIRING_APPROVAL = frozenset({
    "email_send",
    "chat_send",
    "google_mail_send",
    "google_calendar_create",
    "calendar_create",
    "calendar_delete",
    "pass_get",
})

# ── async approval infrastructure ──────────────────────────────────────────

_approval_requests: asyncio.Queue | None = None
_approval_events: dict[str, tuple[asyncio.Event, dict]] = {}

_APPROVAL_TIMEOUT_SECONDS = 300


def _get_approval_queue() -> asyncio.Queue:
    global _approval_requests
    if _approval_requests is None:
        _approval_requests = asyncio.Queue()
    return _approval_requests


async def request_approval(
    tool_name: str,
    description: str,
    params: dict[str, Any] | None = None,
) -> str:
    """Queue an approval request and block until the user responds.

    Called from within async tool wrappers.  Returns ``"approve"``,
    ``"deny"``, or ``"__timeout__"``.
    """
    bid = f"approval-{uuid.uuid4().hex[:8]}"
    event = asyncio.Event()
    result: dict = {}
    _approval_events[bid] = (event, result)

    queue = _get_approval_queue()
    await queue.put({
        "block_id": bid,
        "tool_name": tool_name,
        "description": description,
        "params": _redact_params(params or {}),
    })

    try:
        await asyncio.wait_for(event.wait(), timeout=_APPROVAL_TIMEOUT_SECONDS)
        return result.get("action_id", "__timeout__")
    except asyncio.TimeoutError:
        return "__timeout__"
    finally:
        _approval_events.pop(bid, None)


def resolve_approval(block_id: str, action_id: str) -> bool:
    """Unblock a waiting ``request_approval`` call.

    Called by the ``SendApproval`` gRPC handler when the user clicks
    Approve or Deny in the applet UI.
    """
    entry = _approval_events.get(block_id)
    if entry is None:
        return False
    event, result = entry
    result["action_id"] = action_id
    event.set()
    return True


def has_pending_approvals() -> bool:
    return bool(_approval_events)


# ── audit logging ──────────────────────────────────────────────────────────

_SENSITIVE_PARAM_NAMES = frozenset({
    "password", "secret", "token", "credential", "api_key",
    "access_token", "refresh_token", "private_key",
})

_AUDIT_LOG_DIR = Path(
    os.environ.get("ATOMOS_AUDIT_LOG_DIR",
                    str(Path.home() / ".local" / "share" / "atomos" / "audit"))
)


def _redact_params(params: dict[str, Any]) -> dict[str, Any]:
    """Return a copy of *params* with sensitive values replaced by '[REDACTED]'."""
    redacted = {}
    for k, v in params.items():
        if k.lower() in _SENSITIVE_PARAM_NAMES:
            redacted[k] = "[REDACTED]"
        elif isinstance(v, str) and len(v) > 500:
            redacted[k] = v[:200] + "...[truncated]"
        else:
            redacted[k] = v
    return redacted


class AuditLogger:
    """Records every external tool invocation to a JSONL audit log.

    Each line is a JSON object::

        {
            "ts": "2025-03-15T10:23:01.123Z",
            "tool": "email_send",
            "params": {"to": "alice@example.com", "subject": "Hi"},
            "outcome": "success",
            "duration_ms": 245,
            "approval": "approve"
        }

    Sensitive parameter values are redacted automatically.
    """

    def __init__(self, log_dir: Path | None = None):
        self._log_dir = log_dir or _AUDIT_LOG_DIR
        self._log_file: Path | None = None
        self._enabled = True

    def _ensure_log_file(self) -> Path:
        if self._log_file is None:
            self._log_dir.mkdir(parents=True, exist_ok=True)
            today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            self._log_file = self._log_dir / f"tools-{today}.jsonl"
        return self._log_file

    def log(
        self,
        tool_name: str,
        params: dict[str, Any],
        outcome: str,
        duration_ms: float = 0,
        approval: str | None = None,
        error: str | None = None,
    ) -> None:
        if not self._enabled:
            return
        entry = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "tool": tool_name,
            "params": _redact_params(params),
            "outcome": outcome,
            "duration_ms": round(duration_ms, 1),
        }
        if approval:
            entry["approval"] = approval
        if error:
            entry["error"] = error[:500]

        try:
            path = self._ensure_log_file()
            with open(path, "a") as f:
                f.write(json.dumps(entry, default=str) + "\n")
        except OSError as exc:
            logger.warning("Audit log write failed: %s", exc)

        logger.info(
            "AUDIT: tool=%s outcome=%s duration=%.0fms%s",
            tool_name, outcome, duration_ms,
            f" approval={approval}" if approval else "",
        )

    def disable(self) -> None:
        self._enabled = False

    def enable(self) -> None:
        self._enabled = True


_audit_logger: AuditLogger | None = None


def get_audit_logger() -> AuditLogger:
    global _audit_logger
    if _audit_logger is None:
        _audit_logger = AuditLogger()
    return _audit_logger


# ── tool package whitelist ─────────────────────────────────────────────────

_PYPROJECT_PATH = Path(__file__).resolve().parent.parent / "pyproject.toml"


def _parse_pyproject_deps(path: Path | None = None) -> set[str]:
    """Extract declared dependency package names from pyproject.toml.

    Returns a set of normalised package names (lowered, hyphens → underscores).
    """
    p = path or _PYPROJECT_PATH
    if not p.exists():
        logger.warning("pyproject.toml not found at %s — whitelist disabled", p)
        return set()

    text = p.read_text()
    deps: set[str] = set()
    in_deps = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("dependencies") and "=" in stripped:
            in_deps = True
            continue
        if in_deps:
            if stripped == "]":
                in_deps = False
                continue
            match = re.match(r'"([a-zA-Z0-9_-]+)', stripped)
            if match:
                name = match.group(1).lower().replace("-", "_")
                deps.add(name)
    return deps


# Mapping from tool namespace → the pyproject.toml dependency that provides it.
# Built-in namespaces (browser, editor, shell) don't need external packages.
_NAMESPACE_TO_PACKAGE: dict[str, str | None] = {
    "browser": None,
    "editor": None,
    "shell": None,
    "arxiv": "arxiv_mcp_server",
    "devtools": "chrome_devtools_mcp_fork",
    "superpowers": None,  # vendored
    "researcher": "gpt_researcher",
    "drawio": "drawio_mcp",
    "notion": "notion_mcp_ldraney",
    "google_workspace": None,  # CLI tool, no pip package
    "geary": None,  # iso-ubuntu app
    "chatty": None,
    "amberol": None,
    "podcasts": None,
    "vocalis": None,
    "loupe": None,
    "karlender": None,
    "contacts": None,
    "pidif": None,
    "notejot": None,
    "authenticator": None,
    "passes": None,
}


def validate_tool_whitelist(
    namespaces: list[str],
    pyproject_path: Path | None = None,
) -> list[str]:
    """Return namespaces whose backing package is NOT in pyproject.toml.

    Namespaces mapped to ``None`` in ``_NAMESPACE_TO_PACKAGE`` (built-in,
    vendored, or system-level) are always allowed.

    Returns an empty list when all namespaces pass validation.
    """
    declared = _parse_pyproject_deps(pyproject_path)
    violations: list[str] = []
    for ns in namespaces:
        pkg = _NAMESPACE_TO_PACKAGE.get(ns)
        if pkg is None:
            continue
        if pkg not in declared:
            violations.append(ns)
            logger.warning(
                "Tool namespace '%s' requires package '%s' which is not "
                "declared in pyproject.toml dependencies",
                ns, pkg,
            )
    return violations


# ── response sanitisation ──────────────────────────────────────────────────

_CREDENTIAL_PATTERNS = [
    re.compile(r"password\s*[:=]\s*\S+", re.IGNORECASE),
    re.compile(r"secret\s*[:=]\s*[A-Za-z0-9+/=]{8,}", re.IGNORECASE),
    re.compile(r"Bearer\s+[A-Za-z0-9._-]{20,}"),
]


def sanitise_tool_output(tool_name: str, output: str) -> str:
    """Strip credential material that should never appear in chat.

    Applied automatically by the security wrapper.  Specific tools
    (authenticator, passes) have their own guardrails; this is a
    defence-in-depth layer.
    """
    result = output
    for pattern in _CREDENTIAL_PATTERNS:
        result = pattern.sub("[REDACTED]", result)
    return result


# ── tool wrapping ──────────────────────────────────────────────────────────


def wrap_tool_with_security(tool: BaseTool) -> BaseTool:
    """Wrap a LangChain tool with audit logging and approval gating.

    The returned tool:
      1. Logs every invocation to the audit log (params redacted).
      2. If the tool requires approval, blocks until the user approves.
      3. Sanitises the output to strip any leaked credentials.
    """
    name = getattr(tool, "name", "")
    needs_approval = name in TOOLS_REQUIRING_APPROVAL

    original_ainvoke = tool.ainvoke

    audit = get_audit_logger()

    async def _secured_ainvoke(input: Any, config=None, **kwargs) -> Any:
        params = input if isinstance(input, dict) else {"input": str(input)}
        approval_result = None

        if needs_approval:
            desc = _build_approval_description(name, params)
            approval_result = await request_approval(name, desc, params)
            if approval_result != "approve":
                audit.log(name, params, "denied", approval=approval_result)
                return f"Action '{name}' was {approval_result} by the user."

        t0 = time.monotonic()
        try:
            result = await original_ainvoke(input, config=config, **kwargs)
            duration = (time.monotonic() - t0) * 1000
            outcome = "success"
        except Exception as exc:
            duration = (time.monotonic() - t0) * 1000
            audit.log(name, params, "error", duration, approval_result, str(exc))
            raise

        audit.log(name, params, outcome, duration, approval_result)

        if isinstance(result, str):
            result = sanitise_tool_output(name, result)
        return result

    object.__setattr__(tool, "ainvoke", _secured_ainvoke)
    return tool


def _build_approval_description(tool_name: str, params: dict) -> str:
    """Build a human-readable description for the approval prompt."""
    desc_map = {
        "email_send": lambda p: f"Send email to {p.get('to', '?')}: {p.get('subject', '(no subject)')}",
        "google_mail_send": lambda p: f"Send Gmail to {p.get('to', '?')}: {p.get('subject', '(no subject)')}",
        "chat_send": lambda p: f"Send message to {p.get('recipient', '?')} via {p.get('protocol', '?')}",
        "calendar_create": lambda p: f"Create event: {p.get('summary', '(untitled)')} at {p.get('start_time', '?')}",
        "google_calendar_create": lambda p: f"Create Google Calendar event: {p.get('summary', '(untitled)')}",
        "calendar_delete": lambda p: f"Delete calendar event: {p.get('event_id', '?')}",
        "pass_get": lambda p: f"Retrieve credentials for: {p.get('service', '?')}",
    }
    builder = desc_map.get(tool_name)
    if builder:
        try:
            return builder(params)
        except Exception:
            pass
    redacted = _redact_params(params)
    return f"{tool_name}({', '.join(f'{k}={v!r}' for k, v in redacted.items())})"
