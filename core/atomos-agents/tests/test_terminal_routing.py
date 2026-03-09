"""
Tests for terminal output routing in server.py (TASKLIST_2 §2).

Verifies that:
- terminal output goes to the terminal window via terminal_event, not chat content
- read_file / search_in_files output is suppressed from chat (editor operations)
- Other tool output still appears as markdown code blocks in content
- Tool scope cleanup: internal-only tools are excluded from discovery
"""
import asyncio
import json
import pytest
from unittest.mock import MagicMock, patch
from langgraph.graph.state import CompiledStateGraph


def _make_chunk(text=None, tool_name=None, tool_output=None, node="agent"):
    """Build a minimal AIMessageChunk-like mock."""
    chunk = MagicMock()
    if tool_name:
        chunk.content_blocks = [
            {"type": "tool_call_chunk", "name": tool_name, "args": "", "id": "x", "index": 0}
        ]
        chunk.content = ""
        chunk.tool_call_chunks = [{"name": tool_name}]
    elif text:
        chunk.content_blocks = [{"type": "text", "text": text}]
        chunk.content = text
        chunk.tool_call_chunks = []
    elif tool_output is not None:
        chunk.content_blocks = []
        chunk.content = tool_output
        chunk.tool_call_chunks = []
    else:
        chunk.content_blocks = []
        chunk.content = ""
        chunk.tool_call_chunks = []
    return chunk


def _make_request(prompt="test", model="llama3"):
    req = MagicMock()
    req.prompt = prompt
    req.model = model
    req.context = []
    req.images = []
    req.history = []
    return req


def _make_mock_agent(chunks_and_nodes):
    async def fake_astream(input, config, stream_mode=None, **kwargs):
        for chunk, metadata in chunks_and_nodes:
            yield chunk, metadata

    mock_agent = MagicMock(spec=CompiledStateGraph)
    mock_agent.astream = fake_astream
    return mock_agent


async def _collect(servicer, request):
    return [r async for r in servicer.StreamAgentTurn(request, context=MagicMock())]


def _run(servicer, request):
    return asyncio.run(_collect(servicer, request))


def _run_with_chunks(chunks_and_nodes):
    mock_agent = _make_mock_agent(chunks_and_nodes)
    with (
        patch("server.create_agent_for_query", return_value=mock_agent),
        patch("server.retrieve_tools", return_value=[]),
        patch("server.ensure_registry"),
    ):
        from server import AgentServiceServicer
        servicer = AgentServiceServicer()
        return _run(servicer, _make_request())


class TestTerminalRouting:
    """Verify terminal tool output is routed as terminal events."""

    def test_terminal_emits_terminal_events(self):
        tool_call_chunk = _make_chunk(tool_name="terminal")
        tool_output_chunk = _make_chunk(tool_output="$ ls -la\ntotal 42\ndrwxr-xr-x 2 user user 4096")

        responses = _run_with_chunks([
            (tool_call_chunk, {"langgraph_node": "agent"}),
            (tool_output_chunk, {"langgraph_node": "tools"}),
        ])

        terminal_responses = [r for r in responses if r.terminal_event]
        assert len(terminal_responses) >= 3, (
            f"Expected open+output+close terminal events, got {len(terminal_responses)}"
        )

        events = [json.loads(r.terminal_event) for r in terminal_responses]
        types = [e["type"] for e in events]
        assert "open" in types
        assert "output" in types
        assert "close" in types

        open_ev = next(e for e in events if e["type"] == "open")
        assert "ls -la" in open_ev["title"]

        output_ev = next(e for e in events if e["type"] == "output")
        assert "total 42" in output_ev["data"]

        close_ev = next(e for e in events if e["type"] == "close")
        assert close_ev["exit_code"] == 0

    def test_terminal_no_content_in_chat(self):
        tool_call_chunk = _make_chunk(tool_name="terminal")
        tool_output_chunk = _make_chunk(tool_output="$ echo hello\nhello")

        responses = _run_with_chunks([
            (tool_call_chunk, {"langgraph_node": "agent"}),
            (tool_output_chunk, {"langgraph_node": "tools"}),
        ])

        content_responses = [
            r for r in responses
            if r.content and "hello" in r.content and not r.done
        ]
        assert len(content_responses) == 0, (
            "Terminal output should NOT appear as chat content"
        )

    def test_terminal_nonzero_exit(self):
        tool_call_chunk = _make_chunk(tool_name="terminal")
        tool_output_chunk = _make_chunk(tool_output="$ false\n[exit 1]")

        responses = _run_with_chunks([
            (tool_call_chunk, {"langgraph_node": "agent"}),
            (tool_output_chunk, {"langgraph_node": "tools"}),
        ])

        terminal_responses = [r for r in responses if r.terminal_event]
        events = [json.loads(r.terminal_event) for r in terminal_responses]
        close_ev = next(e for e in events if e["type"] == "close")
        assert close_ev["exit_code"] == 1


class TestSilentEditorTools:
    """Verify read_file and search_in_files output is suppressed from chat."""

    def test_read_file_output_suppressed(self):
        tool_call_chunk = _make_chunk(tool_name="read_file")
        tool_output_chunk = _make_chunk(tool_output="line1\nline2\nline3")

        responses = _run_with_chunks([
            (tool_call_chunk, {"langgraph_node": "agent"}),
            (tool_output_chunk, {"langgraph_node": "tools"}),
        ])

        content_responses = [
            r for r in responses
            if r.content and "line1" in r.content and not r.done
        ]
        assert len(content_responses) == 0, (
            "read_file output should not appear in chat"
        )

    def test_search_in_files_output_suppressed(self):
        tool_call_chunk = _make_chunk(tool_name="search_in_files")
        tool_output_chunk = _make_chunk(tool_output="src/main.rs:5: fn main()")

        responses = _run_with_chunks([
            (tool_call_chunk, {"langgraph_node": "agent"}),
            (tool_output_chunk, {"langgraph_node": "tools"}),
        ])

        content_responses = [
            r for r in responses
            if r.content and "main" in r.content and not r.done
        ]
        assert len(content_responses) == 0


class TestOtherToolsUnchanged:
    """Verify browser and generic tool output still goes to chat as before."""

    def test_browse_web_output_in_chat(self):
        tool_call_chunk = _make_chunk(tool_name="browse_web")
        tool_output_chunk = _make_chunk(tool_output="Page title: Example")

        responses = _run_with_chunks([
            (tool_call_chunk, {"langgraph_node": "agent"}),
            (tool_output_chunk, {"langgraph_node": "tools"}),
        ])

        content_responses = [r for r in responses if r.content and "Example" in r.content]
        assert len(content_responses) >= 1, (
            "browse_web output should still appear in chat"
        )

    def test_create_file_output_in_chat(self):
        tool_call_chunk = _make_chunk(tool_name="create_file")
        tool_output_chunk = _make_chunk(tool_output="Created /tmp/test.txt")

        responses = _run_with_chunks([
            (tool_call_chunk, {"langgraph_node": "agent"}),
            (tool_output_chunk, {"langgraph_node": "tools"}),
        ])

        content_responses = [r for r in responses if r.content and "Created" in r.content]
        assert len(content_responses) >= 1


class TestToolScopeCleanup:
    """Verify tool registry filters out internal-only tools."""

    def test_internal_tools_excluded(self):
        with patch("tool_registry._discover_atomos_tools", return_value=[]):
            mock_tools = [
                {"name": "terminal", "description": "run shell", "source": "atomos", "tool": MagicMock()},
                {"name": "check_sync_status", "description": "internal sync check", "source": "atomos", "tool": MagicMock()},
                {"name": "query_context_manager", "description": "internal context query", "source": "atomos", "tool": MagicMock()},
                {"name": "browse_web", "description": "browse web", "source": "atomos", "tool": MagicMock()},
            ]
            with patch("tool_registry._discover_deepagent_tools", return_value=mock_tools):
                from tool_registry import discover_all_tools
                result = discover_all_tools()

        names = [t["name"] for t in result]
        assert "terminal" in names
        assert "browse_web" not in names
        assert "check_sync_status" not in names, "check_sync_status should be filtered out"
        assert "query_context_manager" not in names, "query_context_manager should be filtered out"

    def test_always_available_tools_only_editor_and_terminal(self):
        from tool_registry import _ALWAYS_AVAILABLE_TOOLS
        assert "terminal" in _ALWAYS_AVAILABLE_TOOLS
        assert "code_editor" in _ALWAYS_AVAILABLE_TOOLS
        assert len(_ALWAYS_AVAILABLE_TOOLS) == 2

    def test_disabled_tools_are_filtered_out(self):
        from tool_registry import retrieve_tools
        fake_tools = {
            "code_editor": MagicMock(name="code_editor"),
            "create_file": MagicMock(name="create_file"),
            "edit_file": MagicMock(name="edit_file"),
            "read_file": MagicMock(name="read_file"),
            "search_in_files": MagicMock(name="search_in_files"),
            "terminal": MagicMock(name="terminal"),
        }
        with (
            patch("tool_registry._tool_objects", fake_tools),
            patch("tool_registry._embed", return_value=[[0.1, 0.2]]),
            patch("tool_registry._surreal_query", return_value=[{
                "status": "OK",
                "result": [
                    {"name": "create_file", "score": 0.99},
                    {"name": "edit_file", "score": 0.98},
                    {"name": "code_editor", "score": 0.95},
                ],
            }]),
        ):
            selected = retrieve_tools("do coding work")

        selected_names = {getattr(t, "_mock_name", None) for t in selected}
        assert "code_editor" in selected_names
        assert "create_file" not in selected_names
        assert "edit_file" not in selected_names
        assert "read_file" not in selected_names
        assert "search_in_files" not in selected_names
        assert "terminal" in selected_names
