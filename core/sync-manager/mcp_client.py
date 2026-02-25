import asyncio
import json
import logging
import os
import hashlib
from typing import Dict, Any, List

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from surrealdb import AsyncSurreal

logger = logging.getLogger(__name__)

_embedding_model = None

def get_embedding_model():
    global _embedding_model
    if _embedding_model is None:
        from sentence_transformers import SentenceTransformer
        _embedding_model = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
    return _embedding_model

def chunk_text(text: str, chunk_size: int = 500, overlap: int = 50) -> List[Dict[str, Any]]:
    chunks = []
    start = 0
    text_len = len(text)
    while start < text_len:
        end = start + chunk_size
        chunk_str = text[start:end]
        chunks.append({
            "text": chunk_str,
            "location": {"start": start, "end": min(end, text_len)}
        })
        start += (chunk_size - overlap)
        if start >= text_len:
            break
    if not chunks and text:
         chunks.append({
            "text": text,
            "location": {"start": 0, "end": len(text)}
        })
    return chunks

async def connect_and_sync(server_config: Dict[str, Any], db: AsyncSurreal, doc_db: AsyncSurreal = None, table_name: str = "mcp_server"):
    """
    Connects to a single MCP STDIO server, fetches its tools and resources,
    and upserts the state into the SurrealDB mcp_server table.
    """
    name = server_config.get("name")
    command = server_config.get("command")
    args = server_config.get("args", [])
    env = server_config.get("env", None)

    if not name or not command:
        logger.error("MCP Server config missing 'name' or 'command'")
        return

    logger.info(f"Connecting to MCP Server: {name} via {command} {' '.join(args)}")

    server_parameters = StdioServerParameters(
        command=command,
        args=args,
        env=env
    )

    try:
        async with stdio_client(server_parameters) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()

                # Fetch tools
                tools_response = await session.list_tools()
                supported_tools = []
                if tools_response and hasattr(tools_response, 'tools'):
                    for tool in tools_response.tools:
                        supported_tools.append(json.dumps({
                            "name": tool.name,
                            "description": tool.description,
                            "inputSchema": tool.inputSchema
                        }))

                # Upsert record in SurrealDB
                record_id = f"{table_name}:{name}"
                record_data = {
                    "name": name,
                    "url": "stdio",
                    "status": "connected",
                    "supported_tools": supported_tools,
                    "last_connected": "time::now()"
                }
                
                # Check if exists to update or create
                try:
                    await db.update(record_id, record_data)
                except Exception:
                    try:
                        await db.create(record_id, record_data)
                    except Exception as e:
                        logger.error(f"Failed to upsert MCP server {name} to SurrealDB: {e}")

                logger.info(f"Successfully synced MCP Server: {name} with {len(supported_tools)} tools.")
                
                # Fetch and index resources if doc_db is provided
                if doc_db:
                    resources_response = await session.list_resources()
                    if resources_response and hasattr(resources_response, 'resources'):
                        model = get_embedding_model()
                        for resource in resources_response.resources:
                            try:
                                res_content = await session.read_resource(resource.uri)
                                if hasattr(res_content, "contents"):
                                    for content_item in res_content.contents:
                                        if hasattr(content_item, "text"):
                                            # Chunk and embed
                                            text_data = content_item.text
                                            chunks = chunk_text(text_data)
                                            for chunk in chunks:
                                                path = f"mcp://{name}/{resource.uri}"
                                                loc = json.dumps(chunk["location"])
                                                raw_key = f"{path}_{loc}"
                                                hashed_id = hashlib.sha256(raw_key.encode()).hexdigest()
                                                doc_id = f"document:{hashed_id}"
                                                
                                                embedding = model.encode(chunk["text"]).tolist()
                                                
                                                doc_data = {
                                                    "path": path,
                                                    "content": chunk["text"],
                                                    "location": chunk["location"],
                                                    "embedding": embedding,
                                                    "modified_at": "time::now()"
                                                }
                                                
                                                try:
                                                    await doc_db.update(doc_id, doc_data)
                                                except Exception:
                                                    try:
                                                        await doc_db.create(doc_id, doc_data)
                                                    except Exception as e:
                                                        logger.error(f"Failed to upsert MCP resource {path}: {e}")
                            except Exception as re:
                                logger.error(f"Failed to sync MCP resource {resource.uri}: {re}")

    except Exception as e:
        logger.error(f"Failed to connect or sync MCP Server {name}: {e}")
        # Mark as disconnected
        record_id = f"{table_name}:{name}"
        record_data = {
            "name": name,
            "url": "stdio",
            "status": "disconnected"
        }
        try:
             await db.update(record_id, record_data)
        except Exception:
             pass

async def sync_all_mcp_servers(config_path: str, surreal_url: str, db_ns: str, db_name: str, doc_db_name: str = None):
    """
    Reads the MCP_SERVERS_CONFIG JSON array and syncs each server.
    """
    if not os.path.exists(config_path):
        logger.warning(f"MCP config file not found at {config_path}. Skipping MCP sync.")
        return

    try:
        with open(config_path, "r") as f:
            servers = json.load(f)
    except Exception as e:
        logger.error(f"Failed to parse MCP config file: {e}")
        return

    if not isinstance(servers, list):
        logger.error("MCP config must be a JSON array of server objects.")
        return

    # Connect to SurrealDB once for all servers
    db = AsyncSurreal(surreal_url)
    doc_db = None
    try:
        await db.connect()
        # await db.signin({"user": "root", "pass": "root"}) # Depending on auth config
        await db.use(db_ns, db_name)
        
        if doc_db_name:
            doc_db = AsyncSurreal(surreal_url)
            await doc_db.connect()
            await doc_db.use(db_ns, doc_db_name)

        for server_config in servers:
            await connect_and_sync(server_config, db, doc_db)
    except Exception as e:
         logger.error(f"SurrealDB connection failed during MCP sync: {e}")

async def mcp_polling_loop(config_path: str, surreal_url: str, db_ns: str, db_name: str, doc_db_name: str = None, interval_seconds: int = 300):
    """
    Background block to repeatedly poll MCP server status.
    """
    while True:
        logger.info("Running scheduled MCP Server sync...")
        await sync_all_mcp_servers(config_path, surreal_url, db_ns, db_name, doc_db_name)
        await asyncio.sleep(interval_seconds)
