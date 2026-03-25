import asyncio
import json
import logging
import re
import uuid

import grpc
import grpc.aio

import bridge_pb2
import bridge_pb2_grpc
from agent_factory import create_agent_for_query
from tool_registry import retrieve_tools, ensure_registry
from langchain_core.messages import AIMessage, HumanMessage
from secret_store import CredentialRequiredError, store_secret, has_secret
import security

_terminal_tab_counter = 0
_ui_block_counter = 0

_TERMINAL_TOOLS = frozenset({"terminal"})

_SILENT_EDITOR_TOOLS = frozenset({
    "read_file", "search_in_files",
})

# ── Approval registry ─────────────────────────────────────────────────────────
# Maps block_id → (asyncio.Event, result_dict).  When the applet's
# SendApproval RPC arrives, the event is set and the result dict is populated.
# NOTE: The security module's _approval_events is used for tool-level
# approvals; this dict handles legacy/direct approval prompts.
_pending_approvals: dict[str, tuple[asyncio.Event, dict]] = {}

_APPROVAL_TIMEOUT_SECONDS = 300


def _next_tab_id() -> str:
    global _terminal_tab_counter
    _terminal_tab_counter += 1
    return f"tab-{_terminal_tab_counter}"


def _next_block_id() -> str:
    global _ui_block_counter
    _ui_block_counter += 1
    return f"blk-{_ui_block_counter}"


def send_ui_block(
    block_type: str,
    *,
    block_id: str | None = None,
    title: str = "",
    description: str = "",
    body: str = "",
    columns: list[str] | None = None,
    rows: list[list[str]] | None = None,
    actions: list[dict] | None = None,
    progress: float = 0.0,
    progress_label: str = "",
    file_paths: list[str] | None = None,
    diff_content: str = "",
    diff_language: str = "",
) -> bridge_pb2.AgentResponse:
    """Build an AgentResponse carrying a single UiBlock.

    Agents call this to emit structured UI elements (cards, tables,
    approval prompts, progress bars, file trees, diff views).
    """
    type_map = {
        "card": bridge_pb2.UI_BLOCK_CARD,
        "table": bridge_pb2.UI_BLOCK_TABLE,
        "approval_prompt": bridge_pb2.UI_BLOCK_APPROVAL_PROMPT,
        "progress_bar": bridge_pb2.UI_BLOCK_PROGRESS_BAR,
        "file_tree": bridge_pb2.UI_BLOCK_FILE_TREE,
        "diff_view": bridge_pb2.UI_BLOCK_DIFF_VIEW,
    }

    proto_actions = []
    for a in (actions or []):
        proto_actions.append(bridge_pb2.UiBlockAction(
            id=a.get("id", ""),
            label=a.get("label", ""),
            style=a.get("style", "secondary"),
        ))

    proto_rows = []
    for r in (rows or []):
        proto_rows.append(bridge_pb2.TableRow(cells=list(r)))

    block = bridge_pb2.UiBlock(
        block_id=block_id or _next_block_id(),
        block_type=type_map.get(block_type, bridge_pb2.UI_BLOCK_CARD),
        title=title,
        description=description,
        body=body,
        columns=columns or [],
        rows=proto_rows,
        actions=proto_actions,
        progress=progress,
        progress_label=progress_label,
        file_paths=file_paths or [],
        diff_content=diff_content,
        diff_language=diff_language,
    )

    return bridge_pb2.AgentResponse(ui_blocks=[block])


async def send_approval_prompt(
    block_id: str | None = None,
    *,
    title: str = "Approval required",
    description: str = "",
    body: str = "",
    actions: list[dict] | None = None,
) -> str:
    """Emit an approval prompt UiBlock and block until the user responds.

    Returns the action_id chosen by the user (e.g. ``"approve"``
    or ``"deny"``), or ``"__timeout__"`` if the user doesn't respond
    within ``_APPROVAL_TIMEOUT_SECONDS``.

    This is a coroutine — callers must ``await`` it.  It is designed to
    be used inside ``StreamAgentTurn`` by yielding the response first,
    then awaiting the result::

        bid = _next_block_id()
        yield send_ui_block("approval_prompt", block_id=bid, ...)
        action = await send_approval_prompt_wait(bid)
    """
    bid = block_id or _next_block_id()
    if actions is None:
        actions = [
            {"id": "approve", "label": "Approve", "style": "primary"},
            {"id": "deny", "label": "Deny", "style": "danger"},
        ]

    event = asyncio.Event()
    result: dict = {}
    _pending_approvals[bid] = (event, result)

    try:
        await asyncio.wait_for(event.wait(), timeout=_APPROVAL_TIMEOUT_SECONDS)
        return result.get("action_id", "__timeout__")
    except asyncio.TimeoutError:
        return "__timeout__"
    finally:
        _pending_approvals.pop(bid, None)


def _parse_exit_code(output: str) -> int:
    """Extract exit code from shell tool output, defaulting to 0."""
    for line in reversed(output.splitlines()):
        line = line.strip()
        if line.startswith("[exit ") and line.endswith("]"):
            try:
                return int(line[6:-1])
            except ValueError:
                pass
        if line == "[timed out after" or "timed out" in line:
            return 124
    return 0


def _extract_command(output: str) -> str:
    """Extract the command from the first line (e.g. '$ ls -la' → 'ls -la')."""
    for line in output.splitlines():
        if line.startswith("$ "):
            return line[2:].strip()
    return "Shell"


def _format_tool_output(content: str, tool_name: str) -> str:
    """Wrap tool output in a markdown fenced code block."""
    safe = content.replace("```", "` ` `")
    return f"\n```\n{safe}\n```\n"


def _coerce_json_dict(content: str) -> dict | None:
    """Parse a JSON object from *content*, tolerating fences and leading junk."""
    if not isinstance(content, str) or not content.strip():
        return None
    s = content.strip()
    if s.startswith("```"):
        lines = s.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        while lines and lines[-1].strip() == "```":
            lines.pop()
        s = "\n".join(lines).strip()
    try:
        data = json.loads(s)
        return data if isinstance(data, dict) else None
    except (json.JSONDecodeError, TypeError):
        pass
    start = s.find("{")
    if start < 0:
        return None
    try:
        data, _end = json.JSONDecoder().raw_decode(s, start)
        return data if isinstance(data, dict) else None
    except (json.JSONDecodeError, TypeError, ValueError):
        return None


# ── Structured tool output → UI blocks ────────────────────────────────────

def _try_render_tool_ui(content: str, tool_name: str) -> list[bridge_pb2.AgentResponse] | None:
    """Attempt to parse *content* as JSON and render it as UI blocks.

    Returns a list of ``AgentResponse`` messages carrying UI blocks, or
    ``None`` if the output doesn't match any known pattern.
    """
    data = _coerce_json_dict(content)
    if data is None:
        return None

    if "papers" in data and isinstance(data["papers"], list):
        return _render_papers(data, tool_name)

    if "status" in data and "paper_id" in data and "content" in data:
        return _render_paper_content(data)

    if "status" in data and "message" in data:
        return _render_status_message(data, tool_name)

    if tool_name.startswith("arxiv_"):
        title = str(data.get("status", "arXiv")).replace("_", " ").title()
        return [send_ui_block("card", title=title, description="", body=data.get("message", ""))]

    return None


def _render_papers(data: dict, tool_name: str) -> list[bridge_pb2.AgentResponse]:
    """Render a list of papers as a table UI block."""
    papers = data["papers"]
    if not papers:
        return [send_ui_block("card", title="No papers found")]

    columns = ["ID", "Title"]
    has_authors = any("authors" in p for p in papers)
    has_date = any(p.get("published") or p.get("date") for p in papers)
    if has_authors:
        columns.append("Authors")
    if has_date:
        columns.append("Published")

    rows: list[list[str]] = []
    for p in papers:
        row = [
            p.get("id", p.get("paper_id", "")),
            p.get("title", ""),
        ]
        if has_authors:
            authors = p.get("authors", "")
            if isinstance(authors, list):
                authors = ", ".join(str(a) for a in authors[:3])
                if len(p.get("authors", [])) > 3:
                    authors += " et al."
            row.append(str(authors))
        if has_date:
            row.append(p.get("published", p.get("date", "")))
        rows.append(row)

    total = data.get("total_results", len(papers))
    title = f"arXiv Results ({total} found)" if "search" in tool_name else f"Papers ({total})"

    return [send_ui_block("table", title=title, columns=columns, rows=rows)]


def _render_paper_content(data: dict) -> list[bridge_pb2.AgentResponse]:
    """Render a single paper's content as a card."""
    title = data.get("title", data.get("paper_id", "Paper"))
    body = data.get("content", "")
    if len(body) > 4000:
        body = body[:4000] + "\n\n*… (truncated)*"
    return [send_ui_block(
        "card",
        title=title,
        description=f"arXiv:{data.get('paper_id', '')}",
        body=body,
    )]


def _render_status_message(data: dict, tool_name: str) -> list[bridge_pb2.AgentResponse]:
    """Render a status/message JSON as a card."""
    title = data.get("status", "").replace("_", " ").title()
    return [send_ui_block("card", title=title, description=data.get("message", ""))]


_RAW_TC_OPEN = re.compile(r"<(?:\|)?tool_call(?:\|)?>")
_RAW_TC_CLOSE = re.compile(r"</(?:\|)?(?:tool_call|arg_value|tool_response)(?:\|)?>")
_MAX_TC_BUFFER = 4096


class _ToolCallFilter:
    """Buffer streamed text and strip raw tool-call markup.

    Some models emit tool calls as plain text (e.g.
    ``<tool_call>func(arg="val")</arg_value>``) instead of structured
    tool-call objects.  This filter absorbs that markup so it never
    reaches the UI, even when the tags span multiple stream chunks.
    """

    def __init__(self) -> None:
        self._buf = ""
        self._inside = False

    def feed(self, text: str) -> str:
        """Accept a text chunk; return only the portion safe to emit."""
        if self._inside:
            self._buf += text
            m = _RAW_TC_CLOSE.search(self._buf)
            if m:
                logging.warning(
                    "Stripped raw tool-call markup from model output: %.200s",
                    self._buf,
                )
                remainder = self._buf[m.end():]
                self._buf = ""
                self._inside = False
                return self.feed(remainder) if remainder.strip() else ""
            if len(self._buf) > _MAX_TC_BUFFER:
                result = self._buf
                self._buf = ""
                self._inside = False
                return result
            return ""

        m = _RAW_TC_OPEN.search(text)
        if m:
            self._inside = True
            before = text[: m.start()]
            self._buf = text[m.start():]
            close = _RAW_TC_CLOSE.search(self._buf)
            if close:
                logging.warning(
                    "Stripped raw tool-call markup from model output: %.200s",
                    self._buf,
                )
                remainder = self._buf[close.end():]
                self._buf = ""
                self._inside = False
                after = self.feed(remainder) if remainder.strip() else ""
                return before + after
            return before

        return text

    def flush(self) -> str:
        """Return any buffered text at end-of-stream."""
        result = self._buf
        self._buf = ""
        self._inside = False
        return result


class AgentServiceServicer(bridge_pb2_grpc.AgentServiceServicer):

    async def StreamAgentTurn(self, request, context):
        model_name = (request.model or "").strip() or "default"
        requested_thread_id = (getattr(request, "thread_id", "") or "").strip()
        if requested_thread_id:
            thread_id = requested_thread_id
        elif request.history:
            thread_id = f"conv:{uuid.uuid4()}"
        else:
            thread_id = f"default:{model_name}"
        logging.info(
            "StreamAgentTurn received: model=%r  thread_id=%r  requested_thread_id=%r  prompt_len=%d  history_len=%d",
            model_name,
            thread_id,
            requested_thread_id,
            len(request.prompt),
            len(request.history),
        )

        tool_query = request.prompt
        if request.history:
            recent = request.history[-4:]
            context_parts = [msg.content for msg in recent]
            context_parts.append(request.prompt)
            tool_query = "\n".join(context_parts)

        try:
            tools = retrieve_tools(tool_query)
        except Exception as exc:
            logging.warning("Tool retrieval failed: %s — proceeding without tools", exc)
            tools = []

        agent = create_agent_for_query(
            request.model,
            tools,
            thread_id,
            query=tool_query,
        )
        config = {"configurable": {"thread_id": thread_id, "session_id": thread_id}}

        messages = []
        for msg in request.history:
            if msg.role == "user":
                messages.append(HumanMessage(content=msg.content))
            elif msg.role == "assistant":
                messages.append(AIMessage(content=msg.content))
        if not messages or not isinstance(messages[-1], HumanMessage):
            messages.append(HumanMessage(content=request.prompt))

        try:
            current_tool_call = ""
            last_tool_call = ""
            pending_terminal_tab = ""
            tc_filter = _ToolCallFilter()
            arxiv_accum = ""
            arxiv_sticky = ""

            # Merge the agent stream with the approval-request side-channel.
            # When a tool calls security.request_approval(), the request
            # appears on the approval queue; we yield the approval UiBlock
            # to the client while the tool awaits the user's response.
            output_queue: asyncio.Queue = asyncio.Queue()
            approval_queue = security._get_approval_queue()

            _SENTINEL = object()

            async def _run_agent():
                try:
                    async for chunk, metadata in agent.astream(
                        {"messages": messages},
                        config=config,
                        stream_mode="messages",
                    ):
                        await output_queue.put(("chunk", chunk, metadata))
                except Exception as exc:
                    await output_queue.put(("error", exc, None))
                finally:
                    await output_queue.put(("done", None, None))

            async def _check_approvals():
                while True:
                    req = await approval_queue.get()
                    await output_queue.put(("approval", req, None))

            agent_task = asyncio.create_task(_run_agent())
            approval_task = asyncio.create_task(_check_approvals())

            try:
                while True:
                    msg_type, data, meta = await output_queue.get()

                    if msg_type == "done":
                        break
                    elif msg_type == "error":
                        raise data
                    elif msg_type == "approval":
                        bid = data["block_id"]
                        yield send_ui_block(
                            "approval_prompt",
                            block_id=bid,
                            title="Approval required",
                            description=data.get("description", ""),
                            body=f"**{data['tool_name']}** wants to perform an action.\n\n{data.get('description', '')}",
                            actions=[
                                {"id": "approve", "label": "Approve", "style": "primary"},
                                {"id": "deny", "label": "Deny", "style": "danger"},
                            ],
                        )
                        continue

                    # msg_type == "chunk"
                    chunk = data
                    metadata = meta
                    node = metadata.get("langgraph_node", "")

                    if node == "agent":
                        tc_chunks = getattr(chunk, "tool_call_chunks", None) or []
                        for tc in tc_chunks:
                            name = tc.get("name", "") or ""
                            if name:
                                if name.startswith("arxiv_"):
                                    arxiv_accum = ""
                                    arxiv_sticky = name
                                else:
                                    arxiv_accum = ""
                                    arxiv_sticky = ""
                                current_tool_call = name
                                last_tool_call = name
                                if name in _TERMINAL_TOOLS and not pending_terminal_tab:
                                    pending_terminal_tab = _next_tab_id()
                                    yield bridge_pb2.AgentResponse(
                                        terminal_event=json.dumps({
                                            "type": "open",
                                            "tab_id": pending_terminal_tab,
                                            "title": "$ ...",
                                            "cwd": "",
                                        }),
                                    )
                            if current_tool_call:
                                yield bridge_pb2.AgentResponse(
                                    content="",
                                    done=False,
                                    tool_call=current_tool_call,
                                    status="Using tool...",
                                )

                        blocks = getattr(chunk, "content_blocks", None) or []
                        for block in blocks:
                            block_type = block.get("type", "")
                            if block_type == "tool_call_chunk":
                                if block.get("name"):
                                    nm = block["name"]
                                    if nm.startswith("arxiv_"):
                                        arxiv_accum = ""
                                        arxiv_sticky = nm
                                    else:
                                        arxiv_accum = ""
                                        arxiv_sticky = ""
                                    current_tool_call = nm
                                    last_tool_call = nm
                                    if nm in _TERMINAL_TOOLS and not pending_terminal_tab:
                                        pending_terminal_tab = _next_tab_id()
                                        yield bridge_pb2.AgentResponse(
                                            terminal_event=json.dumps({
                                                "type": "open",
                                                "tab_id": pending_terminal_tab,
                                                "title": "$ ...",
                                                "cwd": "",
                                            }),
                                        )
                                yield bridge_pb2.AgentResponse(
                                    content="",
                                    done=False,
                                    tool_call=current_tool_call or "Tool",
                                    status="Using tool...",
                                )
                            elif block_type == "text":
                                text = tc_filter.feed(block.get("text", ""))
                                if text:
                                    current_tool_call = ""
                                    yield bridge_pb2.AgentResponse(
                                        content=text,
                                        done=False,
                                        tool_call="",
                                        status="Thinking...",
                                    )

                        if not tc_chunks and not blocks:
                            raw = getattr(chunk, "content", "")
                            if isinstance(raw, str) and raw and not current_tool_call:
                                content = tc_filter.feed(raw)
                                if content:
                                    yield bridge_pb2.AgentResponse(
                                        content=content,
                                        done=False,
                                        tool_call="",
                                        status="Thinking...",
                                    )

                    elif node == "tools":
                        current_tool_call = ""
                        content = getattr(chunk, "content", "")

                        if isinstance(content, str) and content and last_tool_call in _TERMINAL_TOOLS:
                            arxiv_accum = ""
                            arxiv_sticky = ""
                            cmd_title = _extract_command(content)
                            exit_code = _parse_exit_code(content)

                            if pending_terminal_tab:
                                tab_id = pending_terminal_tab
                                pending_terminal_tab = ""
                                yield bridge_pb2.AgentResponse(
                                    terminal_event=json.dumps({
                                        "type": "output",
                                        "tab_id": tab_id,
                                        "data": f"$ {cmd_title}",
                                    }),
                                    tool_call="terminal",
                                    status=f"$ {cmd_title}",
                                )
                            else:
                                tab_id = _next_tab_id()
                                yield bridge_pb2.AgentResponse(
                                    terminal_event=json.dumps({
                                        "type": "open",
                                        "tab_id": tab_id,
                                        "title": f"$ {cmd_title}",
                                        "cwd": "",
                                    }),
                                )

                            yield bridge_pb2.AgentResponse(
                                terminal_event=json.dumps({
                                    "type": "output",
                                    "tab_id": tab_id,
                                    "data": content,
                                }),
                            )
                            yield bridge_pb2.AgentResponse(
                                terminal_event=json.dumps({
                                    "type": "close",
                                    "tab_id": tab_id,
                                    "exit_code": exit_code,
                                }),
                            )
                        elif isinstance(content, str) and content and last_tool_call in _SILENT_EDITOR_TOOLS:
                            arxiv_accum = ""
                            arxiv_sticky = ""
                            pass
                        elif isinstance(content, str) and content:
                            arxiv_name = (
                                last_tool_call
                                if last_tool_call.startswith("arxiv_")
                                else arxiv_sticky
                            )
                            if arxiv_name.startswith("arxiv_"):
                                arxiv_accum += content
                                combined = arxiv_accum
                                ui_responses = _try_render_tool_ui(
                                    combined, arxiv_name
                                )
                                if ui_responses:
                                    for resp in ui_responses:
                                        yield resp
                                    arxiv_accum = ""
                                    arxiv_sticky = ""
                                elif (
                                    combined.strip().startswith("{")
                                    and _coerce_json_dict(combined) is None
                                ):
                                    pass
                                else:
                                    formatted = _format_tool_output(
                                        combined, arxiv_name
                                    )
                                    yield bridge_pb2.AgentResponse(
                                        content=formatted,
                                        done=False,
                                        tool_call="",
                                        status="",
                                    )
                                    arxiv_accum = ""
                                    arxiv_sticky = ""
                            else:
                                ui_responses = _try_render_tool_ui(
                                    content, last_tool_call
                                )
                                if ui_responses:
                                    for resp in ui_responses:
                                        yield resp
                                else:
                                    formatted = _format_tool_output(
                                        content, last_tool_call
                                    )
                                    yield bridge_pb2.AgentResponse(
                                        content=formatted,
                                        done=False,
                                        tool_call="",
                                        status="",
                                    )
                        else:
                            yield bridge_pb2.AgentResponse(
                                content="",
                                done=False,
                                tool_call="",
                                status="Thinking...",
                            )
                        last_tool_call = ""
            finally:
                approval_task.cancel()
                try:
                    await approval_task
                except asyncio.CancelledError:
                    pass

            if pending_terminal_tab:
                yield bridge_pb2.AgentResponse(
                    terminal_event=json.dumps({
                        "type": "close",
                        "tab_id": pending_terminal_tab,
                        "exit_code": -1,
                    }),
                )
                pending_terminal_tab = ""

            yield bridge_pb2.AgentResponse(
                content="",
                done=True,
                tool_call="",
                status="Done",
            )

        except CredentialRequiredError as cred_err:
            logging.warning("Credential required: %s", cred_err.key)
            yield bridge_pb2.AgentResponse(
                content="A cloud API key is required to complete this browser task.",
                done=True,
                tool_call="",
                status="credential_required",
                credential_required=cred_err.key,
            )

        except Exception as e:
            logging.error("Error during streaming: %s", e, exc_info=True)
            if pending_terminal_tab:
                yield bridge_pb2.AgentResponse(
                    terminal_event=json.dumps({
                        "type": "close",
                        "tab_id": pending_terminal_tab,
                        "exit_code": -1,
                    }),
                )
                pending_terminal_tab = ""
            yield bridge_pb2.AgentResponse(
                content=str(e),
                done=True,
                tool_call="",
                status="Error",
            )

    async def StoreSecret(self, request, context):
        """Store a credential in OS keyring (gnome-keyring / encrypted file fallback)."""
        try:
            store_secret(request.key, request.value)
            return bridge_pb2.StoreSecretResponse(success=True)
        except Exception as exc:
            logging.error("StoreSecret failed for key=%s: %s", request.key, exc)
            return bridge_pb2.StoreSecretResponse(success=False, error=str(exc))

    async def HasSecret(self, request, context):
        """Check whether a credential is already stored."""
        return bridge_pb2.HasSecretResponse(exists=has_secret(request.key))

    async def SendApproval(self, request, context):
        """Receive an approval/denial from the applet UI for a pending
        approval prompt.  Routes to the security module's approval system
        (for tool-level approvals) or the legacy ``_pending_approvals``
        dict (for direct approval prompts)."""
        block_id = request.block_id
        action_id = request.action_id
        logging.info("SendApproval: block_id=%s action_id=%s", block_id, action_id)

        if security.resolve_approval(block_id, action_id):
            return bridge_pb2.ApprovalReply(success=True)

        entry = _pending_approvals.get(block_id)
        if entry is None:
            logging.warning("SendApproval: no pending approval for block_id=%s", block_id)
            return bridge_pb2.ApprovalReply(success=False)

        event, result = entry
        result["action_id"] = action_id
        event.set()
        return bridge_pb2.ApprovalReply(success=True)


async def serve():
    import os

    logging.info("Initializing tool registry...")
    try:
        ensure_registry()
    except Exception as exc:
        logging.error("Tool registry initialization failed: %s — tools may be unavailable", exc)

    port = os.environ.get("PORT", "50051")
    server = grpc.aio.server()
    bridge_pb2_grpc.add_AgentServiceServicer_to_server(AgentServiceServicer(), server)
    server.add_insecure_port(f'[::]:{port}')
    await server.start()
    logging.info("Agent Server starting on port %s...", port)
    await server.wait_for_termination()



if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    asyncio.run(serve())
