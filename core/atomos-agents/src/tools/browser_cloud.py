"""
Browser Use Cloud API runner (browser-use-sdk v2.x).

Uses the v2 SDK API: client.tasks.create_task() + task_response.complete().

API key resolution order:
  1. $HOME/.browser_use  (first line of the file)
  2. OS keyring / encrypted-file fallback via secret_store

The key value is never logged, never passed to the LLM, and never present
in any agent message.  The sentinel string CLOUD_KEY_TOKEN is used in any
display or debug context that would otherwise reference the key.
"""

import logging
import os
import asyncio
from pathlib import Path
from typing import List, Optional

from secret_store import CredentialRequiredError

logger = logging.getLogger(__name__)

CLOUD_KEY_TOKEN = "__BROWSER_USE_CLOUD_KEY__"
_BROWSER_USE_API_KEY = "browser_use_api_key"


def _read_cloud_browser_timeout() -> int:
    """Return cloud browser timeout from env, with sane fallback bounds."""
    raw = os.environ.get("BROWSER_CLOUD_TIMEOUT_SECONDS", "").strip()
    try:
        value = int(raw) if raw else 300
    except ValueError:
        value = 300
    return max(30, min(value, 1800))


_CLOUD_TASK_TIMEOUT_SECONDS = _read_cloud_browser_timeout()


def _read_browser_use_key_file(path: Path) -> Optional[str]:
    """Read the Browser Use Cloud API key from the first line of *path*."""
    try:
        line = path.read_text().splitlines()[0].strip()
        return line or None
    except (FileNotFoundError, IndexError, OSError):
        return None


def _get_browser_use_api_key() -> Optional[str]:
    """Return the Browser Use Cloud API key, checking $HOME/.browser_use first.

    Resolution order:
      1. ``$HOME/.browser_use``  (first line)
      2. ``/home/$SUDO_USER/.browser_use``
      3. Scan ``/home/*/.browser_use``

    Falls back to the secret store when no file is found.
    """
    key = _read_browser_use_key_file(Path.home() / ".browser_use")
    if key:
        return key

    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        key = _read_browser_use_key_file(Path("/home") / sudo_user / ".browser_use")
        if key:
            return key

    try:
        for entry in sorted(Path("/home").iterdir()):
            if entry.is_dir():
                key = _read_browser_use_key_file(entry / ".browser_use")
                if key:
                    return key
    except OSError:
        pass

    from secret_store import get_secret
    return get_secret(_BROWSER_USE_API_KEY)


def _get_cloud_client():
    """Instantiate the Browser Use Cloud SDK client (v2 default import).

    Tries ``$HOME/.browser_use`` first, then the secret store.
    Raises CredentialRequiredError when no key is found anywhere.
    """
    api_key = _get_browser_use_api_key()
    if not api_key:
        raise CredentialRequiredError(_BROWSER_USE_API_KEY)

    try:
        from browser_use_sdk import AsyncBrowserUse
    except ImportError as exc:
        raise RuntimeError(
            "browser-use-sdk >=2.0 not installed. "
            "Run: pip install 'browser-use-sdk>=2.0.0'"
        ) from exc

    return AsyncBrowserUse(api_key=api_key)


async def run_cloud_browser_task(
    task: str,
    start_url: Optional[str] = None,
    allowed_domains: Optional[List[str]] = None,
) -> str:
    """
    Run a single browser task via Browser Use Cloud.

    Uses the v2 SDK: creates a task via ``client.tasks.create_task()``,
    then polls until completion via ``task_response.complete()``.

    Raises:
        CredentialRequiredError: when no API key is found.
    """
    client = _get_cloud_client()

    kwargs: dict = {}
    if start_url:
        kwargs["start_url"] = start_url
    if allowed_domains:
        kwargs["allowed_domains"] = allowed_domains

    task_response = await client.tasks.create_task(task=task, **kwargs)
    result = await asyncio.wait_for(
        task_response.complete(), timeout=_CLOUD_TASK_TIMEOUT_SECONDS
    )
    logger.info("Cloud browser task complete (id=%s, status=%s)", result.id, result.status)
    return result.output or ""


async def run_cloud_browser_session(
    tasks: List[str],
    profile_name: Optional[str] = None,
    proxy_country: str = "us",
) -> List[str]:
    """
    Run multiple tasks in a single persistent cloud browser session.

    Maintains cookies and localStorage across all tasks in the list.

    Raises:
        CredentialRequiredError: when no API key is found.
    """
    client = _get_cloud_client()

    profile_id: Optional[str] = None
    if profile_name:
        profiles = await client.profiles.list()
        for p in profiles:
            if p.name == profile_name:
                profile_id = str(p.id)
                break
        if not profile_id:
            profile = await client.profiles.create(name=profile_name)
            profile_id = str(profile.id)
            logger.info("Created new browser profile: %s", profile_name)

    session_kwargs: dict = {}
    if profile_id:
        session_kwargs["profile_id"] = profile_id
    session = await client.sessions.create(**session_kwargs)
    session_id = str(session.id)
    logger.info("Cloud browser session started (id=%s)", session_id)

    results: List[str] = []
    try:
        for task in tasks:
            task_response = await client.tasks.create_task(task=task, session_id=session_id)
            result = await task_response.complete()
            results.append(result.output or "")
    finally:
        await client.sessions.stop(session_id)
        logger.info("Cloud browser session stopped (id=%s)", session_id)

    return results
