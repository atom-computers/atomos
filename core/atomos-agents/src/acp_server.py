"""ACP (Agent Client Protocol) server for Zed integration.

Exposes the AtomOS agent over stdio so Zed (and any ACP-compatible
client) can use it as an external coding agent.

The agent reuses the same tool registry, model resolution, and LangGraph
ReAct loop that the gRPC server uses for the COSMIC applet — only the
transport layer differs.

Design note: This server uses a per-prompt agent (tools from RAG over the
user message) and streams tool_call/tool_call_update with locations so
Zed can follow the active file. For a session-scoped agent with
create_deep_agent and AgentServerACP, see the reference demo:
  https://github.com/langchain-ai/deepagents/blob/main/libs/acp/examples/demo_agent.py

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
import inspect
import json
import os
import re
import sys
from typing import Any, Optional
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
        self._session_cwds: dict[str, str] = {}
        self._next_tc_id = 0
        self._client_capabilities: ClientCapabilities | None = None

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
        self._client_capabilities = client_capabilities
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
        self._session_cwds[session_id] = cwd
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

        acp_fs_tools = self._make_acp_fs_tools(session_id)
        if acp_fs_tools:
            from security import wrap_tool_with_security
            wrapped = [wrap_tool_with_security(t) for t in acp_fs_tools]
            tools = wrapped + [t for t in tools if getattr(t, "name", "") not in {"acp_read_file", "acp_write_file"}]
            logger.info("Injected ACP fs tools so editor will open/focus files: %s", [getattr(t, "name", "") for t in acp_fs_tools])

        thread_id = f"acp:{session_id}"
        agent = create_agent_for_query(
            "default",
            tools,
            thread_id,
            query=text,
        )
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

    def _client_fs_capable(self) -> tuple[bool, bool]:
        """Return (read_ok, write_ok) from client capabilities."""
        cap = self._client_capabilities
        if not cap:
            return False, False
        fs = getattr(cap, "fs", None)
        if fs is None:
            return False, False
        read_ok = getattr(fs, "read_text_file", None) or getattr(fs, "readTextFile", None)
        write_ok = getattr(fs, "write_text_file", None) or getattr(fs, "writeTextFile", None)
        return bool(read_ok), bool(write_ok)

    async def _call_client(
        self,
        method: str,
        params: dict[str, Any],
    ) -> Any:
        """Invoke a client method (e.g. fs/read_text_file, fs/write_text_file)."""
        if hasattr(self._conn, "call"):
            return await self._conn.call(method, params)
        if hasattr(self._conn, "request"):
            return await self._conn.request(method, params)
        if method == "fs/read_text_file" and hasattr(self._conn, "read_text_file"):
            return await self._conn.read_text_file(
                params.get("sessionId", ""),
                params.get("path", ""),
                line=params.get("line"),
                limit=params.get("limit"),
            )
        if method == "fs/write_text_file" and hasattr(self._conn, "write_text_file"):
            return await self._conn.write_text_file(
                params.get("sessionId", ""),
                params.get("path", ""),
                params.get("content", ""),
            )
        raise NotImplementedError(
            f"Client does not expose call/request or {method}; cannot open file in editor."
        )

    def _make_acp_fs_tools(self, session_id: str) -> list[Any]:
        """Build ACP-backed read/write file tools so Zed opens and focuses the file."""
        from langchain_core.tools import StructuredTool

        read_ok, write_ok = self._client_fs_capable()
        tools: list[Any] = []

        if read_ok:
            async def _acp_read_file(
                path: str,
                line: Optional[int] = None,
                limit: Optional[int] = None,
            ) -> str:
                params: dict[str, Any] = {"sessionId": session_id, "path": path}
                if line is not None:
                    params["line"] = line
                if limit is not None:
                    params["limit"] = limit
                result = await self._call_client("fs/read_text_file", params)
                if isinstance(result, dict):
                    return result.get("content", "")
                return str(result)

            tools.append(
                StructuredTool.from_function(
                    coroutine=_acp_read_file,
                    name="acp_read_file",
                    description=(
                        "Read a file via the editor (ACP). Opens and focuses the file in Zed. "
                        "Use this instead of code_editor when you need to read or open a specific file in the current editor."
                    ),
                    args_schema=None,
                )
            )

        if write_ok:
            async def _acp_write_file(path: str, content: str) -> str:
                result = await self._call_client(
                    "fs/write_text_file",
                    {"sessionId": session_id, "path": path, "content": content},
                )
                return "Written." if result is None else str(result)

            tools.append(
                StructuredTool.from_function(
                    coroutine=_acp_write_file,
                    name="acp_write_file",
                    description=(
                        "Write a file via the editor (ACP). Creates or overwrites the file and opens it in Zed. "
                        "Use this instead of pasting code in chat so the file is opened and focused in the editor."
                    ),
                    args_schema=None,
                )
            )

        return tools

    @staticmethod
    def _tool_kind(name: str) -> str:
        lower = name.lower()
        if lower in {"terminal", "execute_command"}:
            return "execute"
        if "read" in lower:
            return "read"
        if any(tok in lower for tok in ("edit", "write", "create", "code_editor")):
            return "edit"
        if "search" in lower:
            return "search"
        if any(tok in lower for tok in ("delete", "remove")):
            return "delete"
        if any(tok in lower for tok in ("move", "rename")):
            return "move"
        if any(tok in lower for tok in ("fetch", "download", "request", "browse")):
            return "fetch"
        return "other"

    @staticmethod
    def _collect_json_paths(obj: Any) -> list[str]:
        paths: list[str] = []
        if isinstance(obj, dict):
            for key, value in obj.items():
                key_lower = str(key).lower()
                if (
                    isinstance(value, str)
                    and any(tok in key_lower for tok in ("path", "file", "dir", "cwd"))
                ):
                    paths.append(value)
                paths.extend(AtomOSAgent._collect_json_paths(value))
        elif isinstance(obj, list):
            for item in obj:
                paths.extend(AtomOSAgent._collect_json_paths(item))
        return paths

    def _extract_locations(
        self,
        text: str,
        session_id: str,
    ) -> list[dict[str, Any]]:
        if not text:
            return []

        candidates: list[str] = []
        stripped = text.strip()
        if stripped:
            try:
                parsed = json.loads(stripped)
                candidates.extend(self._collect_json_paths(parsed))
            except Exception:
                pass

        candidates.extend(
            re.findall(r"(?:^|[\s\"'=(])(/[^\s\"')]+)", text)
        )

        cwd = self._session_cwds.get(session_id, "")
        home = os.path.expanduser("~")
        seen: set[str] = set()
        locations: list[dict[str, Any]] = []
        for raw in candidates:
            candidate = raw.strip()
            if not candidate:
                continue
            if candidate.startswith("~"):
                candidate = os.path.expanduser(candidate)
            elif not os.path.isabs(candidate) and cwd:
                candidate = os.path.join(cwd, candidate)

            path = os.path.normpath(candidate)
            if not os.path.isabs(path):
                continue
            if cwd and not path.startswith(cwd):
                # Allow home-relative paths (e.g. "~/project/file.py") that may
                # fall outside the session cwd while still being user-owned.
                if not (home and path.startswith(home)):
                    continue
            if home and not path.startswith(home) and cwd and not path.startswith(cwd):
                continue
            if path in seen:
                continue
            seen.add(path)
            locations.append({"path": path, "line": 0})
            if len(locations) >= 5:
                break
        return locations

    @staticmethod
    def _supports_kwarg(func: Any, name: str) -> bool:
        try:
            return name in inspect.signature(func).parameters
        except (TypeError, ValueError):
            return False

    def _build_start_tool_call_update(
        self,
        tool_call_id: str,
        title: str,
        kind: str,
        status: str,
        locations: list[dict[str, Any]] | None = None,
    ) -> Any:
        kwargs: dict[str, Any] = {"kind": kind, "status": status}
        if locations and self._supports_kwarg(start_tool_call, "locations"):
            kwargs["locations"] = locations
        return start_tool_call(tool_call_id, title, **kwargs)

    def _build_update_tool_call_update(
        self,
        tool_call_id: str,
        *,
        status: str | None = None,
        content: list[Any] | None = None,
        locations: list[dict[str, Any]] | None = None,
    ) -> Any:
        kwargs: dict[str, Any] = {}
        if status is not None:
            kwargs["status"] = status
        if content is not None:
            kwargs["content"] = content
        if locations and self._supports_kwarg(update_tool_call, "locations"):
            kwargs["locations"] = locations
        return update_tool_call(tool_call_id, **kwargs)

    async def _stream_agent(
        self,
        agent: Any,
        config: dict,
        text: str,
        session_id: str,
    ) -> None:
        current_tool_call = ""
        current_tc_id = ""
        current_locations: list[dict[str, Any]] = []

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
                        tc_args = tc.get("args", "")
                        current_locations = self._extract_locations(
                            tc_args if isinstance(tc_args, str) else str(tc_args),
                            session_id,
                        )
                        update = self._build_start_tool_call_update(
                            current_tc_id,
                            current_tool_call,
                            kind=self._tool_kind(current_tool_call),
                            status="in_progress",
                            locations=current_locations,
                        )
                        await self._conn.session_update(
                            session_id=session_id, update=update,
                        )
                    elif current_tc_id:
                        tc_args = tc.get("args", "")
                        args_text = tc_args if isinstance(tc_args, str) else str(tc_args)
                        locations = self._extract_locations(args_text, session_id)
                        if locations and locations != current_locations:
                            current_locations = locations
                            update = self._build_update_tool_call_update(
                                current_tc_id,
                                status="in_progress",
                                locations=current_locations,
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
                if current_tc_id:
                    payload: list[Any] | None = None
                    if isinstance(content, str) and content:
                        result_locations = self._extract_locations(content, session_id)
                        if result_locations:
                            current_locations = result_locations
                        payload = [tool_content(text_block(content))]
                    update = self._build_update_tool_call_update(
                        current_tc_id,
                        status="completed",
                        content=payload,
                        locations=current_locations,
                    )
                    await self._conn.session_update(
                        session_id=session_id, update=update,
                    )
                current_tool_call = ""
                current_tc_id = ""
                current_locations = []


async def main() -> None:
    await run_agent(AtomOSAgent())


if __name__ == "__main__":
    asyncio.run(main())
