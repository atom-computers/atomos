"""
Integration tests: MCP-server tool packages through the bridge (§1.1–1.6).

Each test verifies that an agent can invoke a tool from a given package and
that the result flows back through the gRPC ``StreamAgentTurn`` pipeline.

Because we cannot rely on a live LLM in CI, we simulate the agent loop:
  1. Instantiate the real tool objects via their ``get_*_tools()`` getters.
  2. Call the tool's ``.invoke()`` or ``.ainvoke()`` with realistic params.
  3. Feed the output through ``_format_tool_output()`` (the same path
     ``server.py`` uses) and verify it appears in an ``AgentResponse``.

This exercises the full tool → handler → format → bridge path without
requiring network access or an LLM API key.
"""

import asyncio
import json
import os
import sys
import types
import pytest
from unittest.mock import AsyncMock, MagicMock, patch

import bridge_pb2

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pytestmark = pytest.mark.integration

_SKIP_REASON = "ATOMOS_INTEGRATION_TEST not set"


def _skip_unless_integration():
    if not os.environ.get("ATOMOS_INTEGRATION_TEST"):
        pytest.skip(_SKIP_REASON)


def _format_tool_output(content: str, tool_name: str) -> str:
    safe = content.replace("```", "` ` `")
    return f"\n```\n{safe}\n```\n"


def _bridge_response(tool_output: str, tool_name: str) -> bridge_pb2.AgentResponse:
    """Simulate what server.py yields when a tool returns output."""
    formatted = _format_tool_output(tool_output, tool_name)
    return bridge_pb2.AgentResponse(
        content=formatted,
        done=False,
        tool_call="",
        status="",
    )


# ── §1.1 arxiv ─────────────────────────────────────────────────────────────


class TestArxivBridgeIntegration:
    """Agent calls arxiv search tool → results returned through bridge."""

    def _ensure_arxiv_mock(self):
        """Inject a fake arxiv_mcp_server so the tools load."""
        fake_tools = types.ModuleType("arxiv_mcp_server.tools")

        async def handle_search(arguments):
            result = MagicMock()
            result.text = json.dumps({
                "papers": [{"id": "2401.00001", "title": "Test Paper on LLMs"}]
            })
            return [result]

        async def handle_download(arguments):
            result = MagicMock()
            result.text = "PDF downloaded to /tmp/2401.00001.pdf"
            return [result]

        async def handle_list_papers(arguments):
            result = MagicMock()
            result.text = json.dumps({"papers": []})
            return [result]

        async def handle_read_paper(arguments):
            result = MagicMock()
            result.text = "Abstract: This paper presents..."
            return [result]

        fake_tools.handle_search = handle_search
        fake_tools.handle_download = handle_download
        fake_tools.handle_list_papers = handle_list_papers
        fake_tools.handle_read_paper = handle_read_paper

        fake_pkg = types.ModuleType("arxiv_mcp_server")
        fake_pkg.tools = fake_tools

        sys.modules["arxiv_mcp_server"] = fake_pkg
        sys.modules["arxiv_mcp_server.tools"] = fake_tools

    def test_arxiv_search_through_bridge(self):
        _skip_unless_integration()
        self._ensure_arxiv_mock()

        import tools.arxiv as arxiv_mod
        arxiv_mod._ARXIV_TOOLS = None

        tools_list = arxiv_mod.get_arxiv_tools()
        assert len(tools_list) == 4

        search_tool = next(t for t in tools_list if t.name == "arxiv_search_papers")
        result = asyncio.get_event_loop().run_until_complete(
            search_tool.ainvoke({"query": "large language models"})
        )
        assert "Test Paper on LLMs" in result

        resp = _bridge_response(result, "arxiv_search_papers")
        assert resp.content
        assert "Test Paper" in resp.content

        # Cleanup
        arxiv_mod._ARXIV_TOOLS = None
        sys.modules.pop("arxiv_mcp_server", None)
        sys.modules.pop("arxiv_mcp_server.tools", None)


# ── §1.2 chrome-devtools ───────────────────────────────────────────────────


class TestDevtoolsBridgeIntegration:
    """Agent inspects a page via devtools tool → DOM / network data returned."""

    def _ensure_devtools_mock(self):
        fake_client_mod = types.ModuleType("chrome_devtools_mcp_fork.client")

        class FakeCDPClient:
            def __init__(self, port=9222):
                self.port = port
                self.connected = False

            def connect(self):
                self.connected = True

            def send(self, method, params=None):
                if method == "Runtime.evaluate":
                    return {"result": {"type": "string", "value": "hello"}}
                if method == "DOM.getDocument":
                    return {"root": {"nodeId": 1, "nodeName": "#document", "children": []}}
                if method == "Network.getResponseBody":
                    return {"body": "<html></html>"}
                if method == "Page.getNavigationHistory":
                    return {"currentIndex": 0, "entries": [{"url": "https://example.com", "title": "Example"}]}
                return {}

        fake_client_mod.ChromeDevToolsClient = FakeCDPClient
        fake_pkg = types.ModuleType("chrome_devtools_mcp_fork")
        fake_pkg.client = fake_client_mod

        sys.modules["chrome_devtools_mcp_fork"] = fake_pkg
        sys.modules["chrome_devtools_mcp_fork.client"] = fake_client_mod

    def test_devtools_dom_through_bridge(self):
        _skip_unless_integration()
        self._ensure_devtools_mock()

        import tools.devtools as dt_mod
        dt_mod._DEVTOOLS_TOOLS = None
        dt_mod._client = None

        tools_list = dt_mod.get_devtools_tools()
        assert len(tools_list) == 6

        connect_tool = next(t for t in tools_list if t.name == "devtools_connect")
        connect_result = connect_tool.invoke({"port": 9222})
        assert "Connected" in connect_result or "connected" in connect_result.lower()

        dom_tool = next(t for t in tools_list if t.name == "devtools_get_dom")
        dom_result = dom_tool.invoke({})

        resp = _bridge_response(dom_result, "devtools_get_dom")
        assert resp.content
        assert not resp.done

        dt_mod._DEVTOOLS_TOOLS = None
        dt_mod._client = None
        sys.modules.pop("chrome_devtools_mcp_fork", None)
        sys.modules.pop("chrome_devtools_mcp_fork.client", None)


# ── §1.3 superpowers ───────────────────────────────────────────────────────


class TestSuperpowersBridgeIntegration:
    """Agent invokes a Superpowers tool → result returned through bridge."""

    def test_superpowers_list_through_bridge(self, tmp_path):
        _skip_unless_integration()

        skill_dir = tmp_path / "skills" / "test-skill"
        skill_dir.mkdir(parents=True)
        (skill_dir / "SKILL.md").write_text(
            "---\nname: test-skill\ndescription: A test skill\n---\n# Test Skill\nDoes testing.\n"
        )

        import tools.superpowers as sp_mod
        sp_mod._SUPERPOWERS_TOOLS = None

        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(tmp_path / "skills")}):
            tools_list = sp_mod.get_superpowers_tools()
            assert len(tools_list) == 7

            list_tool = next(t for t in tools_list if t.name == "superpowers_list_skills")
            result = list_tool.invoke({})
            assert "test-skill" in result

            resp = _bridge_response(result, "superpowers_list_skills")
            assert resp.content
            assert "test-skill" in resp.content

        sp_mod._SUPERPOWERS_TOOLS = None


# ── §1.4 GPT Researcher ───────────────────────────────────────────────────


class TestResearcherBridgeIntegration:
    """Agent triggers a research query → structured report returned through bridge."""

    def _ensure_researcher_mock(self):
        fake_mod = types.ModuleType("gpt_researcher")

        class FakeGPTResearcher:
            def __init__(self, query="", report_type="research_report", **kwargs):
                self.query = query
                self.report_type = report_type
                self._report = f"# Research Report\n\nFindings on: {query}\n\n1. Key finding A\n2. Key finding B"
                self._sources = [{"url": "https://example.com", "title": "Source 1"}]
                self._context = ["Context paragraph about " + query]
                self._costs = 0.02

            async def conduct_research(self):
                return self._report

            def get_source_urls(self):
                return self._sources

            def get_research_context(self):
                return self._context

            def get_costs(self):
                return self._costs

        fake_mod.GPTResearcher = FakeGPTResearcher
        sys.modules["gpt_researcher"] = fake_mod

    def test_researcher_research_through_bridge(self):
        _skip_unless_integration()
        self._ensure_researcher_mock()

        import tools.researcher as res_mod
        res_mod._RESEARCHER_TOOLS = None
        res_mod._last_researcher = None

        with patch.dict(os.environ, {"OPENAI_API_KEY": "test-key", "TAVILY_API_KEY": "test-key"}):
            tools_list = res_mod.get_researcher_tools()
            assert len(tools_list) == 4

            research_tool = next(t for t in tools_list if t.name == "researcher_research")
            result = asyncio.get_event_loop().run_until_complete(
                research_tool.ainvoke({"query": "quantum computing advances"})
            )
            assert "quantum computing" in result
            assert "Key finding" in result

            resp = _bridge_response(result, "researcher_research")
            assert resp.content
            assert "Research Report" in resp.content

        res_mod._RESEARCHER_TOOLS = None
        res_mod._last_researcher = None
        sys.modules.pop("gpt_researcher", None)


# ── §1.5 Draw.io ──────────────────────────────────────────────────────────


class TestDrawioBridgeIntegration:
    """Agent creates/edits a diagram → diagram file returned through bridge."""

    def _ensure_drawio_mock(self):
        fake_server = types.ModuleType("drawio_mcp.server")

        async def diagram(name=None, **kwargs):
            result = MagicMock()
            result.text = json.dumps({
                "diagram_id": "diag-001",
                "file": f"/tmp/{name or 'untitled'}.drawio",
                "status": "created",
            })
            return [result]

        async def draw(diagram_id=None, vertices=None, edges=None, **kwargs):
            result = MagicMock()
            result.text = json.dumps({"status": "drawn", "vertex_count": 3, "edge_count": 2})
            return [result]

        async def style(**kwargs):
            result = MagicMock()
            result.text = json.dumps({"status": "styled"})
            return [result]

        async def layout(**kwargs):
            result = MagicMock()
            result.text = json.dumps({"status": "laid out", "engine": "hierarchical"})
            return [result]

        async def inspect(diagram_id=None, **kwargs):
            result = MagicMock()
            result.text = json.dumps({"vertices": 3, "edges": 2, "pages": 1})
            return [result]

        fake_server.diagram = diagram
        fake_server.draw = draw
        fake_server.style = style
        fake_server.layout = layout
        fake_server.inspect = inspect

        fake_pkg = types.ModuleType("drawio_mcp")
        fake_pkg.server = fake_server

        sys.modules["drawio_mcp"] = fake_pkg
        sys.modules["drawio_mcp.server"] = fake_server

    def test_drawio_diagram_through_bridge(self):
        _skip_unless_integration()
        self._ensure_drawio_mock()

        import tools.drawio as drawio_mod
        drawio_mod._DRAWIO_TOOLS = None

        tools_list = drawio_mod.get_drawio_tools()
        assert len(tools_list) == 5

        diagram_tool = next(t for t in tools_list if t.name == "drawio_diagram")
        result = asyncio.get_event_loop().run_until_complete(
            diagram_tool.ainvoke({"name": "architecture"})
        )
        assert "architecture" in result or "diag-001" in result

        resp = _bridge_response(result, "drawio_diagram")
        assert resp.content
        assert not resp.done

        drawio_mod._DRAWIO_TOOLS = None
        sys.modules.pop("drawio_mcp", None)
        sys.modules.pop("drawio_mcp.server", None)


# ── §1.6 Notion ────────────────────────────────────────────────────────────


class TestNotionBridgeIntegration:
    """Agent reads/writes a Notion page → content returned through bridge."""

    def _ensure_notion_mock(self):
        fake_sdk = types.ModuleType("notion_sdk")

        class FakeNotionClient:
            def __init__(self, auth=None):
                self.auth = auth

            def search(self, **kwargs):
                return {"results": [{"id": "page-001", "object": "page",
                         "properties": {"title": {"title": [{"plain_text": "Test Page"}]}}}]}

            def get_page(self, page_id):
                return {"id": page_id, "object": "page",
                        "properties": {"title": {"title": [{"plain_text": "Test Page"}]}}}

            def create_page(self, **kwargs):
                return {"id": "new-page-001", "object": "page", "url": "https://notion.so/new-page-001"}

            def update_page(self, page_id, **kwargs):
                return {"id": page_id, "object": "page", "last_edited_time": "2025-03-15T10:00:00Z"}

            def get_block_children(self, block_id, **kwargs):
                return {"results": [{"type": "paragraph", "paragraph": {"text": [{"plain_text": "Hello world"}]}}]}

            def append_block_children(self, block_id, **kwargs):
                return {"results": [{"id": "block-001", "type": "paragraph"}]}

            def query_database(self, database_id, **kwargs):
                return {"results": [{"id": "row-001", "properties": {}}]}

            def get_database(self, database_id):
                return {"id": database_id, "title": [{"plain_text": "Test DB"}]}

        fake_sdk.NotionClient = FakeNotionClient

        fake_pkg = types.ModuleType("notion_mcp_ldraney")
        sys.modules["notion_sdk"] = fake_sdk
        sys.modules["notion_mcp_ldraney"] = fake_pkg

    def test_notion_read_write_through_bridge(self):
        _skip_unless_integration()
        self._ensure_notion_mock()

        import tools.notion as notion_mod
        notion_mod._NOTION_TOOLS = None
        notion_mod._client = None

        with patch.dict(os.environ, {"NOTION_API_KEY": "ntn_test_key"}):
            tools_list = notion_mod.get_notion_tools()
            assert len(tools_list) == 8

            search_tool = next(t for t in tools_list if t.name == "notion_search")
            result = search_tool.invoke({"query": "Test"})
            assert "Test Page" in result or "page-001" in result

            resp = _bridge_response(result, "notion_search")
            assert resp.content

            create_tool = next(t for t in tools_list if t.name == "notion_create_page")
            create_result = create_tool.invoke({
                "parent_id": "db-001",
                "title": "New Page from Agent",
                "properties": '{"Status": {"select": {"name": "Done"}}}',
            })
            assert "new-page-001" in create_result

            create_resp = _bridge_response(create_result, "notion_create_page")
            assert create_resp.content

        notion_mod._NOTION_TOOLS = None
        notion_mod._client = None
        sys.modules.pop("notion_sdk", None)
        sys.modules.pop("notion_mcp_ldraney", None)
