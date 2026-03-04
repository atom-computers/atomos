import logging
import re

import requests as _requests
from langchain_ollama import ChatOllama
from langgraph.prebuilt import create_react_agent
from langchain_core.tools import BaseTool
from tools.browser import set_local_model

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are Atom, an intelligent assistant running on AtomOS.
You have access to tools that let you:
- Search and read files on the user's filesystem
- Query the context manager for project summaries and AI-indexed information
- Check sync status of files
- Browse the web and automate browser tasks (browse_web, browse_web_with_session)

When asked to find online information, interact with websites, or automate
web workflows, use the browse_web tools. For tasks that need login state
across multiple steps, use browse_web_with_session.

Never ask the user for API keys or credentials directly — the system
manages credential storage securely. If a cloud browser key is needed,
the system will prompt the user through the appropriate UI.

Be concise and direct. If no tools are needed, just answer the question.
"""

NUM_CTX = 8192

_resolution_cache: dict[str, str] = {}
_llm_cache: dict[str, ChatOllama] = {}


def _ollama_installed_models() -> list[str]:
    """Return the names of models currently installed in Ollama."""
    try:
        resp = _requests.get("http://localhost:11434/api/tags", timeout=5)
        if resp.ok:
            return [m["name"] for m in resp.json().get("models", [])]
    except Exception as exc:
        logger.debug("Could not query Ollama model list: %s", exc)
    return []


def _resolve_model(requested: str) -> str:
    """Map *requested* to an installed Ollama model name.

    If *requested* exists locally it is returned unchanged.  If it is not
    installed (e.g. the applet's settings.ron still references an old model
    that was deleted), the first available model is used instead and a
    warning is logged so the mismatch is visible in journalctl.

    Results are cached for the lifetime of the process so we only hit the
    Ollama tags API once per distinct model name.
    """
    if requested in _resolution_cache:
        return _resolution_cache[requested]

    available = _ollama_installed_models()

    if not available:
        _resolution_cache[requested] = requested
        return requested

    if requested in available:
        _resolution_cache[requested] = requested
        return requested

    fallback = available[0]
    logger.warning(
        "Model %r is not installed in Ollama (installed: %s). "
        "Falling back to %r.",
        requested,
        available,
        fallback,
    )
    _resolution_cache[requested] = fallback
    return fallback


def _get_llm(model_name: str) -> ChatOllama:
    if model_name not in _llm_cache:
        _llm_cache[model_name] = ChatOllama(model=model_name, num_ctx=NUM_CTX)
    return _llm_cache[model_name]


# browser-use needs a model large enough to parse page structure and emit
# structured JSON actions — 350M-class models can't do this.
BROWSER_MIN_PARAMS_B = 3.0


def _parse_model_size_b(model_name: str) -> float | None:
    """Extract approximate parameter count (in billions) from an Ollama model name.

    Returns None when the size cannot be determined from the name alone.
    """
    parts = model_name.split(":")
    tag = parts[1] if len(parts) > 1 else parts[0]
    match = re.search(r"(\d+(?:\.\d+)?)\s*(m|b)\b", tag, re.IGNORECASE)
    if match:
        value = float(match.group(1))
        return value / 1000.0 if match.group(2).lower() == "m" else value
    return None


def _resolve_browser_model(agent_model: str) -> str:
    """Pick the best installed Ollama model for browser-use tasks.

    If *agent_model* is large enough, it is returned unchanged.  Otherwise
    the smallest installed model that meets BROWSER_MIN_PARAMS_B is chosen.
    """
    size = _parse_model_size_b(agent_model)
    if size is not None and size >= BROWSER_MIN_PARAMS_B:
        return agent_model

    if size is not None:
        logger.warning(
            "Model %r (~%.1fB params) is too small for browser-use "
            "(minimum %.1fB). Searching for a larger installed model…",
            agent_model, size, BROWSER_MIN_PARAMS_B,
        )

    available = _ollama_installed_models()
    candidates = []
    for m in available:
        m_size = _parse_model_size_b(m)
        if m_size is not None and m_size >= BROWSER_MIN_PARAMS_B:
            candidates.append((m_size, m))

    if candidates:
        candidates.sort()
        chosen_size, chosen = candidates[0]
        logger.info(
            "Auto-selected %r (~%.1fB) for browser-use tasks",
            chosen, chosen_size,
        )
        return chosen

    logger.warning(
        "No installed Ollama model meets the %.1fB minimum for browser-use. "
        "Browser tasks will likely fail or time out with %r.",
        BROWSER_MIN_PARAMS_B, agent_model,
    )
    return agent_model


def create_agent_for_query(
    model_name: str,
    tools: list[BaseTool],
    thread_id: str = "default",
):
    """Build a lightweight react agent with only the given tools.

    Unlike the previous create_deep_agent approach, this does NOT inject
    deepagents' 9 built-in tools (~17K chars of descriptions) into every
    prompt.  Only the RAG-selected tools are bound, keeping the prompt
    small enough for lightweight models.
    """
    resolved = _resolve_model(model_name)
    browser_model = _resolve_browser_model(resolved)
    set_local_model(browser_model)

    logger.info(
        "Agent for query: model=%r resolved=%r tools=%s thread=%s",
        model_name,
        resolved,
        [getattr(t, "name", "?") for t in tools],
        thread_id,
    )

    llm = _get_llm(resolved)
    return create_react_agent(
        model=llm,
        tools=tools,
        prompt=SYSTEM_PROMPT,
    )
