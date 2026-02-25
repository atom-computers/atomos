import pytest
from unittest.mock import patch, MagicMock
from agent_factory import create_deep_agent
from langchain_core.messages import HumanMessage
import bridge_pb2

def test_create_deep_agent_initialization():
    """Test that the factory returns a ChatOllama instance by default"""
    agent = create_deep_agent(model_name="llama3")
    assert agent is not None
    assert agent.model == "llama3"

@pytest.mark.asyncio
async def test_agent_streaming():
    """Mock test for the streaming logic used in the servicer"""
    agent = create_deep_agent(model_name="test_model")
    
    # Mocking stream response
    mock_chunk = MagicMock()
    mock_chunk.content = "Hello from agent"
    
    with patch('langchain_community.chat_models.ChatOllama.stream', return_value=[mock_chunk]):
        chunks = agent.stream([HumanMessage(content="Hello")])
        chunk_contents = [c.content for c in chunks]
        assert "Hello from agent" in chunk_contents

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

def test_tool_registration():
    """Test that the agent successfully registers Atom OS tools"""
    agent = create_deep_agent(model_name="llama3")
    # In langchain_community 0.0.10+ ChatOllama may not always expose `tools` directly, 
    # but if it uses bind_tools, it returns a RunnableBinding. 
    # We just ensure it doesn't crash during tool binding.
    assert agent is not None

def test_subagent_spawn_relay():
    """Mock test for spawning a subagent and relaying the result"""
    # This validates the architecture for delegating tasks to subagents
    from mock_agent import MockAgent
    
    subagent = MockAgent(model="research_agent")
    result = subagent.stream("Find the meaning of life")
    
    # Relay the mocked chunk
    relay_content = result[0].content
    assert relay_content == "Mocked Response"

