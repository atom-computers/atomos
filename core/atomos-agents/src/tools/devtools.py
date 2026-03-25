"""Chrome DevTools debugging tools for atomos-agents.

Wraps the ``ChromeDevToolsClient`` from the ``chrome-devtools-mcp-fork``
package as LangChain tools so the agent can inspect pages, execute
JavaScript, read console logs, and analyse network/performance data.

Coordinates with browser-use (REQ-3.3.1): both connect to the *same*
Chromium instance via CDP.  The default debug port (9222) matches the
browser-use configuration, so devtools and browser-use share one browser
without conflicting sessions.
"""

import json
import logging
import os
from typing import Optional

from langchain_core.tools import tool

logger = logging.getLogger(__name__)

_client = None


def _get_debug_port() -> int:
    return int(os.environ.get("CHROME_DEBUG_PORT", "9222"))


def _get_client():
    """Return (or create) the shared ChromeDevToolsClient singleton."""
    global _client
    if _client is None:
        from chrome_devtools_mcp_fork.client import ChromeDevToolsClient

        _client = ChromeDevToolsClient()
    return _client


def _ensure_connected() -> str | None:
    """Auto-connect if not already connected.

    Returns an error string on failure, ``None`` on success.
    """
    client = _get_client()
    if client.is_connected():
        return None
    port = _get_debug_port()
    if client.connect(port):
        return None
    return (
        f"Not connected to Chrome.  Ensure Chromium is running with "
        f"--remote-debugging-port={port}."
    )


def _cdp(method: str, params: dict | None = None) -> dict | None:
    """Send a raw CDP command and return the parsed JSON response."""
    client = _get_client()
    return client._send_command(method, params or {})


def _eval_js(expression: str) -> dict | None:
    """Shortcut for ``Runtime.evaluate`` with common flags."""
    return _cdp("Runtime.evaluate", {
        "expression": expression,
        "returnByValue": True,
        "awaitPromise": True,
    })


def _extract_js_value(result: dict | None) -> str:
    """Extract a human-readable string from a Runtime.evaluate response."""
    if result is None:
        return "(no response from browser)"
    if "error" in result:
        return f"CDP error: {json.dumps(result['error'])}"
    inner = result.get("result", {})
    exc = inner.get("exceptionDetails")
    if exc:
        text = exc.get("text", "")
        desc = exc.get("exception", {}).get("description", "")
        return f"JavaScript error: {text} {desc}".strip()
    val = inner.get("result", {})
    if val.get("type") == "undefined":
        return "(undefined)"
    raw = val.get("value", val)
    if isinstance(raw, str):
        try:
            parsed = json.loads(raw)
            return json.dumps(parsed, indent=2)
        except (json.JSONDecodeError, TypeError):
            return raw
    return json.dumps(raw, indent=2, default=str)


# ── tools ──────────────────────────────────────────────────────────────────


@tool
def devtools_connect(port: int = 9222) -> str:
    """Connect to a running Chrome/Chromium instance via DevTools Protocol.

    Uses the same Chromium instance as browser-use.  The default port
    (9222) matches the standard CDP debug port.
    """
    client = _get_client()
    if client.is_connected():
        return "Already connected to Chrome DevTools."
    if client.connect(port):
        return f"Connected to Chrome DevTools on port {port}."
    return (
        f"Failed to connect on port {port}.  "
        f"Ensure Chromium is running with --remote-debugging-port={port}."
    )


@tool
def devtools_execute_javascript(code: str) -> str:
    """Execute JavaScript in the browser page context and return the result.

    Useful for inspecting application state, modifying the DOM, or running
    diagnostic code.
    """
    err = _ensure_connected()
    if err:
        return err
    return _extract_js_value(_eval_js(code))


@tool
def devtools_get_page_info() -> str:
    """Get current page URL, title, performance timing, and resource counts."""
    err = _ensure_connected()
    if err:
        return err
    js = """(function() {
        var t = performance.timing;
        return JSON.stringify({
            url: location.href,
            title: document.title,
            readyState: document.readyState,
            timing: {
                domContentLoaded: t.domContentLoadedEventEnd - t.navigationStart,
                load: t.loadEventEnd - t.navigationStart,
                firstByte: t.responseStart - t.navigationStart,
                domInteractive: t.domInteractive - t.navigationStart
            },
            resources: performance.getEntriesByType('resource').length,
            scripts: document.scripts.length,
            stylesheets: document.styleSheets.length
        });
    })()"""
    return _extract_js_value(_eval_js(js))


@tool
def devtools_get_network_requests(limit: int = 50) -> str:
    """Get recent network requests (resource timing entries) from the page.

    Returns URL, type, duration, and transfer size for each resource.
    """
    err = _ensure_connected()
    if err:
        return err
    js = f"""(function() {{
        var entries = performance.getEntriesByType('resource').slice(-{limit});
        return JSON.stringify(entries.map(function(e) {{
            return {{
                name: e.name,
                type: e.initiatorType,
                duration: Math.round(e.duration),
                transferSize: e.transferSize || 0,
                startTime: Math.round(e.startTime)
            }};
        }}));
    }})()"""
    result = _extract_js_value(_eval_js(js))
    if result == "[]":
        return "(no network requests recorded)"
    return result


@tool
def devtools_get_console_logs(limit: int = 50) -> str:
    """Retrieve recent console messages from the browser.

    Injects a collector on the first call, then reads captured messages.
    The first invocation may return empty while the collector activates.
    """
    err = _ensure_connected()
    if err:
        return err
    js = f"""(function() {{
        if (!window.__atomos_console_logs) {{
            window.__atomos_console_logs = [];
            var orig = {{}};
            ['log','warn','error','info','debug'].forEach(function(level) {{
                orig[level] = console[level];
                console[level] = function() {{
                    var args = Array.prototype.slice.call(arguments);
                    window.__atomos_console_logs.push({{
                        level: level,
                        message: args.map(function(a) {{
                            try {{
                                return typeof a === 'object' ? JSON.stringify(a) : String(a);
                            }} catch(e) {{ return String(a); }}
                        }}).join(' '),
                        timestamp: Date.now()
                    }});
                    if (window.__atomos_console_logs.length > 200)
                        window.__atomos_console_logs.shift();
                    orig[level].apply(console, arguments);
                }};
            }});
            return JSON.stringify([]);
        }}
        var logs = window.__atomos_console_logs.slice(-{limit});
        return JSON.stringify(logs);
    }})()"""
    result = _extract_js_value(_eval_js(js))
    if result == "[]":
        return "(no console messages captured yet — collector is now active)"
    return result


@tool
def devtools_get_dom(depth: int = 3) -> str:
    """Get the DOM document tree up to the specified depth.

    Returns a simplified structure showing tag names, attributes, and
    nesting.  Useful for understanding page layout without a screenshot.
    """
    err = _ensure_connected()
    if err:
        return err
    result = _cdp("DOM.getDocument", {"depth": depth})
    if result is None:
        return "(no response from browser)"
    if "error" in result:
        return f"CDP error: {json.dumps(result['error'])}"
    root = result.get("result", {}).get("root", {})
    if not root:
        return "(empty DOM)"
    return json.dumps(root, indent=2, default=str)


# ── registration helper ───────────────────────────────────────────────────

_DEVTOOLS_TOOLS = None


def get_devtools_tools() -> list:
    """Return all devtools tools.  Returns ``[]`` if the
    ``chrome-devtools-mcp-fork`` package is not installed."""
    global _DEVTOOLS_TOOLS
    if _DEVTOOLS_TOOLS is not None:
        return _DEVTOOLS_TOOLS

    try:
        import chrome_devtools_mcp_fork  # noqa: F401 — verify importable

        _DEVTOOLS_TOOLS = [
            devtools_connect,
            devtools_execute_javascript,
            devtools_get_page_info,
            devtools_get_network_requests,
            devtools_get_console_logs,
            devtools_get_dom,
        ]
    except ImportError:
        logger.warning(
            "chrome-devtools-mcp-fork not installed — devtools tools unavailable.  "
            "Install with: pip install 'chrome-devtools-mcp-fork>=2.0.0'"
        )
        _DEVTOOLS_TOOLS = []

    return _DEVTOOLS_TOOLS
