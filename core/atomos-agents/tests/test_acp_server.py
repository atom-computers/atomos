import asyncio
import importlib
import os
import sys
import types
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
if str(SRC) not in sys.path:
    sys.path.insert(0, str(SRC))


class _Record:
    def __init__(self, **kwargs):
        self.__dict__.update(kwargs)


class _FakeChunk:
    def __init__(self, *, tool_call_chunks=None, content=""):
        self.tool_call_chunks = tool_call_chunks or []
        self.content = content


class _FakeConn:
    def __init__(self):
        self.updates = []

    async def session_update(self, session_id, update):
        self.updates.append((session_id, update))


class _FakeStreamAgent:
    def __init__(self, events):
        self._events = events

    async def astream(self, *_args, **_kwargs):
        for event in self._events:
            yield event


def _load_acp_server_with_stubs(monkeypatch):
    acp = types.ModuleType("acp")
    acp.PROTOCOL_VERSION = 1

    class _Agent:
        pass

    async def _run_agent(_agent):
        return None

    def _text_block(text):
        return {"type": "text", "text": text}

    def _tool_content(content):
        return {"type": "content", "content": content}

    def _update_agent_message(content):
        return {"sessionUpdate": "agent_message_chunk", "content": content}

    def _start_tool_call(tool_call_id, title, kind=None, status=None, locations=None):
        return {
            "sessionUpdate": "tool_call",
            "toolCallId": tool_call_id,
            "title": title,
            "kind": kind,
            "status": status,
            "locations": locations or [],
        }

    def _update_tool_call(tool_call_id, status=None, content=None, locations=None):
        return {
            "sessionUpdate": "tool_call_update",
            "toolCallId": tool_call_id,
            "status": status,
            "content": content,
            "locations": locations or [],
        }

    acp.Agent = _Agent
    acp.InitializeResponse = _Record
    acp.NewSessionResponse = _Record
    acp.PromptResponse = _Record
    acp.run_agent = _run_agent
    acp.text_block = _text_block
    acp.update_agent_message = _update_agent_message
    acp.start_tool_call = _start_tool_call
    acp.update_tool_call = _update_tool_call
    acp.tool_content = _tool_content
    monkeypatch.setitem(sys.modules, "acp", acp)

    interfaces = types.ModuleType("acp.interfaces")
    interfaces.Client = type("Client", (), {})
    monkeypatch.setitem(sys.modules, "acp.interfaces", interfaces)

    schema = types.ModuleType("acp.schema")
    for name in (
        "AgentCapabilities",
        "AudioContentBlock",
        "ClientCapabilities",
        "EmbeddedResourceContentBlock",
        "HttpMcpServer",
        "ImageContentBlock",
        "Implementation",
        "McpServerStdio",
        "ResourceContentBlock",
        "SseMcpServer",
        "TextContentBlock",
    ):
        setattr(schema, name, type(name, (), {"__init__": lambda self, **_k: None}))
    monkeypatch.setitem(sys.modules, "acp.schema", schema)

    lc_messages = types.ModuleType("langchain_core.messages")

    class HumanMessage:
        def __init__(self, content):
            self.content = content

    lc_messages.HumanMessage = HumanMessage
    monkeypatch.setitem(sys.modules, "langchain_core.messages", lc_messages)

    agent_factory = types.ModuleType("agent_factory")
    agent_factory.create_agent_for_query = lambda *_a, **_k: None
    monkeypatch.setitem(sys.modules, "agent_factory", agent_factory)

    tool_registry = types.ModuleType("tool_registry")
    tool_registry.retrieve_tools = lambda *_a, **_k: []
    tool_registry.ensure_registry = lambda: True
    monkeypatch.setitem(sys.modules, "tool_registry", tool_registry)

    secret_store = types.ModuleType("secret_store")

    class CredentialRequiredError(Exception):
        def __init__(self, key):
            super().__init__(key)
            self.key = key

    secret_store.CredentialRequiredError = CredentialRequiredError
    monkeypatch.setitem(sys.modules, "secret_store", secret_store)

    sys.modules.pop("acp_server", None)
    return importlib.import_module("acp_server")


def test_extract_locations_from_json_path_variants(monkeypatch):
    acp_server = _load_acp_server_with_stubs(monkeypatch)
    agent = acp_server.AtomOSAgent()
    session_id = "sess-1"
    agent._session_cwds[session_id] = "/home/george/project"

    payload = (
        '{"file_path":"~/demo/main.py",'
        '"relative_path":"src/lib.py",'
        '"dir_path":"/home/george/project/tests"}'
    )
    locations = agent._extract_locations(payload, session_id)
    paths = {loc["path"] for loc in locations}

    assert os.path.expanduser("~/demo/main.py") in paths
    assert "/home/george/project/src/lib.py" in paths
    assert "/home/george/project/tests" in paths
    assert all(loc.get("line") == 0 for loc in locations)


def test_stream_agent_emits_in_progress_and_completed_with_locations(monkeypatch):
    acp_server = _load_acp_server_with_stubs(monkeypatch)
    agent = acp_server.AtomOSAgent()
    session_id = "sess-2"
    agent._session_cwds[session_id] = "/home/george/project"
    agent._conn = _FakeConn()

    events = [
        (
            _FakeChunk(
                tool_call_chunks=[
                    {
                        "name": "edit_file",
                        "args": '{"file_path":"src/main.py"}',
                    }
                ],
                content="",
            ),
            {"langgraph_node": "agent"},
        ),
        (
            _FakeChunk(content="Wrote /home/george/project/src/main.py"),
            {"langgraph_node": "tools"},
        ),
    ]
    stream_agent = _FakeStreamAgent(events)

    asyncio.run(
        agent._stream_agent(
            stream_agent,
            config={"configurable": {"thread_id": "t", "session_id": session_id}},
            text="edit file",
            session_id=session_id,
        )
    )

    updates = [u for _sid, u in agent._conn.updates]
    assert updates[0]["sessionUpdate"] == "tool_call"
    assert updates[0]["status"] == "in_progress"
    assert updates[0]["locations"][0]["path"] == "/home/george/project/src/main.py"

    assert updates[-1]["sessionUpdate"] == "tool_call_update"
    assert updates[-1]["status"] == "completed"
    assert updates[-1]["locations"][0]["path"] == "/home/george/project/src/main.py"


def test_tool_kind_mapping(monkeypatch):
    acp_server = _load_acp_server_with_stubs(monkeypatch)
    AtomOSAgent = acp_server.AtomOSAgent

    assert AtomOSAgent._tool_kind("read_file") == "read"
    assert AtomOSAgent._tool_kind("code_editor") == "edit"
    assert AtomOSAgent._tool_kind("terminal") == "execute"
    assert AtomOSAgent._tool_kind("search_in_files") == "search"
