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

try:
    from browser_use import ChatBrowserUse as _ChatBrowserUse
except ImportError:
    _ChatBrowserUse = None  # type: ignore[assignment,misc]

try:
    from browser_use.llm import ChatGroq as BrowserChatGroq
except ImportError:
    try:
        from langchain_groq import ChatGroq as BrowserChatGroq
    except ImportError:
        BrowserChatGroq = None  # type: ignore[assignment,misc]

try:
    from langchain_openai import ChatOpenAI as _RawChatOpenAI
except ImportError:
    _RawChatOpenAI = None  # type: ignore[assignment,misc]


# ---------------------------------------------------------------------------
# browser-use compatibility shims
#
# browser-use's Agent.__init__ does two things that break Pydantic v2 models:
#   1. Reads llm.provider   — Pydantic __getattr__ raises AttributeError
#   2. token_cost_service.register_llm() does setattr(llm, 'ainvoke', ...)
#      — Pydantic __setattr__ raises ValueError for non-field attributes
#
# We subclass each langchain LLM to override __setattr__: Pydantic-declared
# fields still go through validation; anything else falls back to
# object.__setattr__ so browser-use's monkey-patching succeeds.
# ---------------------------------------------------------------------------

def _browser_safe_cls(base):
    """Create a Pydantic-model subclass that tolerates arbitrary setattr."""
    if base is None:
        return None

    class _Safe(base):  # type: ignore[valid-type]
        def __setattr__(self, name: str, value):
            try:
                super().__setattr__(name, value)
            except (ValueError, AttributeError):
                object.__setattr__(self, name, value)

    _Safe.__name__ = base.__name__
    _Safe.__qualname__ = base.__qualname__
    _Safe.__module__ = base.__module__
    return _Safe


try:
    BrowserChatOpenAI = _browser_safe_cls(_RawChatOpenAI)
except Exception:
    BrowserChatOpenAI = _RawChatOpenAI  # type: ignore[assignment,misc]

try:
    _SafeChatGroq = _browser_safe_cls(BrowserChatGroq)
    if _SafeChatGroq is not None:
        BrowserChatGroq = _SafeChatGroq  # type: ignore[misc]
except Exception:
    pass  # keep the raw BrowserChatGroq

try:
    _SafeChatOllama = _browser_safe_cls(ChatOllama)
    if _SafeChatOllama is not None:
        ChatOllama = _SafeChatOllama  # type: ignore[misc]
except Exception:
    pass  # keep the raw ChatOllama


CAPTCHA_SIGNALS = frozenset(
    [
        "captcha",
        "cloudflare",
        # Keep challenge-related checks specific; bare "challenge" causes
        # false positives in normal content ("research challenges", etc.).
        "cloudflare challenge",
        "managed challenge",
        "security challenge",
        "turnstile challenge",
        "challenge page",
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


def _is_captcha_final_output(text: str) -> bool:
    """Heuristic for final tool output: avoid false positives on real reports.

    Final research outputs often contain words like "challenges" or rich
    multi-section summaries. These should not be treated as CAPTCHA pages.
    """
    lower = text.lower()
    if len(lower) > 1200:
        return False
    if "final result" in lower or "research report" in lower:
        return False
    return _is_captcha_blocked(lower)


def _is_browser_launch_failure(text: str) -> bool:
    lower = text.lower()
    return any(signal in lower for signal in BROWSER_LAUNCH_SIGNALS)


_RATE_LIMIT_SIGNALS = ("rate_limit_exceeded", "429", "413", "tokens per minute")


def _is_rate_limit_error(text: str) -> bool:
    lower = text.lower()
    return any(s in lower for s in _RATE_LIMIT_SIGNALS)


class RateLimitError(RuntimeError):
    """Raised when the cloud LLM rejects requests due to token/rate limits."""


def _read_local_browser_timeout() -> int:
    """Return local browser timeout from env, with sane fallback bounds."""
    raw = os.environ.get("BROWSER_LOCAL_TIMEOUT_SECONDS", "").strip()
    try:
        value = int(raw) if raw else 300
    except ValueError:
        value = 300
    # Keep timeouts practical: avoid accidental 0/negative or runaway values.
    return max(30, min(value, 1800))


LOCAL_BROWSER_TIMEOUT_SECONDS = _read_local_browser_timeout()

# Minimal DOM attributes for cloud models — keeps page representations small
# enough for Groq's 8 000 TPM free-tier limit.
_CLOUD_INCLUDE_ATTRS = ["title", "aria-label", "placeholder", "alt", "name", "role"]

# Groq free-tier caps at 8 000 TPM.  The browser-use system prompt consumes
# ~3 000 tokens; leave the rest for the DOM snapshot + response.
_CLOUD_MAX_DOM_CHARS = 4000


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


# Groq models that browser-use cannot use reliably (tool_choice / send_action errors).
# Fall back to a known-working model for browser tasks.
_BROWSER_GROQ_FALLBACK = "meta-llama/llama-4-maverick-17b-128e-instruct"
_BROWSER_GROQ_SKIP_MODELS = frozenset({"meta-llama/llama-4-maverick-17b-128e-instruct"})


def _set_provider(llm, provider_name: str):
    """Inject a ``provider`` attribute for browser-use's ``Agent.__init__`` check.

    With our safe subclasses, plain ``setattr`` works because the overridden
    ``__setattr__`` falls back to ``object.__setattr__`` for non-field names.
    """
    if not hasattr(llm, "provider"):
        setattr(llm, "provider", provider_name)
    return llm


def _make_browser_llm(
    model_name: str,
    is_cloud: bool,
    groq_api_key: Optional[str],
    browser_use_api_key: Optional[str] = None,
    openrouter_api_key: Optional[str] = None,
):
    """Create the appropriate LLM instance for browser-use.

    Priority:
      1. ChatBrowserUse (BU 2.0) — when browser_use_api_key is provided and
         the library exposes the class.  Uses local Chromium with Browser Use's
         proprietary LLM, which is optimised for browser tasks.
      2. ChatOpenAI via OpenRouter — when openrouter_api_key is provided.
      3. ChatGroq  — when is_cloud=True and a Groq key is available.
      4. ChatOllama — local Ollama fallback.
    """
    if browser_use_api_key and _ChatBrowserUse is not None:
        logger.info("browse_web: using ChatBrowserUse (BU 2.0) with local Chromium")
        return _ChatBrowserUse(api_key=browser_use_api_key)
    if openrouter_api_key and BrowserChatOpenAI is not None:
        logger.info("browse_web: using OpenRouter model %r", model_name)
        llm = BrowserChatOpenAI(
            api_key=openrouter_api_key,
            base_url="https://openrouter.ai/api/v1",
            model=model_name,
        )
        return _set_provider(llm, "openrouter")
    if is_cloud and BrowserChatGroq and groq_api_key:
        if model_name in _BROWSER_GROQ_SKIP_MODELS:
            logger.info(
                "browse_web: %r has known browser-use issues on Groq; using %r",
                model_name,
                _BROWSER_GROQ_FALLBACK,
            )
            model_name = _BROWSER_GROQ_FALLBACK
        return _set_provider(
            BrowserChatGroq(model=model_name, api_key=groq_api_key), "groq"
        )
    return _set_provider(ChatOllama(model=model_name), "ollama")


async def run_local_browser_task(
    task: str,
    model_name: str,
    start_url: Optional[str] = None,
    timeout: float = LOCAL_BROWSER_TIMEOUT_SECONDS,
    is_cloud: bool = False,
    groq_api_key: Optional[str] = None,
    browser_use_api_key: Optional[str] = None,
    openrouter_api_key: Optional[str] = None,
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

    llm = _make_browser_llm(model_name, is_cloud, groq_api_key, browser_use_api_key, openrouter_api_key)
    browser = Browser(headless=False, chromium_sandbox=False, args=extra_args)

    agent_kwargs: dict = dict(
        task=full_task,
        llm=llm,
        browser=browser,
        # use_vision=not is_cloud,
    )
    if is_cloud or browser_use_api_key:
        agent_kwargs.update(
            include_attributes=_CLOUD_INCLUDE_ATTRS,
            max_clickable_elements_length=_CLOUD_MAX_DOM_CHARS,
            flash_mode=True,
            use_judge=False,
            max_failures=1,
        )
    agent = Agent(**agent_kwargs)

    try:
        history = await asyncio.wait_for(agent.run(), timeout=timeout)
        output: str = history.final_result() or ""

        if _is_captcha_final_output(output):
            raise CaptchaBlockedError(
                f"CAPTCHA/bot-detection in agent output: {output[:300]}"
            )

        return output

    except (CaptchaBlockedError, BrowserLaunchError, RateLimitError):
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
        msg = str(exc)
        lower = msg.lower()
        if _is_rate_limit_error(lower):
            raise RateLimitError(
                f"Cloud model rate/token limit exceeded — the page content "
                f"is too large for the free tier.  Try a local model or a "
                f"simpler page.  Detail: {msg[:300]}"
            ) from exc
        if _is_browser_launch_failure(lower):
            raise BrowserLaunchError(msg) from exc
        if _is_captcha_blocked(lower):
            raise CaptchaBlockedError(msg) from exc
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
    is_cloud: bool = False,
    groq_api_key: Optional[str] = None,
    browser_use_api_key: Optional[str] = None,
    openrouter_api_key: Optional[str] = None,
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
    llm = _make_browser_llm(model_name, is_cloud, groq_api_key, browser_use_api_key, openrouter_api_key)
    results: List[str] = []

    for i, task in enumerate(tasks):
        logger.info(
            "browse_web_with_session: task %d/%d in session '%s'",
            i + 1, len(tasks), session_name,
        )
        agent_kwargs: dict = dict(
            task=task,
            llm=llm,
            browser=browser,
            # use_vision=not is_cloud,
        )
        if is_cloud or browser_use_api_key:
            agent_kwargs.update(
                include_attributes=_CLOUD_INCLUDE_ATTRS,
                max_clickable_elements_length=_CLOUD_MAX_DOM_CHARS,
                flash_mode=True,
                use_judge=False,
                max_failures=1,
            )
        agent = Agent(**agent_kwargs)
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
            msg = str(exc)
            lower = msg.lower()
            if _is_rate_limit_error(lower):
                raise RateLimitError(
                    f"Cloud model rate/token limit exceeded — the page "
                    f"content is too large for the free tier.  Try a local "
                    f"model or a simpler page.  Detail: {msg[:300]}"
                ) from exc
            if _is_browser_launch_failure(lower):
                raise BrowserLaunchError(msg) from exc
            raise
        results.append(output)

    return results


async def close_local_browser_session(session_name: str = "default") -> None:
    """Stop and remove a named persistent browser session."""
    browser = _sessions.pop(session_name, None)
    if browser is not None:
        await browser.stop()
        logger.info("browse_web_with_session: closed session '%s'", session_name)
