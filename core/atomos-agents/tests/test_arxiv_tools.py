"""
Tests for the arxiv tools (tools/arxiv.py).

Covers:
  - Tool registration and discovery via get_arxiv_tools()
  - Tool names, descriptions, and argument schemas
  - Handler invocation round-trip (mock arxiv_mcp_server handlers)
  - Error handling when arxiv-mcp-server is unavailable
  - Integration with tool_registry allowed-tools list
"""

import asyncio
import json
import sys
import types as builtin_types
import pytest
from unittest.mock import AsyncMock, MagicMock, patch


# ── helpers ────────────────────────────────────────────────────────────────

def _make_text_content(text: str):
    """Build a mock mcp.types.TextContent."""
    tc = MagicMock()
    tc.text = text
    tc.type = "text"
    return tc


def _install_fake_arxiv_module():
    """Inject a fake arxiv_mcp_server package into sys.modules so deferred
    imports inside tool functions resolve without the real package."""
    pkg = builtin_types.ModuleType("arxiv_mcp_server")
    tools_mod = builtin_types.ModuleType("arxiv_mcp_server.tools")

    tools_mod.handle_search = AsyncMock(return_value=[])
    tools_mod.handle_download = AsyncMock(return_value=[])
    tools_mod.handle_list_papers = AsyncMock(return_value=[])
    tools_mod.handle_read_paper = AsyncMock(return_value=[])

    pkg.tools = tools_mod
    sys.modules["arxiv_mcp_server"] = pkg
    sys.modules["arxiv_mcp_server.tools"] = tools_mod
    return tools_mod


def _uninstall_fake_arxiv_module():
    sys.modules.pop("arxiv_mcp_server", None)
    sys.modules.pop("arxiv_mcp_server.tools", None)


# ── tool registration ─────────────────────────────────────────────────────

class TestArxivToolRegistration:

    def test_get_arxiv_tools_returns_four_tools(self):
        _install_fake_arxiv_module()
        try:
            import tools.arxiv as mod
            mod._ARXIV_TOOLS = None
            result = mod.get_arxiv_tools()
            assert len(result) == 4
        finally:
            _uninstall_fake_arxiv_module()
            mod._ARXIV_TOOLS = None

    def test_tool_names_are_namespaced(self):
        _install_fake_arxiv_module()
        try:
            import tools.arxiv as mod
            mod._ARXIV_TOOLS = None
            result = mod.get_arxiv_tools()
            names = {t.name for t in result}
            assert names == {
                "arxiv_search_papers",
                "arxiv_download_paper",
                "arxiv_list_papers",
                "arxiv_read_paper",
            }
        finally:
            _uninstall_fake_arxiv_module()
            mod._ARXIV_TOOLS = None

    def test_search_tool_has_correct_args(self):
        from tools.arxiv import arxiv_search_papers
        schema = arxiv_search_papers.args_schema
        if schema:
            assert "query" in schema.model_fields

    def test_download_tool_has_paper_id_arg(self):
        from tools.arxiv import arxiv_download_paper
        schema = arxiv_download_paper.args_schema
        if schema:
            assert "paper_id" in schema.model_fields

    def test_graceful_when_package_missing(self):
        """get_arxiv_tools returns [] when arxiv-mcp-server is not installed."""
        _uninstall_fake_arxiv_module()
        import tools.arxiv as mod
        mod._ARXIV_TOOLS = None
        result = mod.get_arxiv_tools()
        assert result == []
        mod._ARXIV_TOOLS = None


# ── handler invocation ────────────────────────────────────────────────────

class TestArxivSearchPapers:

    def test_search_papers_invokes_handler(self):
        fake = _install_fake_arxiv_module()
        fake.handle_search = AsyncMock(return_value=[
            _make_text_content(json.dumps({
                "total_results": 2,
                "papers": [
                    {"id": "2401.00001", "title": "Paper One"},
                    {"id": "2401.00002", "title": "Paper Two"},
                ],
            }))
        ])
        try:
            from tools.arxiv import arxiv_search_papers
            result = asyncio.run(
                arxiv_search_papers.coroutine(query="transformers", max_results=5)
            )
            assert "Paper One" in result
            assert "Paper Two" in result
        finally:
            _uninstall_fake_arxiv_module()

    def test_search_passes_all_arguments(self):
        captured = {}

        async def capture_handler(arguments):
            captured.update(arguments)
            return [_make_text_content("ok")]

        fake = _install_fake_arxiv_module()
        fake.handle_search = capture_handler
        try:
            from tools.arxiv import arxiv_search_papers
            asyncio.run(arxiv_search_papers.coroutine(
                query="attention",
                max_results=20,
                date_from="2023-01-01",
                categories=["cs.AI", "cs.LG"],
                sort_by="date",
            ))

            assert captured["query"] == "attention"
            assert captured["max_results"] == 20
            assert captured["date_from"] == "2023-01-01"
            assert captured["categories"] == ["cs.AI", "cs.LG"]
            assert captured["sort_by"] == "date"
        finally:
            _uninstall_fake_arxiv_module()

    def test_search_omits_none_args(self):
        captured = {}

        async def capture_handler(arguments):
            captured.update(arguments)
            return [_make_text_content("ok")]

        fake = _install_fake_arxiv_module()
        fake.handle_search = capture_handler
        try:
            from tools.arxiv import arxiv_search_papers
            asyncio.run(arxiv_search_papers.coroutine(query="test"))

            assert "date_from" not in captured
            assert "date_to" not in captured
            assert "categories" not in captured
            assert captured.get("max_results") == 10
        finally:
            _uninstall_fake_arxiv_module()


class TestArxivDownloadPaper:

    def test_download_invokes_handler(self):
        fake = _install_fake_arxiv_module()
        fake.handle_download = AsyncMock(return_value=[
            _make_text_content(json.dumps({
                "status": "converting",
                "message": "Paper downloaded, conversion started",
            }))
        ])
        try:
            from tools.arxiv import arxiv_download_paper
            result = asyncio.run(
                arxiv_download_paper.coroutine(paper_id="2401.12345")
            )
            assert "converting" in result or "downloaded" in result
        finally:
            _uninstall_fake_arxiv_module()


class TestArxivListPapers:

    def test_list_invokes_handler(self):
        fake = _install_fake_arxiv_module()
        fake.handle_list_papers = AsyncMock(return_value=[
            _make_text_content(json.dumps({
                "total_papers": 1,
                "papers": [{"title": "Test Paper"}],
            }))
        ])
        try:
            from tools.arxiv import arxiv_list_papers
            result = asyncio.run(arxiv_list_papers.coroutine())
            assert "Test Paper" in result
        finally:
            _uninstall_fake_arxiv_module()


class TestArxivReadPaper:

    def test_read_invokes_handler(self):
        fake = _install_fake_arxiv_module()
        fake.handle_read_paper = AsyncMock(return_value=[
            _make_text_content(json.dumps({
                "status": "success",
                "paper_id": "2401.12345",
                "content": "# Abstract\nThis paper presents...",
            }))
        ])
        try:
            from tools.arxiv import arxiv_read_paper
            result = asyncio.run(
                arxiv_read_paper.coroutine(paper_id="2401.12345")
            )
            assert "Abstract" in result
        finally:
            _uninstall_fake_arxiv_module()


# ── _call_handler round-trip ──────────────────────────────────────────────

class TestCallHandlerRoundTrip:

    def test_extracts_text_from_results(self):
        from tools.arxiv import _call_handler

        async def handler(args):
            return [_make_text_content("block one"), _make_text_content("block two")]

        result = asyncio.run(_call_handler(handler, {}))
        assert "block one" in result
        assert "block two" in result

    def test_handles_empty_result(self):
        from tools.arxiv import _call_handler

        async def handler(args):
            return []

        result = asyncio.run(_call_handler(handler, {}))
        assert result == "(no results)"

    def test_handles_error_in_handler(self):
        from tools.arxiv import _call_handler

        async def handler(args):
            raise ValueError("API error")

        with pytest.raises(ValueError, match="API error"):
            asyncio.run(_call_handler(handler, {}))

    def test_multi_block_joined_with_newlines(self):
        from tools.arxiv import _call_handler

        async def handler(args):
            return [_make_text_content("line1"), _make_text_content("line2")]

        result = asyncio.run(_call_handler(handler, {}))
        assert result == "line1\nline2"


# ── tool_registry integration ─────────────────────────────────────────────

class TestRegistryIntegration:

    def test_arxiv_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS

        assert "arxiv_search_papers" in _ALLOWED_EXPOSED_TOOLS
        assert "arxiv_download_paper" in _ALLOWED_EXPOSED_TOOLS
        assert "arxiv_list_papers" in _ALLOWED_EXPOSED_TOOLS
        assert "arxiv_read_paper" in _ALLOWED_EXPOSED_TOOLS
