import logging
import os
import re
from pathlib import Path

import requests as _requests
from langchain_ollama import ChatOllama
from langchain_groq import ChatGroq
from langchain_openai import ChatOpenAI
from langchain_core.language_models import BaseChatModel
from langgraph.prebuilt import create_react_agent
from langgraph.checkpoint.memory import MemorySaver
from langchain_core.tools import BaseTool
from tools.browser import set_local_model

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """You are Atom, an intelligent assistant running on AtomOS.

You have access to the tools listed below — use ONLY those tools.
Do NOT attempt to call any tool that is not explicitly provided.

TOOL SELECTION — read carefully:

  code_editor     — Opens a file or project directory in the GUI code
                    editor (Zed). ALWAYS use this for coding tasks before
                    making file changes. Pass the PROJECT DIRECTORY (not
                    individual files) so the user gets a full workspace.
                    Do NOT launch editors via terminal.

  terminal        — Run a shell command (/bin/bash). Use for package install,
                    scripts, git, compilation, and any CLI task.

If the user says "use the code editor" or "open in the editor", you MUST
call code_editor.

PATH RULES: Always use ~/path or /home/<user>/path for file paths.
Never use bare relative paths — the service CWD is NOT the user's home.

Never ask the user for API keys or credentials directly — the system
manages credential storage securely.

Be concise and direct. If no tools are needed, just answer the question.
"""

NUM_CTX = 8192
DEFAULT_MODEL = "meta-llama/llama-4-maverick-17b-128e-instruct"

OPENROUTER_MODELS = frozenset({
    "z-ai/glm-5",
    "moonshotai/kimi-k2.5",
    "qwen/qwen3.5-plus-02-15",
    "qwen/qwen3.5-35b-a3b",
})

_llm_cache: dict[str, BaseChatModel] = {}
_checkpointer = MemorySaver()


def _read_key_file(path: Path) -> str | None:
    """Try to read an API key from the first line of *path*."""
    try:
        line = path.read_text().splitlines()[0].strip()
        return line or None
    except (FileNotFoundError, IndexError, OSError):
        return None


def _get_groq_api_key() -> str | None:
    """Return the Groq API key, checking multiple sources.

    Order: GROQ_API_KEY env var → ~/.groq → /home/$SUDO_USER/.groq
    → scan /home/*/.groq.  The last step covers system services where
    $HOME doesn't match the real user's home directory.
    """
    env_key = os.environ.get("GROQ_API_KEY", "").strip()
    if env_key:
        return env_key

    key = _read_key_file(Path.home() / ".groq")
    if key:
        return key

    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        key = _read_key_file(Path("/home") / sudo_user / ".groq")
        if key:
            return key

    try:
        for entry in sorted(Path("/home").iterdir()):
            if entry.is_dir():
                key = _read_key_file(entry / ".groq")
                if key:
                    return key
    except OSError:
        pass

    return None


def _get_browser_use_api_key() -> str | None:
    """Return the Browser Use Cloud API key from ``~/.browser_use``.

    Resolution order: ``~/.browser_use`` → ``/home/$SUDO_USER/.browser_use``
    → scan ``/home/*/.browser_use``.
    """
    key = _read_key_file(Path.home() / ".browser_use")
    if key:
        return key

    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        key = _read_key_file(Path("/home") / sudo_user / ".browser_use")
        if key:
            return key

    try:
        for entry in sorted(Path("/home").iterdir()):
            if entry.is_dir():
                key = _read_key_file(entry / ".browser_use")
                if key:
                    return key
    except OSError:
        pass

    return None


def _get_openrouter_api_key() -> str | None:
    """Return the OpenRouter API key, checking multiple sources.

    Order: OPENROUTER_API_KEY env var → ~/.openrouter
    → /home/$SUDO_USER/.openrouter → scan /home/*/.openrouter.
    """
    env_key = os.environ.get("OPENROUTER_API_KEY", "").strip()
    if env_key:
        return env_key

    key = _read_key_file(Path.home() / ".openrouter")
    if key:
        return key

    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user:
        key = _read_key_file(Path("/home") / sudo_user / ".openrouter")
        if key:
            return key

    try:
        for entry in sorted(Path("/home").iterdir()):
            if entry.is_dir():
                key = _read_key_file(entry / ".openrouter")
                if key:
                    return key
    except OSError:
        pass

    return None


def _is_openrouter_model(model_name: str) -> bool:
    """Check if *model_name* should be routed through OpenRouter."""
    return model_name in OPENROUTER_MODELS


def _ollama_installed_models() -> list[str]:
    """Return the names of models currently installed in Ollama."""
    try:
        resp = _requests.get("http://localhost:11434/api/tags", timeout=5)
        if resp.ok:
            return [m["name"] for m in resp.json().get("models", [])]
    except Exception as exc:
        logger.debug("Could not query Ollama model list: %s", exc)
    return []


def _is_ollama_model(model_name: str) -> bool:
    """Check if *model_name* is available on the local Ollama instance."""
    return model_name in _ollama_installed_models()


_EMBEDDING_PATTERNS = ("embed",)


def _is_chat_capable(model_name: str) -> bool:
    """Heuristic: models whose name contains 'embed' are embedding-only."""
    lower = model_name.lower()
    return not any(pat in lower for pat in _EMBEDDING_PATTERNS)


def _resolve_model(requested: str) -> str:
    """Map *requested* to an available model name.

    Local Ollama models are preferred.  OpenRouter models are routed to
    OpenRouter when an API key is available.  Otherwise, if the model is
    not installed in Ollama, the name is returned unchanged for use with
    Groq (provided an API key exists).  When no backend can serve the
    model, the first chat-capable installed Ollama model is used as a
    last-resort fallback.

    Raises ValueError when a specific cloud model is requested but the
    required API key is missing — this prevents silent fallback to a
    local model that may lack tool-calling support.
    """
    if not requested or requested == "default":
        requested = DEFAULT_MODEL

    available = _ollama_installed_models()

    if requested in available:
        return requested

    if _is_openrouter_model(requested):
        if _get_openrouter_api_key():
            logger.info("Model %r is an OpenRouter model; will use OpenRouter.", requested)
            return requested
        raise ValueError(
            f"Model {requested!r} requires an OpenRouter API key. "
            f"Place your key in ~/.openrouter (first line of the file) "
            f"or set the OPENROUTER_API_KEY environment variable."
        )

    if _get_groq_api_key():
        logger.info("Model %r not on Ollama; will use Groq cloud.", requested)
        return requested

    chat_models = [m for m in available if _is_chat_capable(m)]
    if chat_models:
        fallback = chat_models[0]
        logger.warning(
            "Model %r is not installed in Ollama and no Groq API key found "
            "(checked $GROQ_API_KEY, ~/.groq, /home/*/.groq). "
            "Falling back to %r.",
            requested,
            fallback,
        )
        return fallback

    return requested


def _get_llm(model_name: str) -> BaseChatModel:
    if model_name not in _llm_cache:
        if _is_ollama_model(model_name):
            _llm_cache[model_name] = ChatOllama(model=model_name, num_ctx=NUM_CTX)
        elif _is_openrouter_model(model_name):
            api_key = _get_openrouter_api_key()
            if not api_key:
                raise ValueError(
                    f"Model {model_name!r} requires an OpenRouter API key. "
                    f"Place your key in ~/.openrouter or set OPENROUTER_API_KEY."
                )
            _llm_cache[model_name] = ChatOpenAI(
                api_key=api_key,
                base_url="https://openrouter.ai/api/v1",
                model=model_name,
            )
        else:
            api_key = _get_groq_api_key()
            if not api_key:
                logger.warning(
                    "No Groq API key (~/.groq); falling back to ChatOllama for %r",
                    model_name,
                )
                _llm_cache[model_name] = ChatOllama(model=model_name, num_ctx=NUM_CTX)
            else:
                _llm_cache[model_name] = ChatGroq(
                    model=model_name, api_key=api_key
                )
    return _llm_cache[model_name]


# browser-use needs a model large enough to parse page structure and emit
# structured JSON actions — 350M-class models can't do this.
BROWSER_MIN_PARAMS_B = 3.0

# Groq models that browser-use cannot use reliably (tool_choice / search_page /
# send_action errors). Fall back to a known-working model for browser tasks.
BROWSER_GROQ_SKIP_MODELS = frozenset({"openai/gpt-oss-20b", "openai/gpt-oss-120b"})
BROWSER_GROQ_FALLBACK = "meta-llama/llama-4-maverick-17b-128e-instruct"


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
    """Pick the best model for browser-use tasks.

    Cloud models (Groq) are assumed large enough.  Local models are only
    overridden when their size is *known* to be below the minimum — unknown
    sizes get the benefit of the doubt so the user's selection is respected.

    Some Groq models (gpt-oss-20b, gpt-oss-120b) cause tool validation errors
    with browser-use (search_page/send_action not in request.tools). Those
    are replaced with a known-working fallback.
    """
    if not _is_ollama_model(agent_model):
        if agent_model in BROWSER_GROQ_SKIP_MODELS and _get_groq_api_key():
            logger.info(
                "Model %r has known browser-use issues on Groq; using %r for browser tasks",
                agent_model,
                BROWSER_GROQ_FALLBACK,
            )
            return BROWSER_GROQ_FALLBACK
        return agent_model

    size = _parse_model_size_b(agent_model)

    if size is None or size >= BROWSER_MIN_PARAMS_B:
        return agent_model

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

    if _get_groq_api_key():
        logger.info(
            "No large Ollama model available; using Groq default %r for browser-use",
            DEFAULT_MODEL,
        )
        return DEFAULT_MODEL

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

    is_cloud = not _is_ollama_model(browser_model)
    is_openrouter = _is_openrouter_model(browser_model)
    set_local_model(
        browser_model,
        is_cloud=is_cloud,
        groq_api_key=_get_groq_api_key() if is_cloud and not is_openrouter else None,
        openrouter_api_key=_get_openrouter_api_key() if is_openrouter else None,
    )

    logger.info(
        "Agent for query: model=%r resolved=%r cloud=%s openrouter=%s tools=%s thread=%s",
        model_name,
        resolved,
        is_cloud,
        is_openrouter,
        [getattr(t, "name", "?") for t in tools],
        thread_id,
    )

    llm = _get_llm(resolved)
    return create_react_agent(
        model=llm,
        tools=tools,
        prompt=SYSTEM_PROMPT,
        checkpointer=_checkpointer,
    )
