"""
Tests for the Notion tools (tools/notion.py).

Covers:
  - Tool registration and discovery via get_notion_tools()
  - Tool names, descriptions, and argument schemas
  - Handler invocation round-trip (mock NotionClient)
  - API key resolution from env var and dotfiles
  - JSON parameter parsing for filters, sorts, properties, children
  - Error handling for invalid JSON input
  - Graceful degradation when notion-sdk-ldraney is unavailable
  - Integration with tool_registry allowed-tools list
"""

import json
import sys
import types as builtin_types
import pytest
from unittest.mock import MagicMock, patch


# ── helpers ────────────────────────────────────────────────────────────────


_FAKE_PAGE = {
    "object": "page",
    "id": "page-123",
    "properties": {
        "title": {
            "id": "title",
            "type": "title",
            "title": [{"text": {"content": "Test Page"}}],
        }
    },
}

_FAKE_DB = {
    "object": "database",
    "id": "db-456",
    "title": [{"text": {"content": "Task Board"}}],
    "properties": {
        "Name": {"type": "title", "title": {}},
        "Status": {"type": "select", "select": {"options": []}},
    },
}

_FAKE_SEARCH = {
    "object": "list",
    "results": [_FAKE_PAGE],
    "has_more": False,
}

_FAKE_BLOCKS = {
    "object": "list",
    "results": [
        {
            "object": "block",
            "id": "block-789",
            "type": "paragraph",
            "paragraph": {
                "rich_text": [{"text": {"content": "Hello world"}}]
            },
        }
    ],
    "has_more": False,
}

_FAKE_QUERY = {
    "object": "list",
    "results": [_FAKE_PAGE],
    "has_more": False,
}


def _make_mock_client():
    """Build a mock NotionClient with standard responses."""
    client = MagicMock()
    client.search.return_value = _FAKE_SEARCH
    client.get_page.return_value = _FAKE_PAGE
    client.create_page.return_value = _FAKE_PAGE
    client.update_page.return_value = _FAKE_PAGE
    client.get_block_children.return_value = _FAKE_BLOCKS
    client.append_block_children.return_value = _FAKE_BLOCKS
    client.query_database.return_value = _FAKE_QUERY
    client.get_database.return_value = _FAKE_DB
    return client


def _install_fake_notion_module():
    """Inject a fake notion_sdk package into sys.modules."""
    pkg = builtin_types.ModuleType("notion_sdk")
    pkg.NotionClient = MagicMock(return_value=_make_mock_client())
    sys.modules["notion_sdk"] = pkg
    return pkg


def _uninstall_fake_notion_module():
    sys.modules.pop("notion_sdk", None)


def _reset_module_state():
    """Reset the notion module's cached state."""
    import tools.notion as mod
    mod._NOTION_TOOLS = None
    mod._client = None


# ── tool registration ─────────────────────────────────────────────────────


class TestNotionToolRegistration:

    def test_get_notion_tools_returns_eight_tools(self):
        _install_fake_notion_module()
        try:
            import tools.notion as mod
            _reset_module_state()
            result = mod.get_notion_tools()
            assert len(result) == 8
        finally:
            _uninstall_fake_notion_module()
            _reset_module_state()

    def test_tool_names_are_namespaced(self):
        _install_fake_notion_module()
        try:
            import tools.notion as mod
            _reset_module_state()
            result = mod.get_notion_tools()
            names = {t.name for t in result}
            assert names == {
                "notion_search",
                "notion_get_page",
                "notion_create_page",
                "notion_update_page",
                "notion_get_block_children",
                "notion_append_blocks",
                "notion_query_database",
                "notion_get_database",
            }
        finally:
            _uninstall_fake_notion_module()
            _reset_module_state()

    def test_search_tool_has_query_arg(self):
        from tools.notion import notion_search
        schema = notion_search.args_schema
        if schema:
            assert "query" in schema.model_fields

    def test_create_page_has_parent_id_arg(self):
        from tools.notion import notion_create_page
        schema = notion_create_page.args_schema
        if schema:
            assert "parent_id" in schema.model_fields

    def test_query_database_has_database_id_arg(self):
        from tools.notion import notion_query_database
        schema = notion_query_database.args_schema
        if schema:
            assert "database_id" in schema.model_fields

    def test_graceful_when_package_missing(self):
        """get_notion_tools returns [] when notion-sdk-ldraney is not installed."""
        _uninstall_fake_notion_module()
        import tools.notion as mod
        _reset_module_state()
        result = mod.get_notion_tools()
        assert result == []
        _reset_module_state()


# ── API key resolution ────────────────────────────────────────────────────


class TestNotionApiKeyResolution:

    def test_resolves_from_env_var(self):
        import tools.notion as mod
        with patch.dict("os.environ", {"NOTION_API_KEY": "ntn_test123"}):
            key = mod._resolve_notion_key()
            assert key == "ntn_test123"

    def test_resolves_from_dotfile(self):
        import tools.notion as mod
        with patch.dict("os.environ", {"NOTION_API_KEY": ""}, clear=False):
            with patch("tools._shared._read_key_file", return_value="ntn_from_file"):
                key = mod._resolve_notion_key()
                assert key == "ntn_from_file"

    def test_returns_none_when_missing(self):
        import tools.notion as mod
        with patch.dict("os.environ", {"NOTION_API_KEY": ""}, clear=False):
            with patch("tools._shared._read_key_file", return_value=None):
                with patch("pathlib.Path.iterdir", side_effect=OSError):
                    key = mod._resolve_notion_key()
                    assert key is None

    def test_check_client_returns_error_when_no_key(self):
        import tools.notion as mod
        _reset_module_state()
        with patch.object(mod, "_resolve_notion_key", return_value=None):
            err = mod._check_client()
            assert err is not None
            assert "NOTION_API_KEY" in err


# ── handler invocation ────────────────────────────────────────────────────


class TestNotionSearch:

    def test_search_invokes_client(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_search.invoke({"query": "Meeting Notes"})
        assert "Test Page" in result
        mock_client.search.assert_called_once()
        mod._client = None

    def test_search_passes_filter_type(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        mod.notion_search.invoke({
            "query": "My DB",
            "filter_type": "database",
        })
        call_kwargs = mock_client.search.call_args[1]
        assert call_kwargs["filter"] == {"value": "database", "property": "object"}
        mod._client = None

    def test_search_omits_empty_optional_args(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        mod.notion_search.invoke({"query": "test"})
        call_kwargs = mock_client.search.call_args[1]
        assert "filter" not in call_kwargs
        assert "start_cursor" not in call_kwargs
        mod._client = None

    def test_search_returns_error_when_no_key(self):
        import tools.notion as mod
        _reset_module_state()
        with patch.object(mod, "_resolve_notion_key", return_value=None):
            result = mod.notion_search.invoke({"query": "test"})
            assert "NOTION_API_KEY" in result

    def test_search_handles_api_error(self):
        mock_client = _make_mock_client()
        mock_client.search.side_effect = Exception("rate limited")
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_search.invoke({"query": "test"})
        assert "rate limited" in result
        mod._client = None


class TestNotionGetPage:

    def test_get_page_invokes_client(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_get_page.invoke({"page_id": "page-123"})
        assert "page-123" in result
        mock_client.get_page.assert_called_once_with("page-123")
        mod._client = None

    def test_get_page_handles_error(self):
        mock_client = _make_mock_client()
        mock_client.get_page.side_effect = Exception("not found")
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_get_page.invoke({"page_id": "bad-id"})
        assert "not found" in result
        mod._client = None


class TestNotionCreatePage:

    def test_create_page_with_title(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_create_page.invoke({
            "parent_id": "parent-123",
            "parent_type": "page_id",
            "title": "New Page",
        })
        assert "page-123" in result
        call_kwargs = mock_client.create_page.call_args[1]
        assert call_kwargs["parent"] == {"type": "page_id", "page_id": "parent-123"}
        assert "title" in str(call_kwargs["properties"])
        mod._client = None

    def test_create_page_with_properties_json(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        props = {"Name": {"title": [{"text": {"content": "Task"}}]}}
        mod.notion_create_page.invoke({
            "parent_id": "db-456",
            "parent_type": "database_id",
            "properties_json": json.dumps(props),
        })
        call_kwargs = mock_client.create_page.call_args[1]
        assert call_kwargs["parent"]["type"] == "database_id"
        assert call_kwargs["properties"] == props
        mod._client = None

    def test_create_page_with_children_json(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        children = [{"object": "block", "type": "paragraph",
                      "paragraph": {"rich_text": [{"text": {"content": "Hi"}}]}}]
        mod.notion_create_page.invoke({
            "parent_id": "parent-123",
            "title": "With Content",
            "children_json": json.dumps(children),
        })
        call_kwargs = mock_client.create_page.call_args[1]
        assert call_kwargs["children"] == children
        mod._client = None

    def test_create_page_invalid_json_returns_error(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_create_page.invoke({
            "parent_id": "parent-123",
            "properties_json": "{bad json",
        })
        assert "Invalid JSON" in result
        mod._client = None


class TestNotionUpdatePage:

    def test_update_page_with_properties(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        props = {"Status": {"select": {"name": "Done"}}}
        mod.notion_update_page.invoke({
            "page_id": "page-123",
            "properties_json": json.dumps(props),
        })
        call_kwargs = mock_client.update_page.call_args[1]
        assert call_kwargs["page_id"] == "page-123"
        assert call_kwargs["properties"] == props
        mod._client = None

    def test_update_page_archive(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        mod.notion_update_page.invoke({
            "page_id": "page-123",
            "archived": True,
        })
        call_kwargs = mock_client.update_page.call_args[1]
        assert call_kwargs["archived"] is True
        mod._client = None

    def test_update_page_invalid_json_returns_error(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_update_page.invoke({
            "page_id": "page-123",
            "properties_json": "not valid",
        })
        assert "Invalid JSON" in result
        mod._client = None


class TestNotionGetBlockChildren:

    def test_get_block_children_invokes_client(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_get_block_children.invoke({"block_id": "page-123"})
        assert "Hello world" in result
        mock_client.get_block_children.assert_called_once()
        mod._client = None

    def test_get_block_children_passes_pagination(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        mod.notion_get_block_children.invoke({
            "block_id": "page-123",
            "page_size": 50,
            "start_cursor": "cursor-abc",
        })
        call_kwargs = mock_client.get_block_children.call_args[1]
        assert call_kwargs["page_size"] == 50
        assert call_kwargs["start_cursor"] == "cursor-abc"
        mod._client = None


class TestNotionAppendBlocks:

    def test_append_blocks_invokes_client(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        children = [{"object": "block", "type": "paragraph",
                      "paragraph": {"rich_text": [{"text": {"content": "New content"}}]}}]
        mod.notion_append_blocks.invoke({
            "block_id": "page-123",
            "children_json": json.dumps(children),
        })
        mock_client.append_block_children.assert_called_once_with(
            block_id="page-123", children=children
        )
        mod._client = None

    def test_append_blocks_empty_json_returns_error(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_append_blocks.invoke({
            "block_id": "page-123",
            "children_json": "",
        })
        assert "required" in result.lower()
        mod._client = None

    def test_append_blocks_invalid_json_returns_error(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_append_blocks.invoke({
            "block_id": "page-123",
            "children_json": "[invalid",
        })
        assert "Invalid JSON" in result
        mod._client = None


class TestNotionQueryDatabase:

    def test_query_database_invokes_client(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_query_database.invoke({"database_id": "db-456"})
        assert "page-123" in result
        mock_client.query_database.assert_called_once()
        mod._client = None

    def test_query_database_with_filter_and_sort(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        filter_obj = {"property": "Status", "select": {"equals": "Done"}}
        sorts = [{"property": "Created", "direction": "descending"}]
        mod.notion_query_database.invoke({
            "database_id": "db-456",
            "filter_json": json.dumps(filter_obj),
            "sorts_json": json.dumps(sorts),
        })
        call_kwargs = mock_client.query_database.call_args[1]
        assert call_kwargs["filter"] == filter_obj
        assert call_kwargs["sorts"] == sorts
        mod._client = None

    def test_query_database_invalid_filter_returns_error(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_query_database.invoke({
            "database_id": "db-456",
            "filter_json": "{bad",
        })
        assert "Invalid JSON" in result
        mod._client = None


class TestNotionGetDatabase:

    def test_get_database_invokes_client(self):
        mock_client = _make_mock_client()
        import tools.notion as mod
        mod._client = mock_client

        result = mod.notion_get_database.invoke({"database_id": "db-456"})
        assert "Task Board" in result
        mock_client.get_database.assert_called_once_with("db-456")
        mod._client = None


# ── _fmt helper ────────────────────────────────────────────────────────────


class TestFmtHelper:

    def test_fmt_none_returns_no_results(self):
        from tools.notion import _fmt
        assert _fmt(None) == "(no results)"

    def test_fmt_empty_string_returns_placeholder(self):
        from tools.notion import _fmt
        assert _fmt("") == "(empty response)"

    def test_fmt_dict_returns_json(self):
        from tools.notion import _fmt
        result = _fmt({"key": "value"})
        parsed = json.loads(result)
        assert parsed["key"] == "value"

    def test_fmt_string_returns_as_is(self):
        from tools.notion import _fmt
        assert _fmt("hello") == "hello"


# ── _parse_json_param ─────────────────────────────────────────────────────


class TestParseJsonParam:

    def test_parse_valid_json(self):
        from tools.notion import _parse_json_param
        result = _parse_json_param('{"a": 1}', "test")
        assert result == {"a": 1}

    def test_parse_empty_returns_none(self):
        from tools.notion import _parse_json_param
        assert _parse_json_param("", "test") is None

    def test_parse_invalid_json_raises(self):
        from tools.notion import _parse_json_param
        with pytest.raises(ValueError, match="Invalid JSON"):
            _parse_json_param("{bad", "test_param")

    def test_parse_array(self):
        from tools.notion import _parse_json_param
        result = _parse_json_param('[1, 2, 3]', "test")
        assert result == [1, 2, 3]


# ── tool_registry integration ─────────────────────────────────────────────


class TestRegistryIntegration:

    def test_notion_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS

        expected = {
            "notion_search",
            "notion_get_page",
            "notion_create_page",
            "notion_update_page",
            "notion_get_block_children",
            "notion_append_blocks",
            "notion_query_database",
            "notion_get_database",
        }
        for name in expected:
            assert name in _ALLOWED_EXPOSED_TOOLS, f"{name} not in _ALLOWED_EXPOSED_TOOLS"
