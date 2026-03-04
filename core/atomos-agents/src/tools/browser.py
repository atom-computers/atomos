"""
LangChain tools for browser automation.

browse_web              — one-off tasks: local OSS first, cloud fallback on
                          CAPTCHA / launch failure
browse_web_with_session — multi-step stateful tasks: always local, persistent
                          Chromium window so the user can solve CAPTCHAs manually

The local model name is set at agent initialisation time via set_local_model()
so tools use the same Ollama model as the rest of the agent.
"""

import logging
from typing import Any, List, Optional

from langchain_core.tools import tool

from tools.browser_local import (
    BrowserLaunchError,
    CaptchaBlockedError,
    run_local_browser_task,
    run_local_browser_session,
)
from tools.browser_cloud import run_cloud_browser_task
from secret_store import CredentialRequiredError  # noqa: F401 — re-exported for server.py

logger = logging.getLogger(__name__)

# Set by agent_factory at startup via set_local_model().
_local_model: str = "llama3.2"


def set_local_model(model_name: str) -> None:
    """Register the Ollama model name to use for local browser tasks."""
    global _local_model
    _local_model = model_name


@tool
async def browse_web(
    task: str,
    start_url: Optional[str] = None,
    allowed_domains: Optional[List[str]] = None,
) -> str:
    """
    Browse the web and complete a task using AI-powered browser automation.

    Tries local Chromium + Ollama first. If blocked by CAPTCHA, bot detection,
    or a browser launch failure, automatically escalates to Browser Use Cloud
    (requires the cloud API key — user will be prompted once if not configured).

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
    logger.info("browse_web: starting local attempt (model=%s)", _local_model)
    try:
        result = await run_local_browser_task(task, _local_model, start_url)
        logger.info("browse_web: local attempt succeeded")
        return result
    except CaptchaBlockedError as exc:
        logger.warning("browse_web: CAPTCHA/bot-detection — %s; escalating to cloud", exc)
    except BrowserLaunchError as exc:
        logger.error("browse_web: Chromium failed to start — %s; escalating to cloud", exc)
    except TimeoutError as exc:
        logger.warning("browse_web: %s — escalating to cloud", exc)
    except OSError as exc:
        logger.warning("browse_web: local browser OS error — %s; escalating to cloud", exc)

    logger.info("browse_web: attempting cloud fallback")
    return await run_cloud_browser_task(task, start_url, allowed_domains)


@tool
async def browse_web_with_session(
    tasks: List[str],
    session_name: str = "default",
) -> List[str]:
    """
    Execute multiple browser tasks in a single persistent LOCAL browser session.

    The Chromium window stays visible on the desktop across all tasks so the
    user can solve CAPTCHAs or complete login flows manually when needed.
    Cookies and localStorage are preserved between tasks in the same session.

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
    return await run_local_browser_session(tasks, _local_model, session_name)


def get_browser_tools() -> List[Any]:
    return [browse_web, browse_web_with_session]
