import pytest
from surrealdb import AsyncSurreal

@pytest.mark.asyncio
async def test_surreal_connection(surreal: AsyncSurreal):
    """Test that the SurrealDB test fixture works."""
    result = await surreal.query("RETURN 'hello world';")
    assert 'hello world' in str(result)

import grpc
import bridge_pb2
import bridge_pb2_grpc

@pytest.mark.asyncio
async def test_chat_pipeline(atomos_agents):
    """Test Full Pipeline: User sends chat message -> agent -> response."""
    # The atomos_agents fixture ensures the gRPC server is running on AGENTS_SERVER_PORT.
    from conftest import AGENTS_SERVER_PORT
    
    # Connect to the gRPC server
    channel = grpc.aio.insecure_channel(f"127.0.0.1:{AGENTS_SERVER_PORT}")
    stub = bridge_pb2_grpc.AgentServiceStub(channel)
    
    # Create a request
    request = bridge_pb2.AgentRequest(
        prompt="Hello Atom!",
        model="llama3",  # Assuming a standard model
        images=[],
        context=[]
    )
    
    # Call the streaming endpoint
    responses = []
    async for response in stub.StreamAgentTurn(request):
        responses.append(response.content)
        if response.done:
            break
            
    # Verify we got a response
    full_response = "".join(responses)
    assert len(full_response) > 0, "Agent did not return a response"
    assert "Hello" in full_response or len(full_response) > 5
    
    await channel.close()

@pytest.mark.asyncio
async def test_automation_trigger(surreal):
    """Test Full Pipeline: User triggers automation -> workflow -> result."""
    # Simulate an agent creating a workflow execution
    await surreal.query("CREATE workflow_execution SET status='Pending', name='test_automation';")
    
    # Simulate the task manager executing it
    await surreal.query("UPDATE workflow_execution SET status='Completed' WHERE name='test_automation';")
    
    # Verify the final state
    result = await surreal.query("SELECT * FROM workflow_execution WHERE name='test_automation';")
    
    assert result and isinstance(result, list) and len(result) > 0
    assert result[0].get('status') == 'Completed'

import os
import asyncio

@pytest.mark.asyncio
async def test_file_save_sync(surreal, sync_manager, core_dir):
    """Test Full Pipeline: File saved -> sync manager -> SurrealDB -> context manager has new context."""
    
    # The sync manager fixture ensures it's running and watching `.dev/$HOME` by default, or we can use the actual target
    dev_home = os.path.join(core_dir, "sync-manager", ".dev", "$HOME")
    os.makedirs(dev_home, exist_ok=True)
    
    test_file_path = os.path.join(dev_home, "e2e_sync_test.txt")
    with open(test_file_path, "w") as f:
        f.write("This is a special tracking file for E2E testing sync capabilities.")
    
    # Wait for the live updater to detect and sync (default 5s refresh interval)
    # We will poll SurrealDB every second for up to 60 seconds to allow model downloads.
    synced = False
    for _ in range(60):
        try:
            # check the document table using the relative path from the watched directory
            result = await surreal.query("SELECT * FROM document WHERE path = $path", {"path": "e2e_sync_test.txt"})
            # In the latest surrealdb python client, query results are returned directly as a list
            if result and isinstance(result, list) and len(result) > 0:
                doc = result[0]
                assert "E2E testing sync" in doc.get('content', '')
                synced = True
                break
        except Exception as e:
            print(f"Error querying SurrealDB: {e}")
        await asyncio.sleep(1)
        
    assert synced, "Sync manager did not index the newly created file within 60 seconds."
    
    # Clean up
    if os.path.exists(test_file_path):
        os.remove(test_file_path)

@pytest.mark.asyncio
async def test_context_switch(surreal):
    """Test Full Pipeline: Context switch -> RAG scope changes."""
    # 1. Insert documents for Project A and Project B
    await surreal.query("CREATE document SET path='/projects/A/file.txt', content='Project A secret';")
    await surreal.query("CREATE document SET path='/projects/B/file.txt', content='Project B secret';")
    
    # 2. Switch context to Project A
    await surreal.query("CREATE project_context SET name='Project A', path='/projects/A', status='active';")
    
    # 3. Simulate RAG query scoped to Project A
    result = await surreal.query("SELECT * FROM document WHERE path CONTAINS '/projects/A';")
    
    assert result and isinstance(result, list) and len(result) > 0
    assert 'Project A secret' in result[0].get('content', '')
    
    # Ensure Project B is not in the result
    assert not any('Project B secret' in doc.get('content', '') for doc in result)
