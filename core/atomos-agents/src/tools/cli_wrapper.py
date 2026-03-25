"""Generic CLI tool wrapper for atomos-agents.

Provides ``CliToolWrapper`` — a base class that wraps any CLI binary as
a set of LangChain ``@tool``-decorated functions.  Subclasses define the
commands; the wrapper handles:

  - stdout/stderr capture with timeout
  - Output format detection (JSON, CSV, plain text) and structured parsing
  - Credential/secret injection at invocation time (via keyring or env)
  - Binary availability checks at startup
  - Consistent error handling and formatting
"""

from __future__ import annotations

import csv
import io
import json
import logging
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

_DEFAULT_TIMEOUT = 120
_MAX_OUTPUT_BYTES = 200_000


class CliToolError(RuntimeError):
    """Raised when a CLI invocation fails in a recoverable way."""


class BinaryNotFoundError(CliToolError):
    """Raised at startup when the required CLI binary is not on $PATH."""


class CredentialExpiredError(CliToolError):
    """Raised when a CLI tool reports an expired or invalid credential."""


# ── output format detection ────────────────────────────────────────────────


def detect_output_format(text: str) -> str:
    """Heuristically detect whether *text* is JSON, CSV, or plain text.

    Returns ``"json"``, ``"csv"``, or ``"text"``.
    """
    stripped = text.strip()
    if not stripped:
        return "text"
    if stripped[0] in ("{", "["):
        try:
            json.loads(stripped)
            return "json"
        except (json.JSONDecodeError, ValueError):
            pass
    lines = stripped.splitlines()
    if len(lines) >= 2:
        try:
            dialect = csv.Sniffer().sniff(lines[0], delimiters=",\t")
            reader = csv.reader(io.StringIO(stripped), dialect)
            rows = list(reader)
            if len(rows) >= 2 and all(len(r) == len(rows[0]) for r in rows[:5]):
                return "csv"
        except csv.Error:
            pass
    return "text"


def parse_output(text: str, *, hint: str | None = None) -> Any:
    """Parse CLI output into a structured Python object.

    When *hint* is provided (``"json"``, ``"csv"``, ``"text"``), that
    format is tried first.  Otherwise the format is auto-detected.

    Returns a dict/list for JSON, a list-of-dicts for CSV (using the
    first row as headers), or the raw string for plain text.
    """
    fmt = hint or detect_output_format(text)
    stripped = text.strip()
    if fmt == "json" and stripped:
        try:
            return json.loads(stripped)
        except (json.JSONDecodeError, ValueError):
            pass
    if fmt == "csv" and stripped:
        try:
            reader = csv.DictReader(io.StringIO(stripped))
            return list(reader)
        except csv.Error:
            pass
    return text


# ── generic wrapper ────────────────────────────────────────────────────────


class CliToolWrapper:
    """Base class for wrapping a CLI binary as agent tools.

    Parameters
    ----------
    binary : str
        Name (or full path) of the CLI binary.
    version_flag : str
        Flag to check the binary version (e.g. ``"--version"``).
    env_overrides : dict
        Extra environment variables injected into every invocation.
    timeout : int
        Default command timeout in seconds.
    credential_env_vars : dict
        Mapping of ``{env_var: keyring_service_name}`` for credentials
        that should be resolved from the OS keyring / secret store and
        injected into the command environment.
    """

    def __init__(
        self,
        binary: str,
        *,
        version_flag: str = "--version",
        env_overrides: dict[str, str] | None = None,
        timeout: int = _DEFAULT_TIMEOUT,
        credential_env_vars: dict[str, str] | None = None,
    ):
        self.binary = binary
        self.version_flag = version_flag
        self.env_overrides = env_overrides or {}
        self.timeout = timeout
        self.credential_env_vars = credential_env_vars or {}
        self._binary_path: str | None = None

    # ── startup checks ─────────────────────────────────────────────────

    def check_binary(self) -> str:
        """Verify the binary exists on ``$PATH`` and return its path.

        Raises ``BinaryNotFoundError`` with an actionable message when
        the binary cannot be found.
        """
        path = shutil.which(self.binary)
        if path is None:
            raise BinaryNotFoundError(
                f"CLI binary '{self.binary}' not found on $PATH.  "
                f"Install it first (e.g. apt install {self.binary} or "
                f"download from the project's releases page)."
            )
        self._binary_path = path
        return path

    def get_version(self) -> str | None:
        """Run ``<binary> <version_flag>`` and return the first output line."""
        try:
            self.check_binary()
        except BinaryNotFoundError:
            return None
        try:
            result = subprocess.run(
                [self.binary, self.version_flag],
                capture_output=True, text=True, timeout=10,
            )
            return result.stdout.strip().splitlines()[0] if result.stdout else None
        except Exception:
            return None

    # ── credential resolution ──────────────────────────────────────────

    def _resolve_credentials(self) -> dict[str, str]:
        """Resolve credentials from keyring / env and return env-var dict."""
        resolved: dict[str, str] = {}
        for env_var, service_name in self.credential_env_vars.items():
            val = os.environ.get(env_var, "").strip()
            if val:
                resolved[env_var] = val
                continue
            try:
                import keyring
                secret = keyring.get_password(service_name, "default")
                if secret:
                    resolved[env_var] = secret
            except Exception:
                pass
        return resolved

    # ── command execution ──────────────────────────────────────────────

    def run(
        self,
        args: list[str],
        *,
        timeout: int | None = None,
        output_format: str | None = None,
        cwd: str | None = None,
        extra_env: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        """Execute the CLI binary with *args* and return a result dict.

        Returns
        -------
        dict with keys:
            ``stdout`` : str — raw stdout
            ``stderr`` : str — raw stderr
            ``exit_code`` : int
            ``parsed`` : Any — structured output (JSON/CSV/text)
            ``format`` : str — detected output format
        """
        if self._binary_path is None:
            self.check_binary()

        env = os.environ.copy()
        env.update(self.env_overrides)
        env.update(self._resolve_credentials())
        if extra_env:
            env.update(extra_env)

        cmd = [self.binary] + args
        effective_timeout = timeout or self.timeout

        try:
            proc = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=effective_timeout,
                cwd=cwd,
                env=env,
            )
        except subprocess.TimeoutExpired:
            return {
                "stdout": "",
                "stderr": f"Command timed out after {effective_timeout}s",
                "exit_code": 124,
                "parsed": None,
                "format": "text",
            }
        except FileNotFoundError:
            raise BinaryNotFoundError(
                f"CLI binary '{self.binary}' not found.  "
                f"Is it installed and on $PATH?"
            )

        stdout = proc.stdout or ""
        stderr = proc.stderr or ""

        if len(stdout) > _MAX_OUTPUT_BYTES:
            stdout = stdout[:_MAX_OUTPUT_BYTES] + "\n... (output truncated)"

        fmt = output_format or detect_output_format(stdout)
        parsed = parse_output(stdout, hint=fmt)

        if proc.returncode != 0 and self._looks_like_auth_error(stderr + stdout):
            raise CredentialExpiredError(
                f"CLI '{self.binary}' returned an authentication error "
                f"(exit {proc.returncode}): {stderr.strip()[:200]}"
            )

        return {
            "stdout": stdout,
            "stderr": stderr,
            "exit_code": proc.returncode,
            "parsed": parsed,
            "format": fmt,
        }

    @staticmethod
    def _looks_like_auth_error(output: str) -> bool:
        """Heuristic: check if output suggests an auth/credential failure."""
        lower = output.lower()
        auth_indicators = (
            "token has been expired",
            "token expired",
            "invalid_grant",
            "unauthorized",
            "authentication failed",
            "credentials have expired",
            "login required",
            "access_denied",
            "refresh token",
        )
        return any(indicator in lower for indicator in auth_indicators)

    def format_result(self, result: dict[str, Any]) -> str:
        """Format a ``run()`` result dict as a human-readable string."""
        if result["exit_code"] != 0:
            parts = []
            if result["stderr"]:
                parts.append(result["stderr"].strip())
            if result["stdout"]:
                parts.append(result["stdout"].strip())
            body = "\n".join(parts) or "(no output)"
            return f"Command failed (exit {result['exit_code']}):\n{body}"

        parsed = result["parsed"]
        if isinstance(parsed, (dict, list)):
            return json.dumps(parsed, indent=2, default=str)
        return str(parsed) if parsed else "(no output)"
