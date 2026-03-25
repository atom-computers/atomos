"""
Tests for terminal event emission from server.py.

Verifies the terminal event lifecycle:
  - "open" event is emitted EARLY from the agent node (when the agent decides
    to call the terminal tool), BEFORE the command executes.  This gives the
    applet time to launch COSMIC Terminal and attach to the tmux session.
  - "output" and "close" events are emitted from the tools node after the
    command completes.
  - All events share the same tab_id.
  - Terminal output does NOT leak into the content field.
  - Exit codes and command titles are parsed correctly.
"""

import asyncio
import json
import pytest
from unittest.mock import MagicMock, patch
from langgraph.graph.state import CompiledStateGraph

from server import _parse_exit_code, _extract_command, _next_tab_id, _ToolCallFilter


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_chunk(text=None, tool_name=None, content_str=None):
    chunk = MagicMock()
    if tool_name:
        chunk.tool_call_chunks = [{"name": tool_name, "args": "", "id": "x", "index": 0}]
        chunk.content_blocks = [{"type": "tool_call_chunk", "name": tool_name, "args": "", "id": "x", "index": 0}]
        chunk.content = ""
    elif text:
        chunk.tool_call_chunks = []
        chunk.content_blocks = [{"type": "text", "text": text}]
        chunk.content = text
    elif content_str is not None:
        chunk.tool_call_chunks = []
        chunk.content_blocks = []
        chunk.content = content_str
    else:
        chunk.tool_call_chunks = []
        chunk.content_blocks = []
        chunk.content = ""
    return chunk


def _make_request(prompt="run ls", model="llama3"):
    req = MagicMock()
    req.prompt = prompt
    req.model = model
    req.context = []
    req.images = []
    req.history = []
    return req


def _make_mock_agent(chunks_and_nodes):
    async def fake_astream(input, config, stream_mode=None, **kwargs):
        for item in chunks_and_nodes:
            yield item

    mock_agent = MagicMock(spec=CompiledStateGraph)
    mock_agent.astream = fake_astream
    return mock_agent


async def _collect(servicer, request):
    return [r async for r in servicer.StreamAgentTurn(request, context=MagicMock())]


def _run(servicer, request):
    return asyncio.run(_collect(servicer, request))


def _run_terminal_scenario(tool_output):
    """Simulate: agent calls 'terminal' → tools node emits tool_output."""
    tool_call_chunk = _make_chunk(tool_name="terminal")
    agent_metadata = {"langgraph_node": "agent"}

    tool_result_chunk = _make_chunk(content_str=tool_output)
    tools_metadata = {"langgraph_node": "tools"}

    chunks = [
        (tool_call_chunk, agent_metadata),
        (tool_result_chunk, tools_metadata),
    ]
    mock_agent = _make_mock_agent(chunks)

    with (
        patch("server.create_agent_for_query", return_value=mock_agent),
        patch("server.retrieve_tools", return_value=[]),
        patch("server.ensure_registry"),
    ):
        from server import AgentServiceServicer
        servicer = AgentServiceServicer()
        return _run(servicer, _make_request())


def _terminal_events(responses):
    """Extract parsed terminal events from responses."""
    events = []
    for r in responses:
        if r.terminal_event:
            events.append(json.loads(r.terminal_event))
    return events


# ---------------------------------------------------------------------------
# Pure function tests
# ---------------------------------------------------------------------------


class TestParseExitCode:

    def test_success(self):
        assert _parse_exit_code("$ ls\nfile1\nfile2") == 0

    def test_nonzero_exit(self):
        assert _parse_exit_code("$ false\n[exit 1]") == 1

    def test_high_exit_code(self):
        assert _parse_exit_code("$ segfault\n[exit 139]") == 139

    def test_timeout(self):
        assert _parse_exit_code("$ sleep 999\n[timed out after 120s]") == 124

    def test_empty_output(self):
        assert _parse_exit_code("") == 0

    def test_multiline_with_exit_not_last(self):
        output = "$ cmd\nsome output\n[exit 2]\nmore trailing text"
        assert _parse_exit_code(output) == 0

    def test_exit_code_on_last_line(self):
        output = "$ cmd\nsome output\n[exit 42]"
        assert _parse_exit_code(output) == 42


class TestExtractCommand:

    def test_simple_command(self):
        assert _extract_command("$ ls -la\nfile1") == "ls -la"

    def test_no_prompt(self):
        assert _extract_command("just output") == "Shell"

    def test_empty_string(self):
        assert _extract_command("") == "Shell"

    def test_multiple_dollar_lines(self):
        assert _extract_command("$ echo hello\n$ echo world") == "echo hello"

    def test_whitespace_after_dollar(self):
        assert _extract_command("$   spaced  ") == "spaced"


# ---------------------------------------------------------------------------
# Terminal event emission — end-to-end through the server
# ---------------------------------------------------------------------------


class TestTerminalEventEmission:
    """Verify the new early-open event flow:
    1. Agent node detects tool_call=terminal → emits "open" (placeholder title)
    2. Tools node gets output → emits "output" (title), "output" (full), "close"
    """

    def test_four_events_emitted(self):
        """Terminal tool produces 4 events: open, output(title), output(full), close."""
        responses = _run_terminal_scenario("$ ls\nfile1\nfile2")
        events = _terminal_events(responses)
        assert len(events) == 4

    def test_event_order(self):
        """Events: open → output (title) → output (full) → close."""
        responses = _run_terminal_scenario("$ ls\nfile1")
        events = _terminal_events(responses)
        assert events[0]["type"] == "open"
        assert events[1]["type"] == "output"
        assert events[2]["type"] == "output"
        assert events[3]["type"] == "close"

    def test_open_emitted_from_agent_node(self):
        """The open event is emitted before the tools node processes output,
        i.e. in the same batch as the tool_call response."""
        responses = _run_terminal_scenario("$ echo hello\nhello")
        te_indices = [
            i for i, r in enumerate(responses) if r.terminal_event
        ]
        tool_call_indices = [
            i for i, r in enumerate(responses) if r.tool_call == "terminal"
        ]
        assert te_indices, "should have terminal events"
        assert tool_call_indices, "should have tool_call responses"
        open_idx = te_indices[0]
        last_tc_idx = tool_call_indices[-1]
        assert open_idx <= last_tc_idx + 1, (
            "open event should be emitted near the tool_call, before tool output"
        )

    def test_open_event_has_placeholder_title(self):
        """The early open event title is '$ ...' (command not known yet)."""
        responses = _run_terminal_scenario("$ pip install torch\n...")
        events = _terminal_events(responses)
        assert events[0]["title"] == "$ ..."

    def test_first_output_event_has_command_title(self):
        """The first output event from the tools node contains the command."""
        responses = _run_terminal_scenario("$ pip install torch\n...")
        events = _terminal_events(responses)
        assert events[1]["data"] == "$ pip install torch"

    def test_second_output_event_has_full_content(self):
        """The second output event contains the full tool output."""
        output = "$ cat /etc/hostname\nmy-machine"
        responses = _run_terminal_scenario(output)
        events = _terminal_events(responses)
        assert events[2]["data"] == output

    def test_all_tab_ids_match(self):
        """All events share the same tab_id (pre-allocated in agent node)."""
        responses = _run_terminal_scenario("$ echo hello\nhello")
        events = _terminal_events(responses)
        tab_id = events[0]["tab_id"]
        assert tab_id
        for ev in events[1:]:
            assert ev["tab_id"] == tab_id

    def test_close_event_exit_code_zero(self):
        """Successful command has exit_code 0."""
        responses = _run_terminal_scenario("$ echo ok\nok")
        events = _terminal_events(responses)
        assert events[-1]["exit_code"] == 0

    def test_close_event_nonzero_exit(self):
        """Failed command propagates exit code."""
        responses = _run_terminal_scenario("$ make\nerror: ...\n[exit 2]")
        events = _terminal_events(responses)
        assert events[-1]["exit_code"] == 2

    def test_close_event_timeout(self):
        """Timed-out command has exit_code 124."""
        responses = _run_terminal_scenario("$ sleep 999\n[timed out after 120s]")
        events = _terminal_events(responses)
        assert events[-1]["exit_code"] == 124

    def test_terminal_output_not_in_content(self):
        """Terminal tool output must NOT appear in the content field of
        terminal_event responses."""
        responses = _run_terminal_scenario("$ whoami\nroot")
        for r in responses:
            if r.terminal_event:
                assert r.content == ""

    def test_no_terminal_events_for_non_terminal_tool(self):
        """Tools not in _TERMINAL_TOOLS should not emit terminal_event."""
        tool_call_chunk = _make_chunk(tool_name="read_file")
        agent_metadata = {"langgraph_node": "agent"}

        tool_result_chunk = _make_chunk(content_str="file contents here")
        tools_metadata = {"langgraph_node": "tools"}

        chunks = [
            (tool_call_chunk, agent_metadata),
            (tool_result_chunk, tools_metadata),
        ]
        mock_agent = _make_mock_agent(chunks)

        with (
            patch("server.create_agent_for_query", return_value=mock_agent),
            patch("server.retrieve_tools", return_value=[]),
            patch("server.ensure_registry"),
        ):
            from server import AgentServiceServicer
            servicer = AgentServiceServicer()
            responses = _run(servicer, _make_request())

        events = _terminal_events(responses)
        assert len(events) == 0


class TestTerminalEventJson:
    """Verify the JSON structure matches what the Rust applet deserializes."""

    def test_open_event_schema(self):
        responses = _run_terminal_scenario("$ ls\nfiles")
        events = _terminal_events(responses)
        open_ev = events[0]
        assert set(open_ev.keys()) == {"type", "tab_id", "title", "cwd"}
        assert open_ev["type"] == "open"
        assert isinstance(open_ev["tab_id"], str)
        assert isinstance(open_ev["title"], str)
        assert isinstance(open_ev["cwd"], str)

    def test_output_event_schema(self):
        responses = _run_terminal_scenario("$ ls\nfiles")
        events = _terminal_events(responses)
        output_ev = events[1]
        assert set(output_ev.keys()) == {"type", "tab_id", "data"}
        assert output_ev["type"] == "output"

    def test_close_event_schema(self):
        responses = _run_terminal_scenario("$ ls\nfiles")
        events = _terminal_events(responses)
        close_ev = events[-1]
        assert set(close_ev.keys()) == {"type", "tab_id", "exit_code"}
        assert close_ev["type"] == "close"
        assert isinstance(close_ev["exit_code"], int)

    def test_events_are_valid_json(self):
        """Every terminal_event field is parseable JSON."""
        responses = _run_terminal_scenario("$ echo test\ntest")
        for r in responses:
            if r.terminal_event:
                parsed = json.loads(r.terminal_event)
                assert "type" in parsed
                assert "tab_id" in parsed


class TestTabIdIncrement:

    def test_successive_commands_get_different_tab_ids(self):
        """Two terminal invocations produce different tab_ids."""
        r1 = _run_terminal_scenario("$ echo 1\n1")
        r2 = _run_terminal_scenario("$ echo 2\n2")
        ev1 = _terminal_events(r1)
        ev2 = _terminal_events(r2)
        assert ev1[0]["tab_id"] != ev2[0]["tab_id"]


class TestPendingTerminalTabCleanup:
    """Verify that pending_terminal_tab is cleaned up on errors."""

    def test_error_closes_pending_tab(self):
        """If the agent errors with a pending terminal tab, a close event
        is emitted with exit_code -1."""
        tool_call_chunk = _make_chunk(tool_name="terminal")
        agent_metadata = {"langgraph_node": "agent"}

        chunks = [(tool_call_chunk, agent_metadata)]

        async def raising_astream(*args, **kwargs):
            for c in chunks:
                yield c
            raise RuntimeError("simulated crash")

        mock_agent = MagicMock(spec=CompiledStateGraph)
        mock_agent.astream = raising_astream

        with (
            patch("server.create_agent_for_query", return_value=mock_agent),
            patch("server.retrieve_tools", return_value=[]),
            patch("server.ensure_registry"),
        ):
            from server import AgentServiceServicer
            servicer = AgentServiceServicer()
            responses = asyncio.run(_collect(servicer, _make_request()))

        events = _terminal_events(responses)
        types = [e["type"] for e in events]
        assert "open" in types
        assert "close" in types
        close_ev = next(e for e in events if e["type"] == "close")
        assert close_ev["exit_code"] == -1

    def test_normal_stream_end_closes_pending_tab(self):
        """If stream ends normally but tool never produced output for a
        pending terminal tab, a close event with exit_code -1 is emitted."""
        tool_call_chunk = _make_chunk(tool_name="terminal")
        agent_metadata = {"langgraph_node": "agent"}

        chunks = [(tool_call_chunk, agent_metadata)]
        mock_agent = _make_mock_agent(chunks)

        with (
            patch("server.create_agent_for_query", return_value=mock_agent),
            patch("server.retrieve_tools", return_value=[]),
            patch("server.ensure_registry"),
        ):
            from server import AgentServiceServicer
            servicer = AgentServiceServicer()
            responses = asyncio.run(_collect(servicer, _make_request()))

        events = _terminal_events(responses)
        types = [e["type"] for e in events]
        assert "open" in types
        assert "close" in types
        close_ev = next(e for e in events if e["type"] == "close")
        assert close_ev["exit_code"] == -1


class TestEarlyOpenTiming:
    """Verify the open event is emitted BEFORE tool execution completes."""

    def test_open_before_output(self):
        """The open event index in the response stream is before any output event."""
        responses = _run_terminal_scenario("$ echo timing\ntiming")
        open_idx = None
        first_output_idx = None
        for i, r in enumerate(responses):
            if r.terminal_event:
                ev = json.loads(r.terminal_event)
                if ev["type"] == "open" and open_idx is None:
                    open_idx = i
                elif ev["type"] == "output" and first_output_idx is None:
                    first_output_idx = i
        assert open_idx is not None, "open event missing"
        assert first_output_idx is not None, "output event missing"
        assert open_idx < first_output_idx, (
            f"open event (idx={open_idx}) should precede output (idx={first_output_idx})"
        )

    def test_open_before_tools_node_responses(self):
        """The open event is emitted from the agent node, so it should
        appear before any tools-node content."""
        responses = _run_terminal_scenario("$ date\nThu Mar 12")
        open_idx = None
        for i, r in enumerate(responses):
            if r.terminal_event:
                ev = json.loads(r.terminal_event)
                if ev["type"] == "open":
                    open_idx = i
                    break

        # The open event should be near the start (after tool_call responses).
        # Specifically, it should precede the output and close events.
        assert open_idx is not None
        for i, r in enumerate(responses):
            if r.terminal_event:
                ev = json.loads(r.terminal_event)
                if ev["type"] in ("output", "close"):
                    assert i > open_idx
