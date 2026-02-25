import asyncio
import logging
import os
import re
from typing import Dict, Any, List

from surrealdb import AsyncSurreal

logger = logging.getLogger(__name__)

# Basic Regex to extract the nested User and Bot texts from the RON format.
# Assuming format like: User(Text("Hello")), Bot(Text("Hi there"))
USER_MSG_PATTERN = re.compile(r'User\(Text\("([^"]+)"\)\)')
BOT_MSG_PATTERN = re.compile(r'Bot\(Text\("([^"]+)"\)\)')

def parse_ron_conversation(filepath: str) -> List[Dict[str, Any]]:
    """
    Parses a cosmic-ext-applet-ollama .ron file and extracts the dialogue turns.
    Returns a list of dicts: [{'role': 'user', 'content': '...'}, ...]
    """
    try:
        with open(filepath, 'r') as f:
            content = f.read()
            
        # For simplicity, we can regex split on commas or newlines if we want exact order,
        # but a sequential findall might lose ordering if not careful.
        # A better naive approach: find all occurrences of (User|Bot)(Text("..."))
        # and capture their order.
        pattern = re.compile(r'(User|Bot)\(Text\("(.*?)"\)\)', re.DOTALL)
        matches = pattern.findall(content)
        
        conversation = []
        for role_raw, text in matches:
            role = "user" if role_raw == "User" else "bot"
            conversation.append({
                "role": role,
                "content": text.replace('\\"', '"').replace('\\n', '\n')
            })
            
        return conversation
    except Exception as e:
        logger.error(f"Failed to parse RON file {filepath}: {e}")
        return []

async def sync_conversations(data_path: str, db: AsyncSurreal, table_thread: str = "chat_thread", table_message: str = "chat_message"):
    """
    Reads all .ron files in the data_path, parses them, and upserts them
    in the database preserving thread names as IDs.
    """
    if not os.path.exists(data_path):
        try:
            os.makedirs(data_path, exist_ok=True)
            logger.info(f"Created conversation data path at {data_path}")
        except Exception as e:
            logger.warning(f"Conversation path not found at {data_path} and could not create it. Skipping sync: {e}")
            return

    logger.info(f"Scanning for conversation files in {data_path}")
    
    try:
        files = [f for f in os.listdir(data_path) if f.endswith('.ron')]
        
        for file in files:
            thread_name = file.replace('.ron', '') # e.g. "2024-05-15 12:00:00"
            thread_id = f"{table_thread}:⟨{thread_name}⟩" # Using SurrealDB brackets for arbitrary string IDs
            filepath = os.path.join(data_path, file)
            
            messages = parse_ron_conversation(filepath)
            if not messages:
                continue
                
            # 1. Upsert Thread
            thread_data = {
                "title": thread_name,
                "created_at": "time::now()", # For simplicity, usually we'd parse the date from thread_name
                "updated_at": "time::now()",
                "context_id": None
            }
            try:
                await db.update(thread_id, thread_data)
            except Exception:
                try:
                    await db.create(thread_id, thread_data)
                except Exception as e:
                    logger.error(f"Failed to upsert chat thread {thread_id}: {e}")
                    continue

            # 2. Upsert Messages
            # To avoid duplicating massive arrays, we recreate messages or skip if thread is unchanged.
            # For this simplistic implementation, we'll hash the message content or just use its index.
            for idx, msg in enumerate(messages):
                message_id = f"{table_message}:⟨{thread_name}_{idx}⟩"
                message_data = {
                    "thread_id": thread_id,
                    "role": msg["role"],
                    "content": msg["content"],
                    "meta": None,
                    "timestamp": "time::now()"
                }
                
                try:
                    await db.update(message_id, message_data)
                except Exception:
                    try:
                        await db.create(message_id, message_data)
                    except Exception as e:
                        logger.error(f"Failed to upsert chat message {message_id}: {e}")

        logger.info(f"Successfully synced {len(files)} conversation threads.")
    except Exception as e:
        logger.error(f"Failed during conversation sync: {e}")

async def conversation_polling_loop(data_path: str, surreal_url: str, db_ns: str, db_name: str, interval_seconds: int = 60):
    """
    Background block to repeatedly poll and ingest conversations.
    """
    # Create DB connection
    db = AsyncSurreal(surreal_url)
    try:
        await db.connect()
        await db.use(db_ns, db_name)
    except Exception as e:
        logger.error(f"SurrealDB connection failed during Conversation sync: {e}")
        return

    while True:
        logger.info("Running scheduled Conversation sync...")
        await sync_conversations(data_path, db)
        await asyncio.sleep(interval_seconds)
