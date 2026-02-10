import pytest
import pytest_asyncio
import os
import shutil
import asyncio
from surrealdb import AsyncSurreal
import main

# Configuration for test environment
TEST_HOME_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.dev/TEST_HOME"))
TEST_DOCS_DIR = os.path.join(TEST_HOME_DIR, "Documents")

@pytest_asyncio.fixture(scope="session")
def event_loop():
    loop = asyncio.get_event_loop_policy().new_event_loop()
    yield loop
    loop.close()

@pytest_asyncio.fixture(scope="function")
async def setup_test_env():
    # Ensure clean state
    if os.path.exists(TEST_HOME_DIR):
        shutil.rmtree(TEST_HOME_DIR)
    os.makedirs(TEST_DOCS_DIR, exist_ok=True)
    
    # Patch main.HOME_DIR BEFORE setup
    original_home = main.HOME_DIR
    main.HOME_DIR = TEST_HOME_DIR
    
    # Clean DB
    db = AsyncSurreal(main.SURREAL_URL)
    try:
        await db.connect() 
        await db.use(main.SURREAL_NS, main.SURREAL_DB)
        # Clean up documents table for testing
        # Using raw query to delete
        await db.query(f"DELETE {main.SURREAL_TABLE};") 
    except Exception as e:
        print(f"Setup DB error: {e}")
    
    # Setup Flow
    # We need to run setup_async to initialize the flow with the new HOME_DIR
    # Note: re-running setup_async might be necessary if it was already run, 
    # but strictly speaking flow definition is lazy. 
    # If main.py didn't run setup_async globally on import (it didn't), then we are fine.
    await main.sync_flow.setup_async(report_to_stdout=False)

    yield db
    
    # Teardown
    main.HOME_DIR = original_home
    if os.path.exists(TEST_HOME_DIR):
        shutil.rmtree(TEST_HOME_DIR)
    
    await db.close()

@pytest.mark.asyncio
async def test_create_markdown_document(setup_test_env):
    db = setup_test_env
    
    # 1. Create a markdown file
    file_path = os.path.join(TEST_DOCS_DIR, "test_create.md")
    content = "# Test Document\nThis is a test document for creation."
    with open(file_path, "w") as f:
        f.write(content)
        
    # 2. Run sync
    await main.sync_flow.update_async()
    
    # 3. Verify in SurrealDB
    query = f"SELECT * FROM {main.SURREAL_TABLE} WHERE string::ends_with(path, 'test_create.md');"
    result = await db.query(query)
    
    # Handle SurrealDB response format
    # result might be [{'result': [...], 'status': 'OK', ...}]
    if isinstance(result, list) and len(result) > 0 and isinstance(result[0], dict) and 'result' in result[0]:
        docs = result[0]['result']
    else:
        docs = result

    assert docs, "Document not found in SurrealDB"
    doc = docs[0]
    assert doc['content'].strip() == content.strip()

@pytest.mark.asyncio
async def test_update_markdown_document(setup_test_env):
    db = setup_test_env
    
    # 1. Create initial file
    file_path = os.path.join(TEST_DOCS_DIR, "test_update.md")
    initial_content = "# Initial Content\n"
    with open(file_path, "w") as f:
        f.write(initial_content)
        
    await main.sync_flow.update_async()
    
    # Verify creation
    query = f"SELECT * FROM {main.SURREAL_TABLE} WHERE string::ends_with(path, 'test_update.md');"
    result = await db.query(query)
    
    if isinstance(result, list) and len(result) > 0 and isinstance(result[0], dict) and 'result' in result[0]:
        docs = result[0]['result']
    else:
        docs = result
        
    assert len(docs) > 0
    
    # 2. Update file
    updated_content = initial_content + "Updated Content."
    with open(file_path, "w") as f:
        f.write(updated_content)
        
    # 3. Run sync again
    await main.sync_flow.update_async()

    # 4. Verify update
    result = await db.query(query)
    if isinstance(result, list) and len(result) > 0 and isinstance(result[0], dict) and 'result' in result[0]:
        docs = result[0]['result']
    else:
        docs = result
    
    assert len(docs) == 1, f"Should have exactly one document, found {len(docs)}"
    assert docs[0]['content'].strip() == updated_content.strip()

@pytest.mark.asyncio
async def test_delete_markdown_document(setup_test_env):
    db = setup_test_env
    
    # 1. Create file
    file_path = os.path.join(TEST_DOCS_DIR, "test_delete.md")
    content = "Delete me"
    with open(file_path, "w") as f:
        f.write(content)
    
    await main.sync_flow.update_async()
    
    # Verify existence
    query = f"SELECT * FROM {main.SURREAL_TABLE} WHERE string::ends_with(path, 'test_delete.md');"
    result = await db.query(query)
    if isinstance(result, list) and len(result) > 0 and isinstance(result[0], dict) and 'result' in result[0]:
        docs = result[0]['result']
    else:
        docs = result
    assert len(docs) == 1
    
    # 2. Delete file
    os.remove(file_path)
    
    # 3. Run sync
    await main.sync_flow.update_async()
    
    # 4. Verify deletion in DB
    result = await db.query(query)
    if isinstance(result, list) and len(result) > 0 and isinstance(result[0], dict) and 'result' in result[0]:
        docs = result[0]['result']
    else:
        docs = result
        
    assert len(docs) == 0, "Document should be removed from DB after file deletion"
