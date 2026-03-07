import asyncio
import logging
import uuid

import grpc
import grpc.aio

import bridge_pb2
import bridge_pb2_grpc
from agent_factory import create_agent_for_query
from tool_registry import retrieve_tools, ensure_registry
from langchain_core.messages import AIMessage, HumanMessage
from secret_store import CredentialRequiredError, store_secret, has_secret


def _format_tool_output(content: str, tool_name: str) -> str:
    """Wrap tool output in a markdown fenced code block.

    The applet's markdown renderer displays these as terminal-style
    boxes with monospace font and a distinct background.
    """
    safe = content.replace("```", "` ` `")
    return f"\n```\n{safe}\n```\n"


class AgentServiceServicer(bridge_pb2_grpc.AgentServiceServicer):

    async def StreamAgentTurn(self, request, context):
        model_name = (request.model or "").strip() or "default"
        if request.history:
            thread_id = f"conv:{uuid.uuid4()}"
        else:
            thread_id = f"default:{model_name}"
        logging.info(
            "StreamAgentTurn received: model=%r  thread_id=%r  prompt_len=%d  history_len=%d",
            model_name,
            thread_id,
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

        agent = create_agent_for_query(request.model, tools, thread_id)
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

            async for chunk, metadata in agent.astream(
                {"messages": messages},
                config=config,
                stream_mode="messages",
            ):
                node = metadata.get("langgraph_node", "")

                if node == "agent":
                    # ChatOllama: tool calls arrive in tool_call_chunks
                    tc_chunks = getattr(chunk, "tool_call_chunks", None) or []
                    for tc in tc_chunks:
                        name = tc.get("name", "") or ""
                        if name:
                            current_tool_call = name
                            last_tool_call = name
                        if current_tool_call:
                            yield bridge_pb2.AgentResponse(
                                content="",
                                done=False,
                                tool_call=current_tool_call,
                                status="Using tool...",
                            )

                    # Anthropic/deepagents: structured content_blocks
                    blocks = getattr(chunk, "content_blocks", None) or []
                    for block in blocks:
                        block_type = block.get("type", "")
                        if block_type == "tool_call_chunk":
                            if block.get("name"):
                                current_tool_call = block["name"]
                                last_tool_call = block["name"]
                            yield bridge_pb2.AgentResponse(
                                content="",
                                done=False,
                                tool_call=current_tool_call or "Tool",
                                status="Using tool...",
                            )
                        elif block_type == "text":
                            text = block.get("text", "")
                            if text:
                                current_tool_call = ""
                                yield bridge_pb2.AgentResponse(
                                    content=text,
                                    done=False,
                                    tool_call="",
                                    status="Thinking...",
                                )

                    # Fallback: plain content string (most common for Ollama)
                    if not tc_chunks and not blocks:
                        content = getattr(chunk, "content", "")
                        if isinstance(content, str) and content and not current_tool_call:
                            yield bridge_pb2.AgentResponse(
                                content=content,
                                done=False,
                                tool_call="",
                                status="Thinking...",
                            )

                elif node == "tools":
                    current_tool_call = ""
                    content = getattr(chunk, "content", "")
                    if isinstance(content, str) and content:
                        formatted = _format_tool_output(content, last_tool_call)
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
