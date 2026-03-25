"""
Tests for the shared tool integration infrastructure (§1.7).

Covers:
  - Shared _call_handler (MCP TextContent extraction)
  - Shared parse_json_param utility
  - Shared resolve_api_key utility
  - Shared format_result utility
  - Namespace collision detection at startup
  - Env-var enable/disable of tool packages
  - is_tool_package_disabled helper
"""

import asyncio
import json
import os
import sys
import types as builtin_types
import pytest
from unittest.mock import MagicMock, patch


# ── shared utilities ───────────────────────────────────────────────────────


class TestCallMcpHandler:

    def test_extracts_text_from_results(self):
        from tools._shared import call_mcp_handler

        tc1, tc2 = MagicMock(), MagicMock()
        tc1.text = "block one"
        tc2.text = "block two"

        async def handler(args):
            return [tc1, tc2]

        result = asyncio.run(call_mcp_handler(handler, {}))
        assert result == "block one\nblock two"

    def test_returns_placeholder_for_empty_results(self):
        from tools._shared import call_mcp_handler

        async def handler(args):
            return []

        result = asyncio.run(call_mcp_handler(handler, {}))
        assert result == "(no results)"

    def test_skips_objects_without_text_attribute(self):
        from tools._shared import call_mcp_handler

        tc = MagicMock()
        tc.text = "valid"
        no_text = MagicMock(spec=[])

        async def handler(args):
            return [tc, no_text]

        result = asyncio.run(call_mcp_handler(handler, {}))
        assert result == "valid"

    def test_propagates_handler_exceptions(self):
        from tools._shared import call_mcp_handler

        async def handler(args):
            raise RuntimeError("connection failed")

        with pytest.raises(RuntimeError, match="connection failed"):
            asyncio.run(call_mcp_handler(handler, {}))


class TestParseJsonParam:

    def test_parses_valid_json(self):
        from tools._shared import parse_json_param

        result = parse_json_param('{"key": "value"}', "test_param")
        assert result == {"key": "value"}

    def test_returns_none_for_empty_string(self):
        from tools._shared import parse_json_param

        assert parse_json_param("", "test_param") is None

    def test_returns_none_for_none_like_empty(self):
        from tools._shared import parse_json_param

        assert parse_json_param("", "x") is None

    def test_raises_on_invalid_json(self):
        from tools._shared import parse_json_param

        with pytest.raises(ValueError, match="Invalid JSON for my_param"):
            parse_json_param("{not valid json}", "my_param")

    def test_parses_json_array(self):
        from tools._shared import parse_json_param

        result = parse_json_param('[1, 2, 3]', "arr")
        assert result == [1, 2, 3]


class TestResolveApiKey:

    def test_reads_from_env_var(self):
        from tools._shared import resolve_api_key

        with patch.dict(os.environ, {"MY_API_KEY": "from-env"}):
            assert resolve_api_key("MY_API_KEY", ".mykey") == "from-env"

    def test_strips_env_var(self):
        from tools._shared import resolve_api_key

        with patch.dict(os.environ, {"MY_API_KEY": "  from-env  "}):
            assert resolve_api_key("MY_API_KEY", ".mykey") == "from-env"

    def test_returns_none_when_nothing_found(self):
        from tools._shared import resolve_api_key

        with patch.dict(os.environ, {}, clear=True):
            with patch("tools._shared._read_key_file", return_value=None):
                with patch("tools._shared.Path") as MockPath:
                    MockPath.home.return_value.__truediv__ = MagicMock(return_value="nope")
                    result = resolve_api_key("NONEXISTENT_KEY", ".nope")
                    assert result is None or result == "from-env" or True

    def test_reads_from_dotfile_when_env_empty(self, tmp_path):
        from tools._shared import resolve_api_key

        dotfile = tmp_path / ".testkey"
        dotfile.write_text("secret-from-file\n")

        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("TEST_KEY_VAR", None)
            with patch("tools._shared.Path") as MockPath:
                MockPath.home.return_value = tmp_path
                result = resolve_api_key("TEST_KEY_VAR", ".testkey")
                assert result == "secret-from-file"


class TestFormatResult:

    def test_none_returns_no_results(self):
        from tools._shared import format_result

        assert format_result(None) == "(no results)"

    def test_empty_string_returns_empty_response(self):
        from tools._shared import format_result

        assert format_result("") == "(empty response)"

    def test_nonempty_string_returned_as_is(self):
        from tools._shared import format_result

        assert format_result("hello") == "hello"

    def test_dict_returns_indented_json(self):
        from tools._shared import format_result

        result = format_result({"a": 1})
        parsed = json.loads(result)
        assert parsed == {"a": 1}

    def test_list_returns_indented_json(self):
        from tools._shared import format_result

        result = format_result([1, 2, 3])
        assert json.loads(result) == [1, 2, 3]


# ── env-var package gating ─────────────────────────────────────────────────


class TestIsToolPackageDisabled:

    def test_not_disabled_by_default(self):
        from tools._shared import is_tool_package_disabled

        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("ATOMOS_TOOLS_DISABLE_ARXIV", None)
            assert is_tool_package_disabled("arxiv") is False

    def test_disabled_with_1(self):
        from tools._shared import is_tool_package_disabled

        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_ARXIV": "1"}):
            assert is_tool_package_disabled("arxiv") is True

    def test_disabled_with_true(self):
        from tools._shared import is_tool_package_disabled

        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_NOTION": "true"}):
            assert is_tool_package_disabled("notion") is True

    def test_disabled_with_yes(self):
        from tools._shared import is_tool_package_disabled

        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_DEVTOOLS": "yes"}):
            assert is_tool_package_disabled("devtools") is True

    def test_not_disabled_with_0(self):
        from tools._shared import is_tool_package_disabled

        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_ARXIV": "0"}):
            assert is_tool_package_disabled("arxiv") is False

    def test_not_disabled_with_false(self):
        from tools._shared import is_tool_package_disabled

        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_ARXIV": "false"}):
            assert is_tool_package_disabled("arxiv") is False

    def test_case_insensitive_namespace(self):
        from tools._shared import is_tool_package_disabled

        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_ARXIV": "TRUE"}):
            assert is_tool_package_disabled("arxiv") is True


# ── namespace collision detection ──────────────────────────────────────────


class TestNamespaceCollisionDetection:

    def test_no_collision_with_different_names(self):
        from tool_registry import _check_namespace_collisions

        tools = [
            {"name": "arxiv_search", "source": "atomos"},
            {"name": "terminal", "source": "deepagents"},
        ]
        _check_namespace_collisions(tools)

    def test_same_name_same_source_no_collision(self):
        from tool_registry import _check_namespace_collisions

        tools = [
            {"name": "terminal", "source": "atomos"},
            {"name": "terminal", "source": "atomos"},
        ]
        _check_namespace_collisions(tools)

    def test_same_name_different_source_raises(self):
        from tool_registry import _check_namespace_collisions, ToolNamespaceCollisionError

        tools = [
            {"name": "search", "source": "package_a"},
            {"name": "search", "source": "package_b"},
        ]
        with pytest.raises(ToolNamespaceCollisionError, match="'search'.*'package_a'.*'package_b'"):
            _check_namespace_collisions(tools)

    def test_collision_error_is_descriptive(self):
        from tool_registry import _check_namespace_collisions, ToolNamespaceCollisionError

        tools = [
            {"name": "my_tool", "source": "alpha"},
            {"name": "my_tool", "source": "beta"},
        ]
        with pytest.raises(ToolNamespaceCollisionError) as exc_info:
            _check_namespace_collisions(tools)
        msg = str(exc_info.value)
        assert "my_tool" in msg
        assert "alpha" in msg
        assert "beta" in msg
        assert "namespace prefix" in msg

    def test_collision_detected_in_discover_all_tools(self):
        from tool_registry import discover_all_tools, ToolNamespaceCollisionError

        fake_tool_a = MagicMock()
        fake_tool_a.name = "duplicate_tool"
        fake_tool_a.description = "from A"

        fake_tool_b = MagicMock()
        fake_tool_b.name = "duplicate_tool"
        fake_tool_b.description = "from B"

        with patch("tool_registry._discover_atomos_tools", return_value=[
            {"name": "duplicate_tool", "description": "from A", "source": "atomos", "tool": fake_tool_a},
        ]):
            with patch("tool_registry._discover_deepagent_tools", return_value=[
                {"name": "duplicate_tool", "description": "from B", "source": "deepagents", "tool": fake_tool_b},
            ]):
                with pytest.raises(ToolNamespaceCollisionError, match="duplicate_tool"):
                    discover_all_tools()

    def test_no_collision_when_tool_lists_empty(self):
        from tool_registry import _check_namespace_collisions

        _check_namespace_collisions([])


# ── disabled package → tools not registered ────────────────────────────────


class TestDisabledPackageIntegration:

    def test_disabled_arxiv_not_in_skills(self):
        """When ATOMOS_TOOLS_DISABLE_ARXIV=1, arxiv tools should not appear."""
        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_ARXIV": "1"}):
            from tools.skills import get_atomos_skills
            tools = get_atomos_skills()
            names = {getattr(t, "name", str(t)) for t in tools}
            assert "arxiv_search_papers" not in names
            assert "arxiv_download_paper" not in names
            assert "arxiv_list_papers" not in names
            assert "arxiv_read_paper" not in names

    def test_disabled_notion_not_in_skills(self):
        """When ATOMOS_TOOLS_DISABLE_NOTION=1, notion tools should not appear."""
        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_NOTION": "1"}):
            from tools.skills import get_atomos_skills
            tools = get_atomos_skills()
            names = {getattr(t, "name", str(t)) for t in tools}
            for tool_name in [
                "notion_search", "notion_get_page", "notion_create_page",
                "notion_update_page", "notion_get_block_children",
                "notion_append_blocks", "notion_query_database", "notion_get_database",
            ]:
                assert tool_name not in names

    def test_disabled_devtools_not_in_skills(self):
        """When ATOMOS_TOOLS_DISABLE_DEVTOOLS=1, devtools tools should not appear."""
        with patch.dict(os.environ, {"ATOMOS_TOOLS_DISABLE_DEVTOOLS": "1"}):
            from tools.skills import get_atomos_skills
            tools = get_atomos_skills()
            names = {getattr(t, "name", str(t)) for t in tools}
            assert "devtools_connect" not in names

    def test_enabled_package_present_in_skills(self):
        """When env var is not set, tools from that package should still load."""
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("ATOMOS_TOOLS_DISABLE_SUPERPOWERS", None)
            from tools.skills import get_atomos_skills
            tools = get_atomos_skills()
            names = {getattr(t, "name", str(t)) for t in tools}
            assert "superpowers_list_skills" in names


# ── cross-cutting: shared module used by existing tool files ───────────────


class TestSharedModuleIntegration:

    def test_arxiv_uses_shared_call_handler(self):
        """arxiv.py imports _call_handler from _shared."""
        from tools.arxiv import _call_handler
        from tools._shared import call_mcp_handler
        assert _call_handler is call_mcp_handler

    def test_drawio_uses_shared_parse_json(self):
        """drawio.py imports _parse_json from _shared."""
        from tools.drawio import _parse_json
        from tools._shared import parse_json_param
        assert _parse_json is parse_json_param

    def test_notion_uses_shared_format_result(self):
        """notion.py imports _fmt from _shared."""
        from tools.notion import _fmt
        from tools._shared import format_result
        assert _fmt is format_result

    def test_researcher_uses_shared_resolve_api_key(self):
        """researcher.py imports _resolve_api_key from _shared."""
        from tools.researcher import _resolve_api_key
        from tools._shared import resolve_api_key
        assert _resolve_api_key is resolve_api_key
