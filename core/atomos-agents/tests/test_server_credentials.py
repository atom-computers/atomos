"""
Tests for the credential management additions to server.py:

- StoreSecret RPC stores via secrets.store_secret()
- HasSecret RPC checks via secrets.has_secret()
- StreamAgentTurn emits credential_required when CredentialRequiredError is raised
- Proto field and message serialisation for new types
"""
import asyncio
import pytest
from unittest.mock import MagicMock, patch
from langgraph.graph.state import CompiledStateGraph

import bridge_pb2


# ---------------------------------------------------------------------------
# Proto serialisation for new message types
# ---------------------------------------------------------------------------


class TestNewProtoMessages:
    def test_agent_response_has_credential_required_field(self):
        resp = bridge_pb2.AgentResponse(
            content="need key",
            done=True,
            status="credential_required",
            credential_required="browser_use_api_key",
        )
        assert resp.credential_required == "browser_use_api_key"
        assert resp.status == "credential_required"
        assert resp.done is True

    def test_agent_response_credential_required_defaults_to_empty(self):
        resp = bridge_pb2.AgentResponse(content="hello", done=False)
        assert resp.credential_required == ""

    def test_store_secret_request_fields(self):
        req = bridge_pb2.StoreSecretRequest(
            service="atomos",
            key="browser_use_api_key",
            value="sk-test-1234",
        )
        assert req.service == "atomos"
        assert req.key == "browser_use_api_key"
        assert req.value == "sk-test-1234"

    def test_store_secret_response_success(self):
        resp = bridge_pb2.StoreSecretResponse(success=True)
        assert resp.success is True
        assert resp.error == ""

    def test_store_secret_response_failure(self):
        resp = bridge_pb2.StoreSecretResponse(success=False, error="D-Bus unavailable")
        assert resp.success is False
        assert resp.error == "D-Bus unavailable"

    def test_has_secret_request_fields(self):
        req = bridge_pb2.HasSecretRequest(service="atomos", key="browser_use_api_key")
        assert req.service == "atomos"
        assert req.key == "browser_use_api_key"

    def test_has_secret_response_exists_true(self):
        resp = bridge_pb2.HasSecretResponse(exists=True)
        assert resp.exists is True

    def test_has_secret_response_exists_false(self):
        resp = bridge_pb2.HasSecretResponse(exists=False)
        assert resp.exists is False


# ---------------------------------------------------------------------------
# StoreSecret RPC  (async def in grpc.aio servicer)
# ---------------------------------------------------------------------------


class TestStoreSecretRPC:
    def _make_request(self, key="browser_use_api_key", value="sk-test"):
        req = MagicMock()
        req.service = "atomos"
        req.key = key
        req.value = value
        return req

    def test_store_secret_calls_store_secret(self):
        with patch("server.store_secret") as mock_store:
            from server import AgentServiceServicer
            servicer = AgentServiceServicer()
            response = asyncio.run(
                servicer.StoreSecret(self._make_request(), context=MagicMock())
            )

        mock_store.assert_called_once_with("browser_use_api_key", "sk-test")
        assert response.success is True
        assert response.error == ""

    def test_store_secret_returns_error_on_exception(self):
        with patch("server.store_secret", side_effect=Exception("write failed")):
            from server import AgentServiceServicer
            servicer = AgentServiceServicer()
            response = asyncio.run(
                servicer.StoreSecret(self._make_request(), context=MagicMock())
            )

        assert response.success is False
        assert "write failed" in response.error

    def test_store_secret_value_not_passed_to_agent(self):
        """The secret value must stay within store_secret — never reach the agent."""
        stored_args = []

        def capturing_store(key, value):
            stored_args.append((key, value))

        with patch("server.store_secret", side_effect=capturing_store):
            from server import AgentServiceServicer
            servicer = AgentServiceServicer()
            asyncio.run(
                servicer.StoreSecret(self._make_request(value="top_secret_key"), MagicMock())
            )

        assert stored_args[0] == ("browser_use_api_key", "top_secret_key")


# ---------------------------------------------------------------------------
# HasSecret RPC  (async def in grpc.aio servicer)
# ---------------------------------------------------------------------------


class TestHasSecretRPC:
    def _make_request(self, key="browser_use_api_key"):
        req = MagicMock()
        req.service = "atomos"
        req.key = key
        return req

    def test_returns_true_when_secret_exists(self):
        with patch("server.has_secret", return_value=True):
            from server import AgentServiceServicer
            servicer = AgentServiceServicer()
            response = asyncio.run(
                servicer.HasSecret(self._make_request(), context=MagicMock())
            )

        assert response.exists is True

    def test_returns_false_when_secret_absent(self):
        with patch("server.has_secret", return_value=False):
            from server import AgentServiceServicer
            servicer = AgentServiceServicer()
            response = asyncio.run(
                servicer.HasSecret(self._make_request(), context=MagicMock())
            )

        assert response.exists is False


# ---------------------------------------------------------------------------
# StreamAgentTurn — CredentialRequiredError handling
# ---------------------------------------------------------------------------


class TestStreamAgentTurnCredentialFlow:
    def _make_request(self, prompt="browse the web for me"):
        req = MagicMock()
        req.prompt = prompt
        req.model = "llama3"
        req.context = []
        req.images = []
        return req

    def _run_with_agent_error(self, error):
        """Build an agent whose astream() raises the given error on first iteration."""
        async def raising_astream(*args, **kwargs):
            raise error
            yield  # makes this an async generator

        mock_agent = MagicMock(spec=CompiledStateGraph)
        mock_agent.astream = raising_astream

        async def run():
            with patch("server.create_agent_for_query", return_value=mock_agent), patch("server.retrieve_tools", return_value=[]), patch("server.ensure_registry"):
                from server import AgentServiceServicer
                servicer = AgentServiceServicer()
                return [r async for r in servicer.StreamAgentTurn(
                    self._make_request(), context=MagicMock()
                )]

        return asyncio.run(run())

    def test_credential_required_error_produces_credential_required_response(self):
        from secret_store import CredentialRequiredError
        responses = self._run_with_agent_error(
            CredentialRequiredError("browser_use_api_key")
        )

        final = responses[-1]
        assert final.done is True
        assert final.status == "credential_required"
        assert final.credential_required == "browser_use_api_key"

    def test_credential_required_response_is_terminal(self):
        """Only one response is emitted and it has done=True."""
        from secret_store import CredentialRequiredError
        responses = self._run_with_agent_error(
            CredentialRequiredError("browser_use_api_key")
        )

        assert len(responses) == 1
        assert responses[0].done is True

    def test_credential_required_does_not_emit_error_status(self):
        """CredentialRequiredError is a normal flow, not a server error."""
        from secret_store import CredentialRequiredError
        responses = self._run_with_agent_error(
            CredentialRequiredError("browser_use_api_key")
        )

        assert responses[0].status != "Error"

    def test_generic_exception_still_emits_error_status(self):
        """Other exceptions must still produce status='Error', not credential_required."""
        responses = self._run_with_agent_error(RuntimeError("unexpected crash"))

        final = responses[-1]
        assert final.done is True
        assert final.status == "Error"
        assert final.credential_required == ""

    def test_credential_key_name_present_in_response(self):
        from secret_store import CredentialRequiredError
        responses = self._run_with_agent_error(
            CredentialRequiredError("my_custom_service_key")
        )
        assert responses[0].credential_required == "my_custom_service_key"

    def test_normal_stream_unaffected_by_credential_handling(self):
        """Standard streaming still works; credential logic doesn't interfere."""
        chunk = MagicMock()
        chunk.content_blocks = [{"type": "text", "text": "hello"}]
        chunk.content = "hello"

        async def normal_astream(*args, **kwargs):
            yield (chunk, {"langgraph_node": "agent"})

        mock_agent = MagicMock(spec=CompiledStateGraph)
        mock_agent.astream = normal_astream

        async def run():
            with patch("server.create_agent_for_query", return_value=mock_agent), patch("server.retrieve_tools", return_value=[]), patch("server.ensure_registry"):
                from server import AgentServiceServicer
                servicer = AgentServiceServicer()
                return [r async for r in servicer.StreamAgentTurn(
                    self._make_request(), MagicMock()
                )]

        responses = asyncio.run(run())
        content_responses = [r for r in responses if r.content]
        assert any("hello" in r.content for r in content_responses)
        final = responses[-1]
        assert final.done is True
        assert final.credential_required == ""
