import asyncio
import os
import sys
import subprocess
import time
import pytest
import pytest_asyncio
import aiohttp
from surrealdb import AsyncSurreal

# Add atomos-agents to python path for protobuf imports
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../core/atomos-agents/src")))

# Base port configuration for tests to avoid colliding with main dev setup
SURREAL_PORT = 8100
SYNC_MANAGER_PORT = 8101
CONTEXT_MANAGER_PORT = 8102
TASK_MANAGER_PORT = 8103
AGENTS_SERVER_PORT = 8104

def wait_for_port(port, timeout=10):
    """Wait until a port is accepting connections."""
    import socket
    start_time = time.time()
    while time.time() - start_time < timeout:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.5)
    return False

@pytest.fixture(scope="session")
def project_root():
    return os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

@pytest.fixture(scope="session")
def core_dir(project_root):
    return os.path.join(project_root, "core")

@pytest.fixture(scope="session")
def surrealdb_server():
    """Starts a local SurrealDB instance in memory for tests."""
    print("Starting SurrealDB on port", SURREAL_PORT)
    env = os.environ.copy()
    
    process = subprocess.Popen(
        [
            "surreal", "start", "memory",
            "--bind", f"127.0.0.1:{SURREAL_PORT}",
            "--user", "root",
            "--pass", "root"
        ],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    assert wait_for_port(SURREAL_PORT), "SurrealDB failed to start"
    yield f"ws://127.0.0.1:{SURREAL_PORT}"
    process.terminate()
    process.wait()

@pytest.fixture(scope="session")
def postgres_server():
    """Starts a local Postgres instance via Docker for CocoIndex."""
    port = 5433
    print("Starting Postgres on port", port)
    
    # Ensure any existing container with the same name is removed
    subprocess.run(["docker", "rm", "-f", "atomos_e2e_postgres"], capture_output=True)
    
    process = subprocess.Popen(
        [
            "docker", "run", "--rm", "--name", "atomos_e2e_postgres",
            "-p", f"{port}:5432",
            "-e", "POSTGRES_USER=postgres",
            "-e", "POSTGRES_PASSWORD=postgres",
            "-e", "POSTGRES_DB=cocoindex",
            "postgres:15-alpine"
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    
    assert wait_for_port(port, timeout=30), "Postgres failed to start"
    
    # Wait a bit more for Postgres to be fully ready to accept connections
    time.sleep(3)
    
    url = f"postgresql://postgres:postgres@127.0.0.1:{port}/cocoindex"
    yield url
    
    # Clean up the container
    subprocess.run(["docker", "stop", "atomos_e2e_postgres"], capture_output=True)
    process.wait()

@pytest.fixture(scope="session")
def sync_manager(core_dir, surrealdb_server, postgres_server):
    """Starts the Python sync-manager service."""
    env = os.environ.copy()
    env["SURREAL_URL"] = surrealdb_server
    env["SURREAL_USER"] = "root"
    env["SURREAL_PASS"] = "root"
    env["SURREAL_NS"] = "atomos"
    env["SURREAL_DB"] = "system"
    env["PYTHONUNBUFFERED"] = "1"
    env["PORT"] = str(SYNC_MANAGER_PORT)
    env["COCOINDEX_DATABASE_URL"] = postgres_server
    # Adjust variables as needed based on the actual requirements of sync-manager
    
    sync_dir = os.path.join(core_dir, "sync-manager")
    print(f"Starting sync-manager from {sync_dir}")
    
    log_file = open("/tmp/sync_manager.log", "w")
    # Might need a specific port or just background execution
    process = subprocess.Popen(
        [os.path.join(sync_dir, ".venv/bin/python"), "main.py"],
        cwd=sync_dir,
        env=env,
        stdout=log_file,
        stderr=subprocess.STDOUT
    )
    # Ideally ping a health check endpoint or just sleep
    time.sleep(2)
    yield process
    process.terminate()
    process.wait()
    log_file.close()

@pytest.fixture(scope="session")
def context_manager(core_dir, surrealdb_server):
    """Starts the Rust context-manager."""
    env = os.environ.copy()
    env["SURREAL_URL"] = surrealdb_server
    env["SURREAL_USER"] = "root"
    env["SURREAL_PASS"] = "root"
    env["SURREAL_NS"] = "atomos"
    env["SURREAL_DB"] = "system"
    
    cm_dir = os.path.join(core_dir, "context-manager")
    print(f"Starting context-manager from {cm_dir}")
    process = subprocess.Popen(
        ["cargo", "run"],
        cwd=cm_dir,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    time.sleep(2)
    yield process
    process.terminate()
    process.wait()

@pytest.fixture(scope="session")
def task_manager(core_dir, surrealdb_server):
    """Starts the Rust task-manager."""
    env = os.environ.copy()
    env["SURREAL_URL"] = surrealdb_server
    env["SURREAL_USER"] = "root"
    env["SURREAL_PASS"] = "root"
    env["SURREAL_NS"] = "atomos"
    env["SURREAL_DB"] = "system"
    
    tm_dir = os.path.join(core_dir, "task-manager")
    print(f"Starting task-manager from {tm_dir}")
    process = subprocess.Popen(
        ["cargo", "run"],
        cwd=tm_dir,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    time.sleep(2)
    yield process
    process.terminate()
    process.wait()

@pytest.fixture(scope="session")
def atomos_agents(core_dir, surrealdb_server):
    """Starts the Python atomos-agents gRPC server."""
    env = os.environ.copy()
    env["SURREAL_URL"] = surrealdb_server
    env["SURREAL_USER"] = "root"
    env["SURREAL_PASS"] = "root"
    env["SURREAL_NS"] = "atomos"
    env["SURREAL_DB"] = "system"
    env["PORT"] = str(AGENTS_SERVER_PORT)
    
    agents_dir = os.path.join(core_dir, "atomos-agents")
    print(f"Starting atomos-agents from {agents_dir}")
    process = subprocess.Popen(
        [os.path.join(agents_dir, ".venv/bin/python"), "-m", "src.server"],
        cwd=agents_dir,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE
    )
    assert wait_for_port(AGENTS_SERVER_PORT), "atomos-agents failed to start"
    yield process
    process.terminate()
    process.wait()

@pytest_asyncio.fixture
async def surreal(surrealdb_server):
    """Provides an authenticated SurrealDB client for the tests."""
    db = AsyncSurreal(f"ws://127.0.0.1:{SURREAL_PORT}")
    await db.connect()
    await db.signin({"username": "root", "password": "root"})
    await db.use("atomos", "system")
    yield db
