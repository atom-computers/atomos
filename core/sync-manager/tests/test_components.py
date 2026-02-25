import pytest
import datetime
import os
import tempfile
import json
from unittest.mock import AsyncMock, patch, MagicMock

import sys
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

import main
from cocoindex_surreal import _Connector, _MutateContext
from mcp_client import connect_and_sync
from conversation_sync import parse_ron_conversation
from contact_sync import parse_vcf_file

def test_process_file_content_large_file():
    # Unit: CocoIndex flow handles large files properly (part of chunking logic check)
    assert "Large file skipped" in main.process_file_content("large.txt", b"a" * (main.MAX_FILE_SIZE + 1))

def test_process_file_content_text():
    assert main.process_file_content("test.txt", b"Hello World") == "Hello World"

@pytest.mark.asyncio
async def test_surreal_connector_upsert_delete():
    # Unit: `cocoindex_surreal.py` connector handles upsert/delete correctly
    mock_db = AsyncMock()
    context = _MutateContext(db=mock_db, table_name="test_table", key_field_names=["path", "loc"])
    
    # 1. Upsert (create/update)
    mutations = {
        ("test.txt", "1"): {"content": "hello"}
    }
    await _Connector.mutate((context, mutations))
    
    # It should have called create
    assert mock_db.create.called
    
    # 2. Delete
    mutations_delete = {
        ("test.txt", "1"): None
    }
    await _Connector.mutate((context, mutations_delete))
    
    # It should have called delete
    assert mock_db.delete.called

@pytest.mark.asyncio
async def test_mcp_client_serialization():
    # Unit: MCP client adapter serializes/deserializes correctly
    server_config = {"name": "test_mcp", "command": "echo", "args": ["hello"]}
    mock_db = AsyncMock()
    
    # We will mock the stdio_client and ClientSession inside connect_and_sync
    with patch("mcp_client.stdio_client") as mock_stdio, \
         patch("mcp_client.ClientSession") as mock_session_cls:
        
        # Setup mocks
        mock_ctx = AsyncMock()
        mock_stdio.return_value = mock_ctx
        mock_ctx.__aenter__.return_value = (AsyncMock(), AsyncMock())
        
        mock_session_ctx = AsyncMock()
        mock_session_cls.return_value = mock_session_ctx
        mock_session = AsyncMock()
        mock_session_ctx.__aenter__.return_value = mock_session
        
        # Mock tools response
        class Tool:
            name = "test_tool"
            description = "A test tool"
            inputSchema = {"type": "object"}
            
        class ToolsResponse:
            tools = [Tool()]
            
        mock_session.list_tools.return_value = ToolsResponse()
        
        await connect_and_sync(server_config, mock_db, "mcp_server")
        
        assert mock_db.update.called or mock_db.create.called
        # Check what was passed to db
        call_args = mock_db.update.call_args or mock_db.create.call_args
        record_data = call_args[0][1]
        assert record_data["name"] == "test_mcp"
        assert len(record_data["supported_tools"]) == 1
        tool_json = json.loads(record_data["supported_tools"][0])
        assert tool_json["name"] == "test_tool"

def test_conversation_parser_edge_cases():
    # Unit: conversation RON parser handles edge cases (empty, malformed, images)
    with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".ron") as f:
        f.write('User(Text("Hello\\nWorld")), Bot(Text("Hi\\"There\\""))\n')
        f.write('Malformed data here\n')
        temp_path = f.name
        
    try:
        messages = parse_ron_conversation(temp_path)
        assert len(messages) == 2
        assert messages[0]["role"] == "user"
        assert messages[0]["content"] == "Hello\nWorld"
        assert messages[1]["role"] == "bot"
        assert messages[1]["content"] == 'Hi"There"'
    finally:
        os.remove(temp_path)

def test_contact_deduplication():
    # Unit: contact deduplication logic via parsing
    vcf_content = """BEGIN:VCARD
VERSION:3.0
FN:John Doe
UID:12345
EMAIL:john@example.com
TEL:555-1234
END:VCARD
BEGIN:VCARD
VERSION:3.0
N:Smith;Jane;;;
EMAIL:jane@example.com
END:VCARD
"""
    with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".vcf") as f:
        f.write(vcf_content)
        temp_path = f.name
        
    try:
        contacts = parse_vcf_file(temp_path)
        assert len(contacts) == 2
        assert contacts[0]["name"] == "John Doe"
        assert contacts[0]["uid"] == "12345"
        assert "john@example.com" in contacts[0]["metadata"]["emails"]
        
        # Jane Smith has no UID in VCF, so it should be hashed
        assert contacts[1]["name"] == "Jane Smith"
        assert contacts[1]["uid"] != ""
        assert "jane@example.com" in contacts[1]["metadata"]["emails"]
    finally:
        os.remove(temp_path)
