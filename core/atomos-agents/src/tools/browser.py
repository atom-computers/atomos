"""
LangChain tools for browser automation.

browse_web              — one-off tasks: always tries local Chromium + remote
                          LLM first; escalates to Browser Use Cloud only on
                          CAPTCHA, launch failure, or timeout.
browse_web_with_session — multi-step stateful tasks: local persistent Chromium
                          session; escalates to Browser Use Cloud only when
                          Chromium cannot start.

The local model name is set at agent initialisation time via set_local_model()
so tools use the same model as the rest of the agent.
"""

import logging
from typing import Any, List, Optional

from langchain_core.tools import tool

from tools.browser_local import (
    BrowserLaunchError,
    CaptchaBlockedError,
    RateLimitError,
    run_local_browser_task,
    run_local_browser_session,
)
from tools.browser_cloud import (
    _get_browser_use_api_key,
    run_cloud_browser_task,
    run_cloud_browser_session,
)
from secret_store import CredentialRequiredError  # noqa: F401 — re-exported for server.py

logger = logging.getLogger(__name__)

# Set by agent_factory at startup via set_local_model().
_local_model: str = "llama3.2"
_model_is_cloud: bool = False
_groq_api_key: str | None = None
_openrouter_api_key: str | None = None


def set_local_model(
    model_name: str,
    is_cloud: bool = False,
    groq_api_key: str | None = None,
    openrouter_api_key: str | None = None,
) -> None:
    """Register the model to use for local browser tasks.

    When *is_cloud* is True the local browser tools use Groq or OpenRouter
    instead of Ollama.  Browser Use Cloud is only used as a fallback
    (CAPTCHA, launch failure, etc.).
    """
    global _local_model, _model_is_cloud, _groq_api_key, _openrouter_api_key
    _local_model = model_name
    _model_is_cloud = is_cloud
    _groq_api_key = groq_api_key
    _openrouter_api_key = openrouter_api_key


@tool
async def browse_web(
    task: str,
    start_url: Optional[str] = None,
    allowed_domains: Optional[List[str]] = None,
) -> str:
    """
    Browse the web and complete a task using AI-powered browser automation.

    Always uses local Chromium driven by the configured remote LLM.  Falls
    back to Browser Use Cloud only when Chromium cannot start, a CAPTCHA is
    hit, or a timeout occurs.

    Use this for:
    - Searching websites and extracting information
    - Reading page content that requires JavaScript
    - Any single-shot task that needs a real browser

    Args:
        task: Natural language description of what to do in the browser
        start_url: Optional URL to navigate to before starting the task
        allowed_domains: Optional list of domains to restrict navigation to

    Returns:
        The result text from the completed browser task
    """
    bu_key = _get_browser_use_api_key()
    logger.info("browse_web: trying local Chromium (model=%s cloud=%s bu_key=%s)", _local_model, _model_is_cloud, bool(bu_key))
    try:
        result = await run_local_browser_task(
            task, _local_model, start_url,
            is_cloud=_model_is_cloud, groq_api_key=_groq_api_key,
            browser_use_api_key=bu_key,
            openrouter_api_key=_openrouter_api_key,
        )
        if result.strip():
            logger.info("browse_web: local attempt succeeded")
            return result
        logger.warning("browse_web: local attempt returned empty output")
    except RateLimitError as exc:
        logger.error("browse_web: cloud rate/token limit — %s", exc)
        return (
            f"The page content is too large for the cloud model's free-tier "
            f"token limit.  Please try a simpler page, or use a local model "
            f"with enough context capacity.  ({exc})"
        )
    except CaptchaBlockedError as exc:
        logger.warning("browse_web: CAPTCHA/bot-detection — %s; escalating to cloud", exc)
    except BrowserLaunchError as exc:
        logger.error("browse_web: Chromium failed to start — %s; escalating to cloud", exc)
    except TimeoutError as exc:
        logger.warning("browse_web: %s — escalating to cloud", exc)
    except OSError as exc:
        logger.warning("browse_web: local browser OS error — %s; escalating to cloud", exc)

    if not bu_key:
        return (
            "Local browser failed and no Browser Use Cloud key is configured. "
            "Add a key to ~/.browser_use to enable cloud fallback."
        )
    logger.info("browse_web: attempting Browser Use Cloud fallback")
    try:
        result = await run_cloud_browser_task(task, start_url, allowed_domains)
        if result.strip():
            return result
        return (
            "Browser task completed but returned no extractable text. "
            "Please retry with a narrower prompt or specific URL."
        )
    except TimeoutError:
        return (
            "Browser Use Cloud timed out before producing a result. "
            "Please retry with a narrower prompt or specific URL."
        )
    except Exception as exc:
        logger.exception("browse_web: cloud fallback failed")
        return f"Browser task failed in cloud fallback: {exc}"


@tool
async def browse_web_with_session(
    tasks: List[str],
    session_name: str = "default",
) -> List[str]:
    """
    Execute multiple browser tasks in a single persistent browser session.

    Always uses a local Chromium window driven by the configured remote LLM,
    so cookies and login state persist between tasks and the user can solve
    CAPTCHAs manually.  Falls back to Browser Use Cloud only when Chromium
    cannot start.

    Use this when tasks need to share login state across steps, e.g.:
    - Log in to a site, then scrape data from authenticated pages
    - Fill a multi-step form across several pages
    - Any workflow that requires persistent cookies or session state

    Args:
        tasks: Ordered list of tasks to run in the same browser window
        session_name: Name for the persistent session (default: "default").
                      Use different names to maintain multiple independent
                      logged-in profiles simultaneously.

    Returns:
        List of result strings, one per task in the same order
    """
    bu_key = _get_browser_use_api_key()
    logger.info(
        "browse_web_with_session: using local session (model=%s cloud=%s bu_key=%s)",
        _local_model, _model_is_cloud, bool(bu_key),
    )
    try:
        return await run_local_browser_session(
            tasks, _local_model, session_name,
            is_cloud=_model_is_cloud, groq_api_key=_groq_api_key,
            browser_use_api_key=bu_key,
            openrouter_api_key=_openrouter_api_key,
        )
    except BrowserLaunchError as exc:
        logger.error("browse_web_with_session: Chromium failed to start — %s", exc)

    if not bu_key:
        raise BrowserLaunchError(
            "Local Chromium failed and no Browser Use Cloud key is configured. "
            "Add a key to ~/.browser_use to enable cloud fallback."
        )
    logger.info("browse_web_with_session: falling back to Browser Use Cloud")
    try:
        return await run_cloud_browser_session(tasks, profile_name=session_name)
    except Exception as exc:
        logger.exception("browse_web_with_session: cloud fallback failed")
        raise BrowserLaunchError(
            f"Cloud fallback failed after local launch error: {exc}"
        ) from exc


def get_browser_tools() -> List[Any]:
    return [browse_web, browse_web_with_session]
