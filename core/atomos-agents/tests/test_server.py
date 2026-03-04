"""
Tests for AgentServiceServicer in server.py.

Catches regressions like:
  - Wrong streaming API (stream_events vs astream)
  - Tools are async — agent.stream() raises "StructuredTool does not support
    sync invocation"; server must use agent.astream() via grpc.aio
  - Missing 'session_id' in config['configurable']
  - thread_id not scoped per model (model switches not taking effect)
"""
import asyncio
import pytest
from unittest.mock import MagicMock, patch
from langgraph.graph.state import CompiledStateGraph


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _make_chunk(text=None, tool_name=None):
    """Build a minimal AIMessageChunk-like mock for stream_mode='messages'."""
    chunk = MagicMock()
    if tool_name:
        chunk.content_blocks = [{"type": "tool_call_chunk", "name": tool_name, "args": "", "id": "x", "index": 0}]
        chunk.content = ""
    elif text:
        chunk.content_blocks = [{"type": "text", "text": text}]
        chunk.content = text
    else:
        chunk.content_blocks = []
        chunk.content = ""
    return chunk


def _make_request(prompt="Hello", model="llama3", context=(), images=()):
    req = MagicMock()
    req.prompt = prompt
    req.model = model
    req.context = list(context)
    req.images = list(images)
    return req


def _make_mock_agent(chunks_and_nodes, captured_calls=None):
    """Return a mock agent whose astream() yields the given (chunk, metadata) pairs."""
    async def fake_astream(input, config, stream_mode=None, **kwargs):
        if captured_calls is not None:
            captured_calls.append({"config": config, "stream_mode": stream_mode})
        for item in chunks_and_nodes:
            yield item

    mock_agent = MagicMock(spec=CompiledStateGraph)
    mock_agent.astream = fake_astream
    return mock_agent


async def _collect(servicer, request):
    """Collect all AgentResponse protos from an async-generator servicer method."""
    return [r async for r in servicer.StreamAgentTurn(request, context=MagicMock())]


def _run(servicer, request):
    return asyncio.run(_collect(servicer, request))


# ---------------------------------------------------------------------------
# Interface contract: CompiledStateGraph must expose astream()
# ---------------------------------------------------------------------------

class TestAgentInterface:
    """Verify the graph interface assumptions the server relies on."""

    def test_compiled_state_graph_has_astream(self):
        """astream() must exist — it's the async API required for async tools."""
        assert hasattr(CompiledStateGraph, "astream"), (
            "CompiledStateGraph must have .astream()"
        )

    def test_compiled_state_graph_has_stream(self):
        """stream() still exists (but is not used because tools are async)."""
        assert hasattr(CompiledStateGraph, "stream")

    def test_compiled_state_graph_has_no_stream_events(self):
        """stream_events does NOT exist on CompiledStateGraph.

        Calling agent.stream_events() would raise AttributeError at runtime.
        """
        assert not hasattr(CompiledStateGraph, "stream_events"), (
            "stream_events unexpectedly appeared on CompiledStateGraph — "
            "update server.py to handle this API change."
        )

    def test_specced_mock_rejects_stream_events(self):
        """A spec'd mock raises AttributeError for stream_events, matching runtime."""
        specced = MagicMock(spec=CompiledStateGraph)
        with pytest.raises(AttributeError):
            _ = specced.stream_events


# ---------------------------------------------------------------------------
# Config validation
# ---------------------------------------------------------------------------

class TestServicerConfig:
    """Verify the config dict passed into .astream() is correct."""

    def _run_servicer(self, stream_chunks, model="llama3"):
        captured_calls = []
        mock_agent = _make_mock_agent(stream_chunks, captured_calls)

        with (
            patch("server.create_agent_for_query", return_value=mock_agent),
            patch("server.retrieve_tools", return_value=[]),
            patch("server.ensure_registry"),
        ):
            from server import AgentServiceServicer
            servicer = AgentServiceServicer()
            responses = _run(servicer, _make_request(model=model))

        return responses, captured_calls

    def test_uses_astream_not_stream_events(self):
        """Server must call .astream(), not .stream_events()."""
        _, calls = self._run_servicer([])
        assert len(calls) == 1, "agent.astream() should have been called exactly once"

    def test_stream_mode_is_messages(self):
        """stream_mode must be 'messages' to get (chunk, metadata) token pairs."""
        _, calls = self._run_servicer([])
        assert calls[0]["stream_mode"] == "messages", (
            "stream_mode must be 'messages' — got: " + repr(calls[0]["stream_mode"])
        )

    def test_config_contains_session_id(self):
        """config['configurable'] must include session_id."""
        _, calls = self._run_servicer([])
        configurable = calls[0]["config"].get("configurable", {})
        assert "session_id" in configurable, (
            "config['configurable'] must contain 'session_id'."
        )
        assert "thread_id" in configurable

    def test_config_session_id_matches_thread_id(self):
        """session_id and thread_id should be the same value."""
        _, calls = self._run_servicer([])
        cfg = calls[0]["config"]["configurable"]
        assert cfg["session_id"] == cfg["thread_id"]

    def test_config_thread_id_is_scoped_by_model(self):
        """thread_id/session_id must include the requested model name so that
        switching models in the applet immediately uses a fresh session."""
        _, captured_calls = self._run_servicer([], model="qwen3:8b")

        cfg = captured_calls[0]["config"]["configurable"]
        assert cfg["thread_id"] == "default:qwen3:8b"
        assert cfg["session_id"] == "default:qwen3:8b"


# ---------------------------------------------------------------------------
# Streaming output mapping
# ---------------------------------------------------------------------------

class TestServicerStreaming:
    """Verify the servicer maps .astream() output to AgentResponse protos."""

    def _run_with_chunks(self, chunks_and_nodes):
        mock_agent = _make_mock_agent(chunks_and_nodes)

        with (
            patch("server.create_agent_for_query", return_value=mock_agent),
            patch("server.retrieve_tools", return_value=[]),
            patch("server.ensure_registry"),
        ):
            from server import AgentServiceServicer
            servicer = AgentServiceServicer()
            return _run(servicer, _make_request())

    def test_tool_call_chunk_emits_tool_call(self):
        chunk = _make_chunk(tool_name="read_file")
        metadata = {"langgraph_node": "agent"}
        responses = self._run_with_chunks([(chunk, metadata)])
        tool_responses = [r for r in responses if r.tool_call]
        assert len(tool_responses) >= 1
        assert "read_file" in tool_responses[0].tool_call

    def test_text_chunk_emits_content(self):
        chunk = _make_chunk(text="partial response")
        metadata = {"langgraph_node": "agent"}
        responses = self._run_with_chunks([(chunk, metadata)])
        content_responses = [r for r in responses if r.content]
        assert any("partial response" in r.content for r in content_responses)

    def test_tools_node_clears_tool_call(self):
        chunk = _make_chunk()
        metadata = {"langgraph_node": "tools"}
        responses = self._run_with_chunks([(chunk, metadata)])
        tools_responses = [r for r in responses if r.status == "Thinking..." and not r.done]
        assert any(r.tool_call == "" for r in tools_responses)

    def test_always_ends_with_done_true(self):
        responses = self._run_with_chunks([])
        assert responses[-1].done is True

    def test_exception_returns_done_true_with_error(self):
        """Runtime errors should yield a done=True error response, not crash."""
        async def raising_astream(*args, **kwargs):
            raise RuntimeError("boom")
            yield  # makes the function an async generator

        mock_agent = MagicMock(spec=CompiledStateGraph)
        mock_agent.astream = raising_astream

        with (
            patch("server.create_agent_for_query", return_value=mock_agent),
            patch("server.retrieve_tools", return_value=[]),
            patch("server.ensure_registry"),
        ):
            from server import AgentServiceServicer
            servicer = AgentServiceServicer()
            responses = _run(servicer, _make_request())

        assert responses[-1].done is True
        assert "boom" in responses[-1].content
        assert responses[-1].status == "Error"
