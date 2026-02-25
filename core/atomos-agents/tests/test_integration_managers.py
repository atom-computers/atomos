import pytest
from unittest.mock import patch, MagicMock
from langchain_core.messages import HumanMessage
from agent_factory import create_deep_agent

# Mock tools that would normally hit the respective managers' gRPC/REST APIs
def mock_retrieve_context(project_name: str) -> str:
    return f"MOCKED_CONTEXT: {project_name} contains 3 submodules and uses Rust."

def mock_create_task(task_name: str, payload: dict) -> str:
    return f"MOCKED_TASK_ID: 999 for {task_name}"

def mock_check_sync_status(file_path: str) -> str:
    return f"MOCKED_SYNC: {file_path} is fully synced."

def mock_secure_action(action: str) -> str:
    return f"MOCKED_SECURITY: Action '{action}' requires user approval."

class MockIntegrationAgent:
    """A mock agent that specifically simulates tool calling for the integration tests"""
    def __init__(self, model):
        self.model = model
        self.tools = []

    def bind_tools(self, tools):
        self.tools = tools
        return self

    def stream(self, prompt_list):
        prompt = prompt_list[0].content.lower()
        chunk = MagicMock()
        
        # Simulate agent reasoning and routing to different tools based on prompt
        if "delete" in prompt or "secure" in prompt:
            chunk.content = f"Security Manager response: {mock_secure_action('delete_all')}"
        elif "context" in prompt or "project" in prompt:
            chunk.content = f"Based on Context Manager: {mock_retrieve_context('atomos')}"
        elif "schedule" in prompt or "task" in prompt:
            chunk.content = f"Scheduled via Task Manager: {mock_create_task('build', {})}"
        elif "sync" in prompt or "file" in prompt:
            chunk.content = f"Sync Manager reports: {mock_check_sync_status('/doc.txt')}"
        else:
            chunk.content = "Generic response."
            
        return [chunk]

@pytest.fixture
def mock_agent():
    with patch('agent_factory.ChatOllama', return_value=MockIntegrationAgent("test_model")):
        agent = create_deep_agent(model_name="test_model")
        return agent

def test_context_manager_rag(mock_agent):
    """Test that the agent can retrieve context for a project"""
    chunks = mock_agent.stream([HumanMessage(content="Tell me about the atomos project context.")])
    response = "".join([c.content for c in chunks])
    assert "Based on Context Manager" in response
    assert "MOCKED_CONTEXT" in response

def test_task_manager_workflow(mock_agent):
    """Test that the agent can create a task/workflow"""
    chunks = mock_agent.stream([HumanMessage(content="Schedule a build task.")])
    response = "".join([c.content for c in chunks])
    assert "Scheduled via Task Manager" in response
    assert "MOCKED_TASK_ID: 999" in response

def test_sync_manager_status(mock_agent):
    """Test that the agent can check file sync status"""
    chunks = mock_agent.stream([HumanMessage(content="Is my file synced?")])
    response = "".join([c.content for c in chunks])
    assert "Sync Manager reports" in response
    assert "MOCKED_SYNC" in response
    assert "fully synced" in response

def test_security_manager_approval(mock_agent):
    """Test that the agent surfaces security approvals instead of hallucinating"""
    chunks = mock_agent.stream([HumanMessage(content="Delete all secure files.")])
    response = "".join([c.content for c in chunks])
    assert "Security Manager response" in response
    assert "MOCKED_SECURITY" in response
    assert "requires user approval" in response
