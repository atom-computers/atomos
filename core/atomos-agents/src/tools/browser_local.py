"""
Local browser automation using the open-source browser-use library.

browser-use v0.12+ drives Chromium via cdp-use (Chrome DevTools Protocol).
A Chromium binary is still required on the system (installed by
``playwright install chromium`` during the ISO build).

Setup on AtomOS / Ubuntu 24.04:
    pip install browser-use
    playwright install chromium
    playwright install-deps chromium   # installs libnss3, libgbm1, etc.
"""

import asyncio
import logging
import os
from typing import Dict, List, Optional

logger = logging.getLogger(__name__)

# Top-level imports so patch() can target module attributes in tests.
# Set to None when not installed; run_local_browser_task() raises RuntimeError.
try:
    from browser_use import Agent, Browser, ChatOllama

    _BROWSER_USE_AVAILABLE = True
except ImportError:
    Agent = None  # type: ignore[assignment,misc]
    Browser = None  # type: ignore[assignment,misc]
    ChatOllama = None  # type: ignore[assignment,misc]
    _BROWSER_USE_AVAILABLE = False

CAPTCHA_SIGNALS = frozenset(
    [
        "captcha",
        "cloudflare",
        "challenge",
        "bot detection",
        "access denied",
        "please verify",
        "i am not a robot",
        "recaptcha",
        "hcaptcha",
        "turnstile",
        "verify you are human",
        "ddos-guard",
        "just a moment",  # Cloudflare waiting room
    ]
)

BROWSER_LAUNCH_SIGNALS = frozenset(
    [
        "on_browserstartevent",
        "on_browserlaunchevent",
        "timed out after",
        "connect call failed",
        "connectionrefusederror",
    ]
)


class CaptchaBlockedError(Exception):
    """Raised when the local browser hits CAPTCHA or bot-detection protection."""

    pass


class BrowserLaunchError(Exception):
    """Raised when the local Chromium process fails to start (no display, missing binary, etc.)."""

    pass


def _is_captcha_blocked(text: str) -> bool:
    lower = text.lower()
    return any(signal in lower for signal in CAPTCHA_SIGNALS)


def _is_browser_launch_failure(text: str) -> bool:
    lower = text.lower()
    return any(signal in lower for signal in BROWSER_LAUNCH_SIGNALS)


LOCAL_BROWSER_TIMEOUT_SECONDS = 120


def _find_wayland_socket() -> tuple[Optional[str], Optional[str]]:
    """
    Probe for an active Wayland socket without relying on environment variables.

    Scans /run/user/<uid>/ for each logged-in user and returns the first
    (xdg_runtime_dir, wayland_display) pair found.  This works when the
    atomos-agents systemd service runs as root and the Wayland session belongs
    to a different user (e.g. the desktop user).
    """
    import glob as _glob
    import pwd as _pwd

    run_user = "/run/user"
    if not os.path.isdir(run_user):
        return None, None

    for uid_dir in sorted(os.listdir(run_user)):
        xdg = os.path.join(run_user, uid_dir)
        sockets = _glob.glob(os.path.join(xdg, "wayland-*"))
        # Filter to actual sockets (not lock files)
        sockets = [s for s in sockets if not s.endswith(".lock") and os.path.exists(s)]
        if sockets:
            # Use the lowest-numbered socket (wayland-0 or wayland-1)
            sockets.sort()
            wayland_display = os.path.basename(sockets[0])
            return xdg, wayland_display

    return None, None


def _ensure_display_env() -> List[str]:
    """
    Ensure os.environ has the display variables Chromium needs.

    Resolution order:
    1. Environment variables already set (manual runs, tests, PassEnvironment)
    2. Probe /run/user/<uid>/wayland-* for any active Wayland session
       (works when atomos-agents runs as root and the desktop belongs to
       another user)

    Sets os.environ directly so that child processes (Chromium) inherit the
    full parent environment plus the display vars.  browser-use's ``env=``
    parameter replaces the entire env, which strips PATH/HOME/LD_LIBRARY_PATH
    and causes Chromium to crash — so we must NOT use ``env=`` on Browser().

    Returns a list of extra Chromium command-line args needed for the detected
    display (e.g. ``--ozone-platform=wayland`` when WAYLAND_DISPLAY is set).

    Raises BrowserLaunchError immediately if no display is found so the
    caller can escalate to the cloud browser instead of hanging for 30 s.
    """
    wayland = os.environ.get("WAYLAND_DISPLAY")
    xdg_runtime = os.environ.get("XDG_RUNTIME_DIR")
    display = os.environ.get("DISPLAY")

    if not wayland and not display:
        probed_xdg, probed_wayland = _find_wayland_socket()
        if probed_wayland:
            os.environ["WAYLAND_DISPLAY"] = probed_wayland
            wayland = probed_wayland
            if probed_xdg and not xdg_runtime:
                os.environ["XDG_RUNTIME_DIR"] = probed_xdg
            logger.info(
                "browse_web: discovered Wayland socket via filesystem probe: "
                "WAYLAND_DISPLAY=%s XDG_RUNTIME_DIR=%s",
                probed_wayland, probed_xdg,
            )

    if not wayland and not display:
        raise BrowserLaunchError(
            "No display server found: WAYLAND_DISPLAY and DISPLAY are both unset "
            "and no Wayland socket was found under /run/user/. "
            "Ensure the COSMIC desktop is running before the atomos-agents service."
        )

    logger.debug(
        "browse_web: display env WAYLAND_DISPLAY=%s DISPLAY=%s XDG_RUNTIME_DIR=%s",
        wayland, display, xdg_runtime,
    )

    # Chromium defaults to the X11 Ozone backend; it does NOT auto-detect
    # Wayland from the environment.  We must pass the flag explicitly.
    if wayland:
        return ["--ozone-platform=wayland"]
    return []


async def run_local_browser_task(
    task: str,
    model_name: str,
    start_url: Optional[str] = None,
    timeout: float = LOCAL_BROWSER_TIMEOUT_SECONDS,
) -> str:
    """
    Execute a browser task using the local OSS browser-use + Playwright stack.

    Raises:
        CaptchaBlockedError: when CAPTCHA or bot-detection is detected in output
            or raised as an exception by the browser agent.
        BrowserLaunchError: when Chromium fails to start (missing binary, no
            display in headed mode, sandbox issues, etc.).
        TimeoutError: when the browser agent exceeds *timeout* seconds.
        RuntimeError: when browser-use or playwright are not installed.
    """
    if not _BROWSER_USE_AVAILABLE:
        raise RuntimeError(
            "Local browser dependencies not installed. "
            "Run: pip install browser-use && playwright install chromium"
        )

    full_task = task
    if start_url:
        full_task = f"Navigate to {start_url} first, then: {task}"

    extra_args = _ensure_display_env()

    llm = ChatOllama(model=model_name)
    browser = Browser(headless=False, chromium_sandbox=False, args=extra_args)
    agent = Agent(task=full_task, llm=llm, browser=browser)

    try:
        history = await asyncio.wait_for(agent.run(), timeout=timeout)
        output: str = history.final_result() or ""

        if _is_captcha_blocked(output):
            raise CaptchaBlockedError(
                f"CAPTCHA/bot-detection in agent output: {output[:300]}"
            )

        return output

    except (CaptchaBlockedError, BrowserLaunchError):
        raise
    except TimeoutError as exc:
        if _is_browser_launch_failure(str(exc)):
            raise BrowserLaunchError(str(exc)) from exc
        detail = str(exc).strip()
        msg = f"Local browser task exceeded {timeout}s timeout"
        if detail:
            msg += f": {detail}"
        raise TimeoutError(msg) from exc
    except Exception as exc:
        msg = str(exc).lower()
        if _is_browser_launch_failure(msg):
            raise BrowserLaunchError(str(exc)) from exc
        if _is_captcha_blocked(msg):
            raise CaptchaBlockedError(str(exc)) from exc
        raise
    finally:
        await browser.stop()


# Keyed by session_name → Browser instance.  Browsers are created with
# keep_alive=True so the Chromium process persists between tasks.
_sessions: Dict[str, "Browser"] = {}  # type: ignore[type-arg]

SESSION_TASK_TIMEOUT_SECONDS = 300


async def run_local_browser_session(
    tasks: List[str],
    model_name: str,
    session_name: str = "default",
    timeout_per_task: float = SESSION_TASK_TIMEOUT_SECONDS,
) -> List[str]:
    """
    Run multiple tasks in a single persistent local browser session.

    The Chromium window stays open across all tasks so the user can solve
    CAPTCHAs manually when needed — the agent pauses and resumes once the
    page is unblocked.  Cookies and localStorage are preserved across tasks.

    A named session is reused if it already exists (e.g. for a logged-in
    profile).  Call close_local_browser_session() to tear it down explicitly.

    Raises:
        BrowserLaunchError: when Chromium fails to start.
        TimeoutError: when a single task exceeds timeout_per_task seconds.
        RuntimeError: when browser-use is not installed.
    """
    if not _BROWSER_USE_AVAILABLE:
        raise RuntimeError(
            "Local browser dependencies not installed. "
            "Run: pip install browser-use && playwright install chromium"
        )

    extra_args = _ensure_display_env()

    if session_name not in _sessions:
        _sessions[session_name] = Browser(
            headless=False,
            chromium_sandbox=False,
            keep_alive=True,
            args=extra_args,
        )
        logger.info("browse_web_with_session: opened session '%s'", session_name)

    browser = _sessions[session_name]
    llm = ChatOllama(model=model_name)
    results: List[str] = []

    for i, task in enumerate(tasks):
        logger.info(
            "browse_web_with_session: task %d/%d in session '%s'",
            i + 1, len(tasks), session_name,
        )
        agent = Agent(task=task, llm=llm, browser=browser)
        try:
            history = await asyncio.wait_for(agent.run(), timeout=timeout_per_task)
            output: str = history.final_result() or ""
        except TimeoutError as exc:
            if _is_browser_launch_failure(str(exc)):
                raise BrowserLaunchError(str(exc)) from exc
            detail = str(exc).strip()
            msg = f"Session task {i + 1} exceeded {timeout_per_task}s timeout"
            if detail:
                msg += f": {detail}"
            raise TimeoutError(msg) from exc
        except Exception as exc:
            msg = str(exc).lower()
            if _is_browser_launch_failure(msg):
                raise BrowserLaunchError(str(exc)) from exc
            raise
        results.append(output)

    return results


async def close_local_browser_session(session_name: str = "default") -> None:
    """Stop and remove a named persistent browser session."""
    browser = _sessions.pop(session_name, None)
    if browser is not None:
        await browser.stop()
        logger.info("browse_web_with_session: closed session '%s'", session_name)
