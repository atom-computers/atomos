import pytest
from unittest.mock import patch, MagicMock
import bridge_pb2


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _clear_llm_cache():
    """Clear the module-level LLM cache between tests."""
    import agent_factory
    agent_factory._llm_cache.clear()
    agent_factory._resolution_cache.clear()


def _make_mock_agent():
    from langgraph.graph.state import CompiledStateGraph
    return MagicMock(spec=CompiledStateGraph)


# ---------------------------------------------------------------------------
# Agent factory tests
# ---------------------------------------------------------------------------

class TestAgentCache:
    """Verify create_agent_for_query builds agents correctly."""

    def setup_method(self):
        _clear_llm_cache()

    def test_same_model_reuses_llm_instance(self):
        """Repeated calls with the same model must reuse the cached LLM."""
        from agent_factory import create_agent_for_query
        with (
            patch("agent_factory._resolve_model", side_effect=lambda m: m),
            patch("agent_factory.create_react_agent", return_value=_make_mock_agent()),
            patch("agent_factory.set_local_model"),
        ):
            create_agent_for_query("llama3", [])
            create_agent_for_query("llama3", [])
            import agent_factory
            assert "llama3" in agent_factory._llm_cache, (
                "LLM should be cached after first call"
            )

    def test_different_models_return_different_agents(self):
        """Switching models must produce distinct agents."""
        agents = []
        with (
            patch("agent_factory._resolve_model", side_effect=lambda m: m),
            patch("agent_factory.create_react_agent", side_effect=lambda **kw: _make_mock_agent()),
            patch("agent_factory.set_local_model"),
        ):
            from agent_factory import create_agent_for_query
            a_llama = create_agent_for_query("llama3", [])
            a_qwen = create_agent_for_query("qwen3:8b", [])
            assert a_llama is not a_qwen, (
                "Different models must produce separate agent instances"
            )

    def test_switching_back_to_previous_model_reuses_llm(self):
        """Switching A→B→A must reuse A's LLM, not recreate it."""
        with (
            patch("agent_factory._resolve_model", side_effect=lambda m: m),
            patch("agent_factory.create_react_agent", return_value=_make_mock_agent()),
            patch("agent_factory.set_local_model"),
        ):
            from agent_factory import create_agent_for_query
            create_agent_for_query("llama3", [])
            create_agent_for_query("qwen3:8b", [])
            create_agent_for_query("llama3", [])
            import agent_factory
            assert len(agent_factory._llm_cache) == 2, (
                "Only two distinct LLM instances should be created"
            )

    def test_set_local_model_called_on_every_request(self):
        """Browser-tool global must be updated on every call."""
        with (
            patch("agent_factory._resolve_model", side_effect=lambda m: m),
            patch("agent_factory.create_react_agent", return_value=_make_mock_agent()),
            patch("agent_factory.set_local_model") as mock_set,
        ):
            from agent_factory import create_agent_for_query
            create_agent_for_query("llama3", [])
            create_agent_for_query("llama3", [])
            assert mock_set.call_count == 2, (
                "set_local_model must be called on every request so the "
                "browser tool always uses the current model"
            )


def test_proto_serialization():
    """Test basic bridge_pb2 message instantiation"""
    req = bridge_pb2.AgentRequest(
        prompt="Test",
        model="llama3",
        images=[],
        context=[1, 2, 3]
    )
    assert req.prompt == "Test"
    assert req.model == "llama3"
    assert req.context == [1, 2, 3]

    res = bridge_pb2.AgentResponse(
        content="Response",
        done=True,
        status="Success"
    )
    assert res.content == "Response"
    assert res.done is True
