"""Google Workspace CLI tools for atomos-agents.

Wraps the ``gcloud`` CLI (with Workspace add-ons) as LangChain tools so
the agent can search/send mail, manage calendar events, list/download
Drive files, and read/write Google Docs.

Authentication is handled via OAuth or service account credentials
stored in the OS keyring.  Token refresh is automatic — if a command
fails with an auth error, the wrapper attempts a ``gcloud auth login``
refresh before retrying.

Requires:
  - ``gcloud`` CLI installed and on $PATH
  - OAuth credentials configured via ``gcloud auth login`` or a service
    account key stored in the keyring under ``google-workspace-sa-key``.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Optional

from langchain_core.tools import tool

from tools.cli_wrapper import (
    CliToolWrapper,
    CredentialExpiredError,
    BinaryNotFoundError,
    parse_output,
)
from tools._shared import resolve_api_key, format_result

logger = logging.getLogger(__name__)

# ── shared wrapper instance ────────────────────────────────────────────────

_wrapper: CliToolWrapper | None = None


def _get_wrapper() -> CliToolWrapper:
    """Return (or create) the shared ``gcloud`` CLI wrapper singleton."""
    global _wrapper
    if _wrapper is None:
        _wrapper = CliToolWrapper(
            "gcloud",
            version_flag="--version",
            env_overrides={
                "CLOUDSDK_CORE_PROJECT": os.environ.get(
                    "GOOGLE_CLOUD_PROJECT", ""
                ),
            },
            timeout=60,
            credential_env_vars={
                "GOOGLE_APPLICATION_CREDENTIALS": "google-workspace-sa-key",
            },
        )
    return _wrapper


def _run_gcloud(
    args: list[str],
    *,
    output_format: str = "json",
    retry_on_auth: bool = True,
) -> str:
    """Run a gcloud command and return formatted output.

    If the command fails with a credential error and *retry_on_auth* is
    ``True``, attempts ``gcloud auth login --brief`` and retries once.
    """
    wrapper = _get_wrapper()
    full_args = args + ["--format", output_format]

    try:
        result = wrapper.run(full_args, output_format=output_format)
    except BinaryNotFoundError as exc:
        return str(exc)
    except CredentialExpiredError:
        if not retry_on_auth:
            return (
                "Google Workspace credentials have expired.  "
                "Run 'gcloud auth login' to re-authenticate."
            )
        logger.info("Credential expired — attempting token refresh…")
        try:
            wrapper.run(
                ["auth", "login", "--brief", "--no-launch-browser"],
                output_format="text",
            )
        except Exception as refresh_exc:
            return (
                f"Credential refresh failed: {refresh_exc}  "
                f"Run 'gcloud auth login' manually to re-authenticate."
            )
        try:
            result = wrapper.run(full_args, output_format=output_format)
        except CredentialExpiredError:
            return (
                "Google Workspace credentials are still invalid after refresh.  "
                "Run 'gcloud auth login' to re-authenticate."
            )

    return wrapper.format_result(result)


# ── Gmail tools ────────────────────────────────────────────────────────────


@tool
def google_mail_search(
    query: str,
    max_results: int = 20,
) -> str:
    """Search Gmail for messages matching a query.

    Uses the same query syntax as the Gmail search bar (e.g.
    ``from:alice subject:meeting after:2024/01/01``).  Returns message
    IDs, subjects, senders, dates, and snippet previews.
    """
    return _run_gcloud([
        "workspace", "gmail", "messages", "list",
        f"--query={query}",
        f"--max-results={max_results}",
    ])


@tool
def google_mail_send(
    to: str,
    subject: str,
    body: str,
    cc: Optional[str] = None,
    bcc: Optional[str] = None,
) -> str:
    """Send an email via Gmail.

    Args:
        to: Recipient email address(es), comma-separated.
        subject: Email subject line.
        body: Plain-text email body.
        cc: Optional CC addresses, comma-separated.
        bcc: Optional BCC addresses, comma-separated.
    """
    args = [
        "workspace", "gmail", "messages", "send",
        f"--to={to}",
        f"--subject={subject}",
        f"--body={body}",
    ]
    if cc:
        args.append(f"--cc={cc}")
    if bcc:
        args.append(f"--bcc={bcc}")
    return _run_gcloud(args, output_format="text")


# ── Calendar tools ─────────────────────────────────────────────────────────


@tool
def google_calendar_list(
    time_min: Optional[str] = None,
    time_max: Optional[str] = None,
    max_results: int = 25,
) -> str:
    """List upcoming Google Calendar events.

    Dates should be in RFC3339 format (e.g. ``2024-03-01T00:00:00Z``).
    Omitting both dates returns the next *max_results* events.
    """
    args = [
        "workspace", "calendar", "events", "list",
        f"--max-results={max_results}",
    ]
    if time_min:
        args.append(f"--time-min={time_min}")
    if time_max:
        args.append(f"--time-max={time_max}")
    return _run_gcloud(args)


@tool
def google_calendar_create(
    summary: str,
    start_time: str,
    end_time: str,
    description: Optional[str] = None,
    location: Optional[str] = None,
    attendees: Optional[str] = None,
) -> str:
    """Create a new Google Calendar event.

    Args:
        summary: Event title.
        start_time: Start time in RFC3339 (e.g. ``2024-03-15T10:00:00Z``).
        end_time: End time in RFC3339.
        description: Optional event description.
        location: Optional event location.
        attendees: Optional comma-separated email addresses.
    """
    args = [
        "workspace", "calendar", "events", "create",
        f"--summary={summary}",
        f"--start-time={start_time}",
        f"--end-time={end_time}",
    ]
    if description:
        args.append(f"--description={description}")
    if location:
        args.append(f"--location={location}")
    if attendees:
        args.append(f"--attendees={attendees}")
    return _run_gcloud(args)


# ── Drive tools ────────────────────────────────────────────────────────────


@tool
def google_drive_list(
    query: Optional[str] = None,
    max_results: int = 25,
) -> str:
    """List files in Google Drive.

    Optional *query* uses the Drive search syntax (e.g.
    ``name contains 'report' and mimeType='application/pdf'``).
    """
    args = [
        "workspace", "drive", "files", "list",
        f"--max-results={max_results}",
    ]
    if query:
        args.append(f"--query={query}")
    return _run_gcloud(args)


@tool
def google_drive_download(
    file_id: str,
    destination: str = "~/Downloads",
) -> str:
    """Download a file from Google Drive by its file ID.

    The file is saved to *destination* (default ``~/Downloads``).
    """
    return _run_gcloud([
        "workspace", "drive", "files", "export",
        f"--file-id={file_id}",
        f"--destination={destination}",
    ], output_format="text")


# ── Docs tools ─────────────────────────────────────────────────────────────


@tool
def google_docs_read(
    document_id: str,
) -> str:
    """Read the content of a Google Doc by its document ID.

    Returns the document content as structured JSON with paragraphs,
    headings, lists, and tables.
    """
    return _run_gcloud([
        "workspace", "docs", "get",
        f"--document-id={document_id}",
    ])


@tool
def google_docs_write(
    document_id: str,
    content: str,
    insert_at: str = "end",
) -> str:
    """Append or insert text into a Google Doc.

    Args:
        document_id: The Google Doc ID.
        content: Text content to insert.
        insert_at: Where to insert — ``"end"`` (default) or ``"start"``.
    """
    return _run_gcloud([
        "workspace", "docs", "update",
        f"--document-id={document_id}",
        f"--content={content}",
        f"--insert-at={insert_at}",
    ], output_format="text")


# ── registration helper ───────────────────────────────────────────────────

_GOOGLE_WORKSPACE_TOOLS = None


def get_google_workspace_tools() -> list:
    """Return all Google Workspace tools.

    Returns ``[]`` if the ``gcloud`` binary is not found on ``$PATH``,
    so the rest of the agent continues to work without it.
    """
    global _GOOGLE_WORKSPACE_TOOLS
    if _GOOGLE_WORKSPACE_TOOLS is not None:
        return _GOOGLE_WORKSPACE_TOOLS

    wrapper = _get_wrapper()
    try:
        wrapper.check_binary()
        _GOOGLE_WORKSPACE_TOOLS = [
            google_mail_search,
            google_mail_send,
            google_calendar_list,
            google_calendar_create,
            google_drive_list,
            google_drive_download,
            google_docs_read,
            google_docs_write,
        ]
    except BinaryNotFoundError:
        logger.warning(
            "gcloud CLI not found — Google Workspace tools unavailable.  "
            "Install with: curl https://sdk.cloud.google.com | bash"
        )
        _GOOGLE_WORKSPACE_TOOLS = []

    return _GOOGLE_WORKSPACE_TOOLS
