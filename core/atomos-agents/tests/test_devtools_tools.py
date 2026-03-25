"""
Tests for the devtools tools (tools/devtools.py).

Covers:
  - Tool registration and discovery via get_devtools_tools()
  - Tool names, descriptions, and argument schemas
  - Handler invocation round-trip (mock ChromeDevToolsClient)
  - Error handling when chrome-devtools-mcp-fork is unavailable
  - Integration with tool_registry allowed-tools list
  - Browser-use coordination (shared CDP port)
"""

import json
import sys
import types as builtin_types
import pytest
from unittest.mock import MagicMock, patch


# ── helpers ────────────────────────────────────────────────────────────────


def _make_cdp_response(result_value, *, as_string=False):
    """Build a mock CDP Runtime.evaluate response."""
    value = json.dumps(result_value) if as_string else result_value
    return {
        "result": {
            "result": {
                "type": "string" if as_string else type(result_value).__name__,
                "value": value,
            }
        }
    }


def _make_cdp_error(message: str):
    """Build a mock CDP error response."""
    return {"error": {"code": -32000, "message": message}}


def _make_cdp_exception(text: str, description: str = ""):
    """Build a mock CDP Runtime.evaluate response with an exception."""
    resp = {
        "result": {
            "exceptionDetails": {
                "text": text,
                "exception": {"description": description},
            }
        }
    }
    return resp


def _install_fake_devtools_module():
    """Inject a fake chrome_devtools_mcp_fork package into sys.modules."""
    pkg = builtin_types.ModuleType("chrome_devtools_mcp_fork")
    client_mod = builtin_types.ModuleType("chrome_devtools_mcp_fork.client")

    mock_client_cls = MagicMock()
    mock_instance = MagicMock()
    mock_instance.is_connected.return_value = True
    mock_instance.connect.return_value = True
    mock_instance._send_command.return_value = None
    mock_client_cls.return_value = mock_instance
    client_mod.ChromeDevToolsClient = mock_client_cls

    pkg.client = client_mod
    pkg.__version__ = "2.0.1"
    sys.modules["chrome_devtools_mcp_fork"] = pkg
    sys.modules["chrome_devtools_mcp_fork.client"] = client_mod
    return client_mod, mock_client_cls, mock_instance


def _uninstall_fake_devtools_module():
    sys.modules.pop("chrome_devtools_mcp_fork", None)
    sys.modules.pop("chrome_devtools_mcp_fork.client", None)


def _reset_module_state():
    """Reset the devtools module's cached singleton and tools list."""
    import tools.devtools as mod
    mod._client = None
    mod._DEVTOOLS_TOOLS = None


# ── tool registration ─────────────────────────────────────────────────────


class TestDevtoolsToolRegistration:

    def test_get_devtools_tools_returns_six_tools(self):
        _install_fake_devtools_module()
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.get_devtools_tools()
            assert len(result) == 6
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()

    def test_tool_names_are_namespaced(self):
        _install_fake_devtools_module()
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.get_devtools_tools()
            names = {t.name for t in result}
            assert names == {
                "devtools_connect",
                "devtools_execute_javascript",
                "devtools_get_page_info",
                "devtools_get_network_requests",
                "devtools_get_console_logs",
                "devtools_get_dom",
            }
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()

    def test_connect_tool_has_port_arg(self):
        from tools.devtools import devtools_connect
        schema = devtools_connect.args_schema
        if schema:
            assert "port" in schema.model_fields

    def test_execute_js_tool_has_code_arg(self):
        from tools.devtools import devtools_execute_javascript
        schema = devtools_execute_javascript.args_schema
        if schema:
            assert "code" in schema.model_fields

    def test_get_dom_tool_has_depth_arg(self):
        from tools.devtools import devtools_get_dom
        schema = devtools_get_dom.args_schema
        if schema:
            assert "depth" in schema.model_fields

    def test_graceful_when_package_missing(self):
        """get_devtools_tools returns [] when chrome-devtools-mcp-fork
        is not installed."""
        _uninstall_fake_devtools_module()
        import tools.devtools as mod
        _reset_module_state()
        result = mod.get_devtools_tools()
        assert result == []
        _reset_module_state()

    def test_caches_tool_list(self):
        _install_fake_devtools_module()
        try:
            import tools.devtools as mod
            _reset_module_state()
            first = mod.get_devtools_tools()
            second = mod.get_devtools_tools()
            assert first is second
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()


# ── devtools_connect ──────────────────────────────────────────────────────


class TestDevtoolsConnect:

    def test_connect_success(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = False
        mock_instance.connect.return_value = True
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_connect.invoke({"port": 9222})
            assert "Connected" in result
            mock_instance.connect.assert_called_with(9222)
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()

    def test_connect_already_connected(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_connect.invoke({"port": 9222})
            assert "Already connected" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()

    def test_connect_failure(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = False
        mock_instance.connect.return_value = False
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_connect.invoke({"port": 9222})
            assert "Failed" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()


# ── devtools_execute_javascript ───────────────────────────────────────────


class TestDevtoolsExecuteJavascript:

    def test_returns_evaluated_value(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        mock_instance._send_command.return_value = _make_cdp_response(42)
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_execute_javascript.invoke({"code": "1 + 1"})
            assert "42" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()

    def test_returns_js_error(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        mock_instance._send_command.return_value = _make_cdp_exception(
            "Uncaught ReferenceError", "x is not defined"
        )
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_execute_javascript.invoke({"code": "x"})
            assert "JavaScript error" in result
            assert "not defined" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()

    def test_returns_undefined(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        mock_instance._send_command.return_value = {
            "result": {"result": {"type": "undefined"}}
        }
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_execute_javascript.invoke({"code": "void 0"})
            assert result == "(undefined)"
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()

    def test_not_connected_auto_connects(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.side_effect = [False, True]
        mock_instance.connect.return_value = True
        mock_instance._send_command.return_value = _make_cdp_response("hello")
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_execute_javascript.invoke({"code": "'hello'"})
            mock_instance.connect.assert_called_once()
            assert "hello" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()


# ── devtools_get_page_info ────────────────────────────────────────────────


class TestDevtoolsGetPageInfo:

    def test_returns_page_data(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        page_data = {
            "url": "https://example.com",
            "title": "Example",
            "readyState": "complete",
        }
        mock_instance._send_command.return_value = _make_cdp_response(
            json.dumps(page_data), as_string=True
        )
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_get_page_info.invoke({})
            assert "example.com" in result
            assert "Example" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()


# ── devtools_get_network_requests ─────────────────────────────────────────


class TestDevtoolsGetNetworkRequests:

    def test_returns_entries(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        entries = [
            {"name": "https://cdn.example.com/app.js", "type": "script",
             "duration": 120, "transferSize": 45000, "startTime": 50},
        ]
        mock_instance._send_command.return_value = _make_cdp_response(
            json.dumps(entries), as_string=True
        )
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_get_network_requests.invoke({"limit": 10})
            assert "app.js" in result
            assert "script" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()

    def test_empty_entries(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        mock_instance._send_command.return_value = _make_cdp_response(
            "[]", as_string=True
        )
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_get_network_requests.invoke({"limit": 10})
            assert "no network requests" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()


# ── devtools_get_console_logs ─────────────────────────────────────────────


class TestDevtoolsGetConsoleLogs:

    def test_first_call_activates_collector(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        mock_instance._send_command.return_value = _make_cdp_response(
            "[]", as_string=True
        )
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_get_console_logs.invoke({"limit": 50})
            assert "collector is now active" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()

    def test_returns_captured_logs(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        logs = [{"level": "error", "message": "404 not found", "timestamp": 1000}]
        mock_instance._send_command.return_value = _make_cdp_response(
            json.dumps(logs), as_string=True
        )
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_get_console_logs.invoke({"limit": 10})
            assert "404 not found" in result
            assert "error" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()


# ── devtools_get_dom ──────────────────────────────────────────────────────


class TestDevtoolsGetDom:

    def test_returns_dom_tree(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        dom_tree = {
            "nodeId": 1,
            "nodeName": "#document",
            "children": [
                {"nodeId": 2, "nodeName": "HTML", "localName": "html"}
            ],
        }
        mock_instance._send_command.return_value = {
            "result": {"root": dom_tree}
        }
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_get_dom.invoke({"depth": 2})
            assert "#document" in result
            assert "html" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()

    def test_empty_dom(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        mock_instance._send_command.return_value = {"result": {"root": {}}}
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_get_dom.invoke({"depth": 1})
            assert result == "(empty DOM)"
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()

    def test_cdp_error(self):
        _, _, mock_instance = _install_fake_devtools_module()
        mock_instance.is_connected.return_value = True
        mock_instance._send_command.return_value = _make_cdp_error(
            "DOM agent not enabled"
        )
        try:
            import tools.devtools as mod
            _reset_module_state()
            result = mod.devtools_get_dom.invoke({"depth": 1})
            assert "CDP error" in result
        finally:
            _uninstall_fake_devtools_module()
            _reset_module_state()


# ── _extract_js_value round-trip ──────────────────────────────────────────


class TestExtractJsValue:

    def test_none_response(self):
        from tools.devtools import _extract_js_value
        assert _extract_js_value(None) == "(no response from browser)"

    def test_cdp_error_response(self):
        from tools.devtools import _extract_js_value
        result = _extract_js_value(_make_cdp_error("timeout"))
        assert "CDP error" in result
        assert "timeout" in result

    def test_string_value_parsed_as_json(self):
        from tools.devtools import _extract_js_value
        data = {"key": "value"}
        resp = _make_cdp_response(json.dumps(data), as_string=True)
        result = _extract_js_value(resp)
        parsed = json.loads(result)
        assert parsed["key"] == "value"

    def test_plain_string_value(self):
        from tools.devtools import _extract_js_value
        resp = _make_cdp_response("hello world", as_string=True)
        result = _extract_js_value(resp)
        assert "hello world" in result

    def test_numeric_value(self):
        from tools.devtools import _extract_js_value
        resp = _make_cdp_response(3.14)
        result = _extract_js_value(resp)
        assert "3.14" in result


# ── tool_registry integration ─────────────────────────────────────────────


class TestRegistryIntegration:

    def test_devtools_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS

        assert "devtools_connect" in _ALLOWED_EXPOSED_TOOLS
        assert "devtools_execute_javascript" in _ALLOWED_EXPOSED_TOOLS
        assert "devtools_get_page_info" in _ALLOWED_EXPOSED_TOOLS
        assert "devtools_get_network_requests" in _ALLOWED_EXPOSED_TOOLS
        assert "devtools_get_console_logs" in _ALLOWED_EXPOSED_TOOLS
        assert "devtools_get_dom" in _ALLOWED_EXPOSED_TOOLS


# ── browser-use coordination ──────────────────────────────────────────────


class TestBrowserUseCoordination:

    def test_default_port_matches_browser_use(self):
        """The default CDP port should be 9222 — same as browser-use."""
        from tools.devtools import _get_debug_port
        assert _get_debug_port() == 9222

    def test_port_from_env(self):
        from tools.devtools import _get_debug_port
        with patch.dict("os.environ", {"CHROME_DEBUG_PORT": "9333"}):
            assert _get_debug_port() == 9333
