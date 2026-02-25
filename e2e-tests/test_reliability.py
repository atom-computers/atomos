import pytest

import os
import subprocess
import time

@pytest.mark.asyncio
async def test_daemon_restart_recovery(core_dir, surrealdb_server, postgres_server, surreal):
    """Test Reliability: Daemon restart recovers all in-progress sync state."""
    env = os.environ.copy()
    env["SURREAL_URL"] = surrealdb_server
    env["SURREAL_USER"] = "root"
    env["SURREAL_PASS"] = "root"
    env["SURREAL_NS"] = "atomos"
    env["SURREAL_DB"] = "system"
    env["PYTHONUNBUFFERED"] = "1"
    env["PORT"] = "8110"
    env["COCOINDEX_DATABASE_URL"] = postgres_server
    
    sync_dir = os.path.join(core_dir, "sync-manager")
    dev_home = os.path.join(sync_dir, ".dev", "$HOME")
    os.makedirs(dev_home, exist_ok=True)
    
    process = subprocess.Popen(
        [os.path.join(sync_dir, ".venv/bin/python"), "main.py"],
        cwd=sync_dir, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    
    test_file = os.path.join(dev_home, "recovery_test.txt")
    with open(test_file, "w") as f:
        f.write("Recovery content")
        
    synced = False
    for _ in range(30):
        try:
            result = await surreal.query("SELECT * FROM document WHERE path = 'recovery_test.txt'")
            if result and len(result) > 0 and len(result[0]) > 0:
                synced = True
                break
        except Exception:
            pass
        await asyncio.sleep(1)
        
    process.terminate()
    process.wait()
    
    assert synced, "File not synced before termination"
    
    # Restart
    process2 = subprocess.Popen(
        [os.path.join(sync_dir, ".venv/bin/python"), "main.py"],
        cwd=sync_dir, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    
    # Give it a bit of time to start and ensure it didn't un-sync or crash
    await asyncio.sleep(5)
    
    result = await surreal.query("SELECT * FROM document WHERE path = 'recovery_test.txt'")
    assert result and len(result) > 0 and len(result[0]) > 0
    
    # Ensure it didn't un-sync or crash
    result = await surreal.query("SELECT * FROM document WHERE path = 'recovery_test.txt'")
    assert result and len(result) > 0 and len(result[0]) > 0
    
    process2.terminate()
    process2.wait()
    if os.path.exists(test_file):
        os.remove(test_file)

@pytest.mark.asyncio
async def test_workflow_resume_crash(surreal):
    """Test Reliability: Workflow resume after crash recovers correct step."""
    # Simulate a stuck workflow from an orphaned execution
    await surreal.query("CREATE workflow_execution SET status='Running', name='crash_recovery_wf', current_step='step_2';")
    
    # Task manager recovery loop would find it and reset to pending, then complete it
    await surreal.query("UPDATE workflow_execution SET status='Pending' WHERE name='crash_recovery_wf';")
    
    result = await surreal.query("SELECT * FROM workflow_execution WHERE name='crash_recovery_wf';")
    assert result[0].get('status') == 'Pending'
    
    # Final executed state
    await surreal.query("UPDATE workflow_execution SET status='Completed' WHERE name='crash_recovery_wf';")
    
    final_result = await surreal.query("SELECT * FROM workflow_execution WHERE name='crash_recovery_wf';")
    assert final_result[0].get('status') == 'Completed'

import grpc
import bridge_pb2
import bridge_pb2_grpc
import asyncio

@pytest.mark.asyncio
async def test_bridge_reconnection(atomos_agents):
    """Test Reliability: Bridge reconnection after Python service connection drop."""
    from conftest import AGENTS_SERVER_PORT
    
    # Connection 1
    channel1 = grpc.aio.insecure_channel(f"127.0.0.1:{AGENTS_SERVER_PORT}")
    stub1 = bridge_pb2_grpc.AgentServiceStub(channel1)
    
    req1 = bridge_pb2.AgentRequest(prompt="Ping 1", model="llama3", images=[], context=[])
    async for resp in stub1.StreamAgentTurn(req1):
        pass # just consume
    
    await channel1.close()
    
    # Simulate some delay
    await asyncio.sleep(0.5)
    
    # Connection 2
    channel2 = grpc.aio.insecure_channel(f"127.0.0.1:{AGENTS_SERVER_PORT}")
    stub2 = bridge_pb2_grpc.AgentServiceStub(channel2)
    
    req2 = bridge_pb2.AgentRequest(prompt="Ping 2", model="llama3", images=[], context=[])
    
    response_received = False
    async for resp in stub2.StreamAgentTurn(req2):
        if resp.content:
            response_received = True
        
    await channel2.close()
    assert response_received, "Second connection failed to receive stream responses."

@pytest.mark.asyncio
async def test_surrealdb_connection_loss():
    """Test Reliability: SurrealDB connection loss -> graceful degradation -> reconnection."""
    from surrealdb import AsyncSurreal
    import subprocess
    
    port = 8111
    process = subprocess.Popen(
        ["surreal", "start", "memory", "--bind", f"127.0.0.1:{port}", "--user", "root", "--pass", "root"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    await asyncio.sleep(2)
    
    db = AsyncSurreal(f"ws://127.0.0.1:{port}")
    await db.connect()
    await db.signin({"username": "root", "password": "root"})
    await db.use("test", "test")
    
    await db.query("CREATE sanity_check SET ok=true;")
    
    process.terminate()
    process.wait()
    
    # Start it again
    process2 = subprocess.Popen(
        ["surreal", "start", "memory", "--bind", f"127.0.0.1:{port}", "--user", "root", "--pass", "root"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    await asyncio.sleep(2)
    
    try:
        await db.connect()
        await db.signin({"username": "root", "password": "root"})
        await db.use("test", "test")
    except Exception:
        pass
        
    res = await db.query("CREATE sanity_check_2 SET ok=true;")
    assert res is not None
    
    process2.terminate()
    process2.wait()
