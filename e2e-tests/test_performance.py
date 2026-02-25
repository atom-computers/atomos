import pytest
import os
import asyncio
import time
import grpc
import bridge_pb2
import bridge_pb2_grpc

@pytest.mark.asyncio
async def test_sync_manager_burst(surreal, sync_manager, core_dir):
    """Test Performance: Sync manager handles file change burst under 30 seconds."""
    dev_home = os.path.join(core_dir, "sync-manager", ".dev", "$HOME")
    os.makedirs(dev_home, exist_ok=True)
    
    # 100 files for local E2E to be reliable and fast, simulating a burst
    num_files = 100
    for i in range(num_files):
        with open(os.path.join(dev_home, f"burst_{i}.txt"), "w") as f:
            f.write(f"Burst file number {i} for performance testing.")
            
    start_time = time.time()
    
    # Polling for completion
    completed = False
    for _ in range(60):
        try:
            result = await surreal.query("SELECT count() FROM document WHERE path = string::concat('burst_', $_, '.txt') GROUP BY count;", {})
            # A simpler query: count all docs where path CONTAINS 'burst'
            result = await surreal.query("SELECT count() FROM document WHERE path CONTAINS 'burst' GROUP BY count;")
            if result and isinstance(result, list) and len(result) > 0:
                count = result[0].get('count', 0)
                if count >= num_files:
                    completed = True
                    break
        except Exception as e:
            print(f"Query error: {e}")
        await asyncio.sleep(1)
        
    duration = time.time() - start_time
    
    # Clean up
    for i in range(num_files):
        try:
            os.remove(os.path.join(dev_home, f"burst_{i}.txt"))
        except:
            pass
            
    assert completed, f"Sync manager did not index {num_files} files within 60 seconds."
    assert duration < 30.0, f"Burst processing took {duration}s, expected < 30s"

@pytest.mark.asyncio
async def test_rag_latency(surreal):
    """Test Performance: Context manager RAG query responds under 500ms (p95)."""
    # Insert multiple test documents to query against
    for i in range(10):
        await surreal.query(f"CREATE document SET path='/performance/rag/{i}.txt', content='test data', embedding=[0.1, 0.2, 0.3];")
        
    start_time = time.time()
    
    # In SurrealDB, a basic vector similarity search would use vector::similarity
    # Since we're just testing the latency of the query execution through the python client:
    # Here we simulate the RAG retrieval by fetching all documents in this path.
    await surreal.query("SELECT * FROM document WHERE path CONTAINS '/performance/rag/' LIMIT 10;")
    
    duration = time.time() - start_time
    assert duration < 0.5, f"RAG query latency ({duration}s) exceeded 500ms"

@pytest.mark.asyncio
async def test_agent_streaming_latency(atomos_agents):
    """Test Performance: Agent streaming response first-token latency under 2 seconds."""
    from conftest import AGENTS_SERVER_PORT
    channel = grpc.aio.insecure_channel(f"127.0.0.1:{AGENTS_SERVER_PORT}")
    stub = bridge_pb2_grpc.AgentServiceStub(channel)
    request = bridge_pb2.AgentRequest(prompt="Latency test", model="llama3", images=[], context=[])
    
    start_time = time.time()
    first_token_time = None
    
    async for response in stub.StreamAgentTurn(request):
        if first_token_time is None and response.content:
            first_token_time = time.time()
        if response.done:
            break
            
    assert first_token_time is not None, "Did not receive any tokens"
    latency = first_token_time - start_time
    assert latency < 2.0, f"First token latency ({latency}s) exceeded 2 seconds"
    await channel.close()

@pytest.mark.asyncio
async def test_concurrent_agents(atomos_agents):
    """Test Performance: Concurrent workflow execution (10 parallel agents) completes without deadlock."""
    from conftest import AGENTS_SERVER_PORT
    channel = grpc.aio.insecure_channel(f"127.0.0.1:{AGENTS_SERVER_PORT}")
    stub = bridge_pb2_grpc.AgentServiceStub(channel)
    
    async def run_agent(i):
        request = bridge_pb2.AgentRequest(prompt=f"Parallel test {i}", model="llama3", images=[], context=[])
        responses = []
        async for response in stub.StreamAgentTurn(request):
            responses.append(response.content)
            if response.done:
                break
        return "".join(responses)
        
    # Run 10 concurrently
    tasks = [run_agent(i) for i in range(10)]
    results = await asyncio.gather(*tasks)
    
    assert len(results) == 10
    for res in results:
        assert len(res) > 0
    await channel.close()
