"""ACP (Agent Client Protocol) server for Zed integration.

Exposes the AtomOS agent over stdio so Zed (and any ACP-compatible
client) can use it as an external coding agent.

The agent reuses the same tool registry, model resolution, and LangGraph
ReAct loop that the gRPC server uses for the COSMIC applet — only the
transport layer differs.

Usage (direct):
    python acp_server.py

Usage (via wrapper):
    ./run_acp_server.sh

Zed settings.json:
    {
      "agent_servers": {
        "AtomOS": {
          "type": "custom",
          "command": "/opt/atomos/agents/run_acp_server.sh"
        }
      }
    }
"""

import asyncio
import logging
import sys
from typing import Any
from uuid import uuid4

from acp import (
    PROTOCOL_VERSION,
    Agent,
    InitializeResponse,
    NewSessionResponse,
    PromptResponse,
    run_agent,
    text_block,
    update_agent_message,
    start_tool_call,
    update_tool_call,
    tool_content,
)
from acp.interfaces import Client
from acp.schema import (
    AgentCapabilities,
    AudioContentBlock,
    ClientCapabilities,
    EmbeddedResourceContentBlock,
    HttpMcpServer,
    ImageContentBlock,
    Implementation,
    McpServerStdio,
    ResourceContentBlock,
    SseMcpServer,
    TextContentBlock,
)
from langchain_core.messages import HumanMessage

from agent_factory import create_agent_for_query
from tool_registry import retrieve_tools, ensure_registry
from secret_store import CredentialRequiredError

logging.basicConfig(level=logging.INFO, stream=sys.stderr)
logger = logging.getLogger(__name__)


class AtomOSAgent(Agent):
    """ACP-compatible wrapper around the AtomOS LangGraph agent.

    Handles session management, streams text/tool-call updates to the
    editor, and delegates actual reasoning to the same agent factory
    used by the gRPC server.
    """

    _conn: Client

    def __init__(self) -> None:
        self._sessions: set[str] = set()
        self._next_tc_id = 0

    def on_connect(self, conn: Client) -> None:
        self._conn = conn
        logger.info("Initializing tool registry for ACP server...")
        try:
            ensure_registry()
        except Exception as exc:
            logger.error("Tool registry init failed: %s", exc)

    def _tc_id(self) -> str:
        self._next_tc_id += 1
        return f"tc-{self._next_tc_id}"

    async def initialize(
        self,
        protocol_version: int,
        client_capabilities: ClientCapabilities | None = None,
        client_info: Implementation | None = None,
        **kwargs: Any,
    ) -> InitializeResponse:
        return InitializeResponse(
            protocol_version=PROTOCOL_VERSION,
            agent_capabilities=AgentCapabilities(),
            agent_info=Implementation(
                name="atomos-agent",
                title="AtomOS Agent",
                version="0.1.0",
            ),
        )

    async def new_session(
        self,
        cwd: str,
        mcp_servers: list[HttpMcpServer | SseMcpServer | McpServerStdio],
        **kwargs: Any,
    ) -> NewSessionResponse:
        session_id = uuid4().hex
        self._sessions.add(session_id)
        logger.info("New ACP session: %s (cwd=%s)", session_id, cwd)
        return NewSessionResponse(session_id=session_id)

    async def prompt(
        self,
        prompt: list[
            TextContentBlock
            | ImageContentBlock
            | AudioContentBlock
            | ResourceContentBlock
            | EmbeddedResourceContentBlock
        ],
        session_id: str,
        **kwargs: Any,
    ) -> PromptResponse:
        self._sessions.add(session_id)

        text = self._extract_text(prompt)
        if not text.strip():
            return PromptResponse(stop_reason="end_turn")

        logger.info("ACP prompt (session=%s): %s", session_id, text[:120])

        try:
            tools = retrieve_tools(text)
        except Exception as exc:
            logger.warning("Tool retrieval failed: %s", exc)
            tools = []

        thread_id = f"acp:{session_id}"
        agent = create_agent_for_query("default", tools, thread_id)
        config = {
            "configurable": {
                "thread_id": thread_id,
                "session_id": session_id,
            },
        }

        try:
            await self._stream_agent(agent, config, text, session_id)
        except CredentialRequiredError as cred_err:
            await self._send_text(
                session_id,
                f"A credential is required to continue: `{cred_err.key}`",
            )
        except Exception as exc:
            logger.error("Agent error: %s", exc, exc_info=True)
            await self._send_text(session_id, f"Error: {exc}")

        return PromptResponse(stop_reason="end_turn")

    async def cancel(self, session_id: str, **kwargs: Any) -> None:
        logger.info("ACP cancel requested for session %s", session_id)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _extract_text(
        prompt: list[Any],
    ) -> str:
        """Pull plain text out of ACP content blocks."""
        parts: list[str] = []
        for block in prompt:
            if isinstance(block, dict):
                parts.append(block.get("text", ""))
            elif hasattr(block, "text"):
                parts.append(block.text)
            elif isinstance(block, str):
                parts.append(block)
        return "\n".join(parts)

    async def _send_text(self, session_id: str, text: str) -> None:
        update = update_agent_message(text_block(text))
        await self._conn.session_update(session_id=session_id, update=update)

    async def _stream_agent(
        self,
        agent: Any,
        config: dict,
        text: str,
        session_id: str,
    ) -> None:
        current_tool_call = ""
        current_tc_id = ""

        async for chunk, metadata in agent.astream(
            {"messages": [HumanMessage(content=text)]},
            config=config,
            stream_mode="messages",
        ):
            node = metadata.get("langgraph_node", "")

            if node == "agent":
                tc_chunks = getattr(chunk, "tool_call_chunks", None) or []
                for tc in tc_chunks:
                    name = tc.get("name", "") or ""
                    if name:
                        current_tool_call = name
                        current_tc_id = self._tc_id()
                        update = start_tool_call(
                            current_tc_id,
                            current_tool_call,
                            kind="action",
                            status="running",
                        )
                        await self._conn.session_update(
                            session_id=session_id, update=update,
                        )

                content = getattr(chunk, "content", "")
                if (
                    isinstance(content, str)
                    and content
                    and not current_tool_call
                ):
                    await self._send_text(session_id, content)

            elif node == "tools":
                content = getattr(chunk, "content", "")
                if current_tc_id and isinstance(content, str) and content:
                    update = update_tool_call(
                        current_tc_id,
                        status="completed",
                        content=[tool_content(text_block(content))],
                    )
                    await self._conn.session_update(
                        session_id=session_id, update=update,
                    )
                current_tool_call = ""
                current_tc_id = ""


async def main() -> None:
    await run_agent(AtomOSAgent())


if __name__ == "__main__":
    asyncio.run(main())
