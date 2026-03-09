import base64
import logging
import os
from typing import List

import requests
from langchain_core.chat_history import BaseChatMessageHistory
from langchain_core.messages import BaseMessage, HumanMessage, AIMessage, SystemMessage

logger = logging.getLogger(__name__)

SURREALDB_USER = os.environ.get("SURREALDB_USER", "root")
SURREALDB_PASS = os.environ.get("SURREALDB_PASS", "root")

def _message_to_role(message: BaseMessage) -> str:
    if isinstance(message, HumanMessage):
        return "user"
    elif isinstance(message, AIMessage):
        return "assistant"
    elif isinstance(message, SystemMessage):
        return "system"
    else:
        return "unknown"

def _role_to_message(role: str, content: str) -> BaseMessage:
    if role == "user":
        return HumanMessage(content=content)
    elif role == "system":
        return SystemMessage(content=content)
    else:
        return AIMessage(content=content)

class AtomOSChatMessageHistory(BaseChatMessageHistory):
    """Chat message history stored in SurrealDB via REST."""
    
    def __init__(self, session_id: str, db_url: str = "http://localhost:8000"):
        self.session_id = session_id
        self.db_url = db_url.rstrip("/")
        self.sql_url = f"{self.db_url}/sql"
        
        creds = base64.b64encode(f"{SURREALDB_USER}:{SURREALDB_PASS}".encode()).decode()
        self.headers = {
            "Accept": "application/json",
            "Authorization": f"Basic {creds}",
            "surreal-ns": "atomos",
            "surreal-db": "atomos",
        }

    @property
    def messages(self) -> List[BaseMessage]:
        query = f"SELECT * FROM chat_message WHERE thread_id = '{self.session_id}' ORDER BY timestamp ASC;"
        try:
            response = requests.post(self.sql_url, data=query, headers=self.headers)
            response.raise_for_status()
            results = response.json()
            msgs = []
            if results and len(results) > 0 and results[0].get("status") == "OK":
                for row in results[0].get("result", []):
                    msgs.append(_role_to_message(row.get("role"), row.get("content")))
            return msgs
        except Exception as e:
            logger.error(f"Error fetching messages from SurrealDB: {e}")
            return []

    def add_messages(self, messages: List[BaseMessage]) -> None:
        if not messages:
            return
            
        queries = []
        for msg in messages:
            role = _message_to_role(msg)
            # Extremely basic escaping for demonstration purposes
            content = str(msg.content).replace("'", "\\'")
            query = f"CREATE chat_message SET thread_id = '{self.session_id}', role = '{role}', content = '{content}', timestamp = time::now();"
            queries.append(query)
            
        try:
            full_query = "\\n".join(queries)
            response = requests.post(self.sql_url, data=full_query, headers=self.headers)
            response.raise_for_status()
        except Exception as e:
            logger.error(f"Error saving messages to SurrealDB: {e}")

    def clear(self) -> None:
        query = f"DELETE chat_message WHERE thread_id = '{self.session_id}';"
        try:
            requests.post(self.sql_url, data=query, headers=self.headers)
        except Exception as e:
            logger.error(f"Error clearing messages in SurrealDB: {e}")
