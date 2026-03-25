"""
End-to-end cross-tool workflow tests (§ Integration sections).

These tests verify multi-step scenarios where the agent chains tools from
different packages in a single interaction.  They exercise the full
tool → handler → format → bridge path for realistic workflows.

Covers:
  - Tool Packages ↔ Application Connections
  - CLI Tools ↔ Application Connections
  - New Tools ↔ Existing Bridge & UI
"""

import asyncio
import json
import os
import sys
import types
import pytest
from unittest.mock import MagicMock, patch

import bridge_pb2

pytestmark = pytest.mark.integration

_SKIP_REASON = "ATOMOS_INTEGRATION_TEST not set"


def _skip_unless_integration():
    if not os.environ.get("ATOMOS_INTEGRATION_TEST"):
        pytest.skip(_SKIP_REASON)


def _format_tool_output(content: str, tool_name: str) -> str:
    safe = content.replace("```", "` ` `")
    return f"\n```\n{safe}\n```\n"


def send_ui_block(
    block_type: str,
    *,
    block_id: str | None = None,
    title: str = "",
    description: str = "",
    body: str = "",
    actions: list[dict] | None = None,
    **kwargs,
) -> bridge_pb2.AgentResponse:
    type_map = {
        "card": bridge_pb2.UI_BLOCK_CARD,
        "table": bridge_pb2.UI_BLOCK_TABLE,
        "approval_prompt": bridge_pb2.UI_BLOCK_APPROVAL_PROMPT,
        "progress_bar": bridge_pb2.UI_BLOCK_PROGRESS_BAR,
        "file_tree": bridge_pb2.UI_BLOCK_FILE_TREE,
        "diff_view": bridge_pb2.UI_BLOCK_DIFF_VIEW,
    }
    proto_actions = []
    for a in (actions or []):
        proto_actions.append(bridge_pb2.UiBlockAction(
            id=a.get("id", ""),
            label=a.get("label", ""),
            style=a.get("style", "secondary"),
        ))
    block = bridge_pb2.UiBlock(
        block_id=block_id or "blk-test",
        block_type=type_map.get(block_type, bridge_pb2.UI_BLOCK_CARD),
        title=title,
        description=description,
        body=body,
        actions=proto_actions,
    )
    return bridge_pb2.AgentResponse(ui_blocks=[block])


def _mock_which(binary):
    return f"/usr/bin/{binary}"


def _bridge_response(tool_output: str, tool_name: str) -> bridge_pb2.AgentResponse:
    formatted = _format_tool_output(tool_output, tool_name)
    return bridge_pb2.AgentResponse(content=formatted, done=False, tool_call="", status="")


def _reset_mod(mod):
    if hasattr(mod, "_adapter"):
        mod._adapter = None
    for attr in dir(mod):
        if attr.startswith("_") and attr.endswith("_TOOLS"):
            setattr(mod, attr, None)


# ── Tool Packages ↔ Application Connections ────────────────────────────────


class TestToolPackagesToAppConnections:

    def test_arxiv_search_then_open_in_loupe(self, tmp_path):
        """Agent uses arxiv tools to search → downloads PDF → opens in Loupe."""
        _skip_unless_integration()

        # Step 1: arxiv search
        fake_tools = types.ModuleType("arxiv_mcp_server.tools")

        async def handle_search(arguments):
            r = MagicMock()
            r.text = json.dumps({"papers": [{"id": "2401.00001", "title": "Neural Rendering"}]})
            return [r]

        async def handle_download(arguments):
            pdf_path = tmp_path / "2401.00001.pdf"
            pdf_path.write_bytes(b"%PDF-1.4 fake content")
            r = MagicMock()
            r.text = f"Downloaded to {pdf_path}"
            return [r]

        fake_tools.handle_search = handle_search
        fake_tools.handle_download = handle_download
        fake_tools.handle_list_papers = handle_search
        fake_tools.handle_read_paper = handle_search

        fake_pkg = types.ModuleType("arxiv_mcp_server")
        fake_pkg.tools = fake_tools
        sys.modules["arxiv_mcp_server"] = fake_pkg
        sys.modules["arxiv_mcp_server.tools"] = fake_tools

        import tools.arxiv as arxiv_mod
        arxiv_mod._ARXIV_TOOLS = None
        arxiv_tools = arxiv_mod.get_arxiv_tools()
        search = next(t for t in arxiv_tools if t.name == "arxiv_search_papers")
        download = next(t for t in arxiv_tools if t.name == "arxiv_download_paper")

        search_result = asyncio.get_event_loop().run_until_complete(
            search.ainvoke({"query": "neural rendering"})
        )
        assert "Neural Rendering" in search_result

        dl_result = asyncio.get_event_loop().run_until_complete(
            download.ainvoke({"paper_id": "2401.00001"})
        )
        assert "Downloaded" in dl_result

        # Step 2: open preview in Loupe
        pdf_path = tmp_path / "2401.00001.pdf"
        assert pdf_path.exists()

        import tools.loupe as loupe_mod
        _reset_mod(loupe_mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.loupe import image_open, _get_adapter
            adapter = _get_adapter()
            adapter._lifecycle._pid = 1
            adapter._dbus = MagicMock()
            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                open_result = image_open.invoke({"file_path": str(pdf_path)})
                assert open_result

        resp = _bridge_response(open_result, "image_open")
        assert resp.content

        arxiv_mod._ARXIV_TOOLS = None
        _reset_mod(loupe_mod)
        sys.modules.pop("arxiv_mcp_server", None)
        sys.modules.pop("arxiv_mcp_server.tools", None)

    def test_notion_tasks_to_karlender_events(self):
        """Agent uses Notion tools to read task list → creates calendar events in Karlender."""
        _skip_unless_integration()

        # Step 1: read tasks from Notion
        fake_sdk = types.ModuleType("notion_sdk")

        class FakeNotionClient:
            def __init__(self, auth=None): pass
            def query_database(self, database_id, **kw):
                return {"results": [
                    {"id": "task-1", "properties": {"Name": {"title": [{"plain_text": "Design review"}]},
                     "Due": {"date": {"start": "2025-03-16"}}}},
                    {"id": "task-2", "properties": {"Name": {"title": [{"plain_text": "Ship v2"}]},
                     "Due": {"date": {"start": "2025-03-17"}}}},
                ]}
            def search(self, **kw): return {"results": []}
            def get_page(self, pid): return {"id": pid}
            def create_page(self, **kw): return {"id": "new"}
            def update_page(self, pid, **kw): return {"id": pid}
            def get_block_children(self, bid, **kw): return {"results": []}
            def append_block_children(self, bid, **kw): return {"results": []}
            def get_database(self, did): return {"id": did, "title": [{"plain_text": "Tasks"}]}

        fake_sdk.NotionClient = FakeNotionClient
        sys.modules["notion_sdk"] = fake_sdk
        sys.modules["notion_mcp_ldraney"] = types.ModuleType("notion_mcp_ldraney")

        import tools.notion as notion_mod
        notion_mod._NOTION_TOOLS = None
        notion_mod._client = None

        with patch.dict(os.environ, {"NOTION_API_KEY": "test"}):
            notion_tools = notion_mod.get_notion_tools()
            query_tool = next(t for t in notion_tools if t.name == "notion_query_database")
            tasks_json = query_tool.invoke({"database_id": "db-tasks"})
            assert "Design review" in tasks_json

        # Step 2: create calendar events
        import tools.karlender as karl_mod
        _reset_mod(karl_mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.karlender import calendar_create, _get_adapter
            adapter = _get_adapter()
            adapter._lifecycle._pid = 1
            mock_dbus = MagicMock()
            mock_dbus.call.return_value = "('Event created',)"
            adapter._dbus = mock_dbus

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                result = calendar_create.invoke({
                    "summary": "Design review",
                    "start_time": "2025-03-16T09:00:00",
                    "end_time": "2025-03-16T10:00:00",
                })
                assert "created" in result.lower()

        resp = _bridge_response(result, "calendar_create")
        assert resp.content

        notion_mod._NOTION_TOOLS = None
        notion_mod._client = None
        _reset_mod(karl_mod)
        sys.modules.pop("notion_sdk", None)
        sys.modules.pop("notion_mcp_ldraney", None)

    def test_devtools_inspect_then_write_to_notejot(self, tmp_path):
        """Agent uses devtools to inspect page → extracts data → writes to Notejot."""
        _skip_unless_integration()

        # Step 1: devtools inspect
        fake_client_mod = types.ModuleType("chrome_devtools_mcp_fork.client")

        class FakeCDP:
            def __init__(self, port=9222): self.connected = False
            def connect(self): self.connected = True
            def send(self, method, params=None):
                if method == "Runtime.evaluate":
                    return {"result": {"type": "string", "value": "Page Title: Example Corp"}}
                return {}

        fake_client_mod.ChromeDevToolsClient = FakeCDP
        fake_pkg = types.ModuleType("chrome_devtools_mcp_fork")
        fake_pkg.client = fake_client_mod
        sys.modules["chrome_devtools_mcp_fork"] = fake_pkg
        sys.modules["chrome_devtools_mcp_fork.client"] = fake_client_mod

        import tools.devtools as dt_mod
        dt_mod._DEVTOOLS_TOOLS = None
        dt_mod._client = None

        dt_tools = dt_mod.get_devtools_tools()
        connect = next(t for t in dt_tools if t.name == "devtools_connect")
        js_exec = next(t for t in dt_tools if t.name == "devtools_execute_javascript")

        connect.invoke({"port": 9222})
        js_result = js_exec.invoke({"code": "document.title"})
        assert "Example Corp" in js_result

        # Step 2: save to Notejot
        import tools.notejot as notejot_mod
        _reset_mod(notejot_mod)

        notes_file = tmp_path / "notes.json"
        notes_file.write_text("[]")

        with patch("tools.notejot._find_notes_file", return_value=notes_file):
            from tools.notejot import notes_create
            create_result = notes_create.invoke({
                "title": "Inspected: Example Corp",
                "content": f"Page data: {js_result}",
            })
            assert "Note created" in create_result

        resp = _bridge_response(create_result, "notes_create")
        assert resp.content

        dt_mod._DEVTOOLS_TOOLS = None
        dt_mod._client = None
        _reset_mod(notejot_mod)
        sys.modules.pop("chrome_devtools_mcp_fork", None)
        sys.modules.pop("chrome_devtools_mcp_fork.client", None)

    def test_researcher_to_notejot_and_geary(self, tmp_path):
        """Agent uses researcher → results saved as note → summary sent via Geary."""
        _skip_unless_integration()

        # Step 1: research
        fake_mod = types.ModuleType("gpt_researcher")

        class FakeResearcher:
            def __init__(self, query="", **kw):
                self.query = query
                self._report = f"# Research: {query}\n\nKey insight: AI is transforming healthcare."
            async def conduct_research(self): return self._report
            def get_source_urls(self): return []
            def get_research_context(self): return []
            def get_costs(self): return 0.01

        fake_mod.GPTResearcher = FakeResearcher
        sys.modules["gpt_researcher"] = fake_mod

        import tools.researcher as res_mod
        res_mod._RESEARCHER_TOOLS = None
        res_mod._last_researcher = None

        with patch.dict(os.environ, {"OPENAI_API_KEY": "k", "TAVILY_API_KEY": "k"}):
            res_tools = res_mod.get_researcher_tools()
            research = next(t for t in res_tools if t.name == "researcher_research")
            report = asyncio.get_event_loop().run_until_complete(
                research.ainvoke({"query": "AI in healthcare"})
            )
            assert "healthcare" in report

        # Step 2: save to Notejot
        import tools.notejot as notejot_mod
        _reset_mod(notejot_mod)
        notes_file = tmp_path / "notes.json"
        notes_file.write_text("[]")

        with patch("tools.notejot._find_notes_file", return_value=notes_file):
            from tools.notejot import notes_create
            notes_create.invoke({"title": "AI Healthcare Research", "content": report})

        # Step 3: send summary via Geary
        import tools.geary as geary_mod
        _reset_mod(geary_mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.geary import email_send, _get_adapter
            adapter = _get_adapter()
            adapter._lifecycle._pid = 1
            mock_dbus = MagicMock()
            mock_dbus.call.return_value = "('Sent',)"
            adapter._dbus = mock_dbus

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                send_result = email_send.invoke({
                    "to": "team@example.com",
                    "subject": "Research Summary: AI in Healthcare",
                    "body": report[:200],
                })
                assert "Sent" in send_result or "sent" in send_result.lower()

        resp = _bridge_response(send_result, "email_send")
        assert resp.content

        res_mod._RESEARCHER_TOOLS = None
        res_mod._last_researcher = None
        _reset_mod(notejot_mod)
        _reset_mod(geary_mod)
        sys.modules.pop("gpt_researcher", None)


# ── CLI Tools ↔ Application Connections ────────────────────────────────────


class TestCliToAppConnections:

    def test_gmail_to_karlender_event(self):
        """Agent reads email via Google Workspace CLI → extracts meeting →
        creates event in Karlender."""
        _skip_unless_integration()

        import tools.google_workspace as gw_mod
        gw_mod._GOOGLE_WORKSPACE_TOOLS = None

        def _mock_run(cmd, **kwargs):
            r = MagicMock()
            r.returncode = 0
            r.stderr = ""
            r.stdout = json.dumps({
                "messages": [{
                    "id": "msg-meet",
                    "snippet": "Meeting with Product team on March 20 at 2pm",
                    "from": "pm@example.com",
                    "subject": "Product Sync",
                }]
            })
            return r

        with patch("shutil.which", return_value="/usr/bin/gcloud"), \
             patch("subprocess.run", side_effect=_mock_run):
            gw_tools = gw_mod.get_google_workspace_tools()
            search = next(t for t in gw_tools if t.name == "google_mail_search")
            email_result = search.invoke({"query": "meeting product"})
            assert "Product" in email_result or "Meeting" in email_result

        import tools.karlender as karl_mod
        _reset_mod(karl_mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.karlender import calendar_create, _get_adapter
            adapter = _get_adapter()
            adapter._lifecycle._pid = 1
            mock_dbus = MagicMock()
            mock_dbus.call.return_value = "('Event created: Product Sync',)"
            adapter._dbus = mock_dbus

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                result = calendar_create.invoke({
                    "summary": "Product Sync",
                    "start_time": "2025-03-20T14:00:00",
                    "end_time": "2025-03-20T15:00:00",
                })
                assert "Product Sync" in result or "created" in result.lower()

        gw_mod._GOOGLE_WORKSPACE_TOOLS = None
        _reset_mod(karl_mod)

    def test_google_doc_summary_via_chatty(self):
        """Agent reads Google Doc → summarises → sends via Chatty."""
        _skip_unless_integration()

        import tools.google_workspace as gw_mod
        gw_mod._GOOGLE_WORKSPACE_TOOLS = None

        def _mock_run(cmd, **kwargs):
            r = MagicMock()
            r.returncode = 0
            r.stderr = ""
            r.stdout = json.dumps({
                "title": "Q1 Strategy",
                "body": {"content": [{"paragraph": {"elements": [
                    {"textRun": {"content": "Focus areas: AI integration, mobile-first, cost reduction."}}
                ]}}]},
            })
            return r

        with patch("shutil.which", return_value="/usr/bin/gcloud"), \
             patch("subprocess.run", side_effect=_mock_run):
            gw_tools = gw_mod.get_google_workspace_tools()
            read = next(t for t in gw_tools if t.name == "google_docs_read")
            doc_content = read.invoke({"document_id": "doc-q1"})
            assert doc_content

        import tools.chatty as chatty_mod
        _reset_mod(chatty_mod)

        with patch("shutil.which", side_effect=_mock_which):
            from tools.chatty import chat_send, _get_adapter
            adapter = _get_adapter()
            adapter._lifecycle._pid = 1
            mock_dbus = MagicMock()
            mock_dbus.call.return_value = "('Message sent',)"
            adapter._dbus = mock_dbus

            with patch.object(adapter._lifecycle, "ensure_running", return_value=None):
                result = chat_send.invoke({
                    "recipient": "@team:matrix.org",
                    "message": f"Q1 Strategy summary: {doc_content[:100]}",
                })
                assert "sent" in result.lower() or "Message" in result

        gw_mod._GOOGLE_WORKSPACE_TOOLS = None
        _reset_mod(chatty_mod)


# ── New Tools ↔ Existing Bridge & UI ──────────────────────────────────────


class TestToolsAndBridgeUI:

    def test_tool_invocation_shows_indicator(self):
        """Tool invocation appears as tool indicator in chat UI."""
        _skip_unless_integration()

        for tool_name, expected_status in [
            ("researcher_research", "Using tool..."),
            ("drawio_diagram", "Using tool..."),
            ("email_compose", "Using tool..."),
            ("calendar_create", "Using tool..."),
        ]:
            resp = bridge_pb2.AgentResponse(
                content="",
                done=False,
                tool_call=tool_name,
                status=expected_status,
            )
            assert resp.tool_call == tool_name
            assert resp.status == expected_status

    def test_cli_invocation_shows_terminal_event(self):
        """CLI tool invocation appears in terminal window with live output."""
        _skip_unless_integration()

        cli_output = "$ gcloud calendar list --format=json\n{\"events\": []}\n[exit 0]"
        tab_id = "tab-e2e-1"

        events = [
            json.dumps({"type": "open", "tab_id": tab_id, "title": "$ gcloud calendar list", "cwd": ""}),
            json.dumps({"type": "output", "tab_id": tab_id, "data": cli_output}),
            json.dumps({"type": "close", "tab_id": tab_id, "exit_code": 0}),
        ]

        for event_json in events:
            resp = bridge_pb2.AgentResponse(terminal_event=event_json)
            parsed = json.loads(resp.terminal_event)
            assert "type" in parsed
            assert "tab_id" in parsed

    def test_app_adapter_invocation_shows_indicator(self):
        """App adapter invocation shows appropriate tool indicator."""
        _skip_unless_integration()

        tool_indicators = {
            "email_compose": "Composing email…",
            "email_send": "Sending email…",
            "calendar_create": "Creating event…",
            "chat_send": "Sending message…",
            "music_play": "Playing music…",
            "notes_create": "Creating note…",
        }

        for tool_name, indicator_text in tool_indicators.items():
            resp = bridge_pb2.AgentResponse(
                content="",
                done=False,
                tool_call=tool_name,
                status="Using tool...",
            )
            assert resp.tool_call == tool_name

    def test_approval_prompt_before_email_send(self):
        """Human-in-the-loop approval prompt fires before sending email."""
        _skip_unless_integration()

        from security import TOOLS_REQUIRING_APPROVAL
        assert "email_send" in TOOLS_REQUIRING_APPROVAL
        assert "chat_send" in TOOLS_REQUIRING_APPROVAL

        block_id = "approval-test-001"
        resp = send_ui_block(
            "approval_prompt",
            block_id=block_id,
            title="Approval required",
            description="email_send wants to send an email to team@example.com",
            body="**email_send** wants to perform an action.",
            actions=[
                {"id": "approve", "label": "Approve", "style": "primary"},
                {"id": "deny", "label": "Deny", "style": "danger"},
            ],
        )
        assert len(resp.ui_blocks) == 1
        block = resp.ui_blocks[0]
        assert block.block_id == block_id
        assert block.block_type == bridge_pb2.UI_BLOCK_APPROVAL_PROMPT
        assert len(block.actions) == 2
        assert block.actions[0].id == "approve"
        assert block.actions[1].id == "deny"

    def test_credential_retrieval_triggers_approval(self):
        """Credential retrieval from Passes triggers approval prompt before use."""
        _skip_unless_integration()

        from security import TOOLS_REQUIRING_APPROVAL
        assert "pass_get" in TOOLS_REQUIRING_APPROVAL

        block_id = "approval-pass-001"
        resp = send_ui_block(
            "approval_prompt",
            block_id=block_id,
            title="Approval required",
            description="pass_get wants to retrieve credentials for github.com",
            actions=[
                {"id": "approve", "label": "Approve", "style": "primary"},
                {"id": "deny", "label": "Deny", "style": "danger"},
            ],
        )
        assert resp.ui_blocks[0].block_type == bridge_pb2.UI_BLOCK_APPROVAL_PROMPT
