# Atom OS Agents (`atomos-agents`)

## Overview
The Python half of the AI system, leveraging LangChain primitives. This is a gRPC server that listens for agent invocations from the `atomos-bridge`.

## Deep Agents Integration
It exposes the `create_deep_agent` factory builder:
- **Middleware:** Implements memory, summarization, tool injection, and human-in-the-loop loops.
- **Subagents:** Prepares specific sub-agent instances (Research, Code, Automation) depending on user routing.
- **Tools:** Exposes OS-level tools like filesystem access, MCP integrations, browser drivers, and raw SurrealDB querying (scoped to safety).

## Usage
Run the server locally:
```bash
python -m atomos_agents.main
```

---

## Adding a New Tool Package

Every external tool integration follows the same four-step pattern.
Shared utilities in `src/tools/_shared.py` eliminate boilerplate across
packages.

### Step 1 — Add the dependency

Add the package to `pyproject.toml` under `[project] dependencies`:

```toml
dependencies = [
    # ... existing deps ...
    "my-tool-package>=1.0.0",
]
```

### Step 2 — Create the tool module

Create `src/tools/<namespace>.py`.  Import handler functions from the
package and wrap each as a LangChain `@tool` with the `<namespace>_`
prefix.  Use the shared helpers where applicable:

```python
from tools._shared import (
    call_mcp_handler,    # MCP TextContent extraction
    parse_json_param,    # JSON string → Python object
    resolve_api_key,     # env var → dotfile → home scan
    format_result,       # dict/None → JSON string / placeholder
)
```

Every module must expose a `get_<namespace>_tools()` function that:
- Returns a list of `@tool`-decorated callables
- Gracefully returns `[]` if the underlying package is not installed
- Caches the result in a module-level `_<NAMESPACE>_TOOLS` variable

Example skeleton:

```python
from langchain_core.tools import tool

@tool
def myns_do_thing(arg: str) -> str:
    """One-line description shown to the agent."""
    from my_tool_package import do_thing
    return do_thing(arg)

_MYNS_TOOLS = None

def get_myns_tools() -> list:
    global _MYNS_TOOLS
    if _MYNS_TOOLS is not None:
        return _MYNS_TOOLS
    try:
        import my_tool_package  # noqa: F401
        _MYNS_TOOLS = [myns_do_thing]
    except ImportError:
        _MYNS_TOOLS = []
    return _MYNS_TOOLS
```

### Step 3 — Wire into `skills.py` and the registry

Add the package to the `_TOOL_PACKAGES` list in `src/tools/skills.py`:

```python
_TOOL_PACKAGES: list[tuple[str, str, str]] = [
    # ... existing entries ...
    ("myns", "tools.myns", "get_myns_tools"),
]
```

Add every tool name to `_ALLOWED_EXPOSED_TOOLS` in `src/tool_registry.py`:

```python
_ALLOWED_EXPOSED_TOOLS = frozenset({
    # ... existing tools ...
    "myns_do_thing",
})
```

### Step 4 — Add agent guidance

Add a section to `SYSTEM_PROMPT` in `src/agent_factory.py` describing
when and how the agent should use the new tools.

### Shared utilities (`src/tools/_shared.py`)

| Helper | Purpose |
|---|---|
| `call_mcp_handler(handler, args)` | Await an MCP handler, extract `.text` from `TextContent` results |
| `parse_json_param(raw, name)` | Parse a JSON string param; returns `None` for empty, raises `ValueError` for invalid |
| `resolve_api_key(env_var, dotfile)` | Resolve a secret from `$ENV_VAR` → `~/.<dotfile>` → `/home/*/<dotfile>` |
| `format_result(obj)` | Format an API response as indented JSON, or `"(no results)"` / `"(empty response)"` |
| `is_tool_package_disabled(ns)` | Check if `ATOMOS_TOOLS_DISABLE_<NS>=1` is set |

### Disabling a tool package at runtime

Set `ATOMOS_TOOLS_DISABLE_<NAMESPACE>=1` to prevent a package from
loading:

```bash
ATOMOS_TOOLS_DISABLE_ARXIV=1        # skip arxiv tools
ATOMOS_TOOLS_DISABLE_NOTION=true    # skip notion tools
```

### Namespace collision detection

At startup, `discover_all_tools()` checks that no two tool packages
from different sources register the same tool name.  If a collision is
detected, a `ToolNamespaceCollisionError` is raised with both package
names and a reminder to use unique namespace prefixes.
