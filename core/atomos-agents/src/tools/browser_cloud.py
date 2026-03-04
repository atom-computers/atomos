"""
Browser Use Cloud API runner.

API key is retrieved from OS keyring at call time via require_secret().
It is never logged, never passed to the LLM, and never present in any
agent message. The sentinel string CLOUD_KEY_TOKEN is used in any
display or debug context that would otherwise reference the key.
"""

import logging
from typing import List, Optional

from secret_store import require_secret

logger = logging.getLogger(__name__)

CLOUD_KEY_TOKEN = "__BROWSER_USE_CLOUD_KEY__"
_BROWSER_USE_API_KEY = "browser_use_api_key"


def _get_cloud_client():
    """Instantiate the Browser Use SDK client, resolving key from keyring.

    Credential check happens before the SDK import so that a missing key
    raises CredentialRequiredError even when browser-use-sdk is not installed.
    """
    api_key = require_secret(_BROWSER_USE_API_KEY)

    try:
        from browser_use_sdk import AsyncBrowserUse
    except ImportError as exc:
        raise RuntimeError(
            "browser-use-sdk not installed. "
            "Run: pip install browser-use-sdk"
        ) from exc

    return AsyncBrowserUse(api_key=api_key)


async def run_cloud_browser_task(
    task: str,
    start_url: Optional[str] = None,
    allowed_domains: Optional[List[str]] = None,
) -> str:
    """
    Run a single browser task via Browser Use Cloud.

    Raises:
        CredentialRequiredError: when no API key is stored in keyring.
    """
    client = _get_cloud_client()
    result = await client.run(
        task,
        start_url=start_url,
        allowed_domains=allowed_domains,
    )
    logger.info("Cloud browser task complete (task_id=%s, status=%s)", result.id, result.status)
    return result.output


async def run_cloud_browser_session(
    tasks: List[str],
    profile_name: Optional[str] = None,
    proxy_country: str = "us",
) -> List[str]:
    """
    Run multiple tasks in a single persistent cloud browser session.

    Maintains cookies and localStorage across all tasks in the list.
    Raises:
        CredentialRequiredError: when no API key is stored in keyring.
    """
    client = _get_cloud_client()

    profile_id: Optional[str] = None
    if profile_name:
        profiles = await client.profiles.list()
        for p in profiles:
            if p.name == profile_name:
                profile_id = p.id
                break
        if not profile_id:
            profile = await client.profiles.create(name=profile_name)
            profile_id = profile.id
            logger.info("Created new browser profile: %s", profile_name)

    session = await client.sessions.create(
        profile_id=profile_id,
        proxy_country_code=proxy_country,
    )
    logger.info("Cloud browser session started (id=%s)", session.id)

    results: List[str] = []
    try:
        for task in tasks:
            result = await client.run(task, session_id=session.id)
            results.append(result.output)
    finally:
        await client.sessions.stop(session.id)
        logger.info("Cloud browser session stopped (id=%s)", session.id)

    return results
