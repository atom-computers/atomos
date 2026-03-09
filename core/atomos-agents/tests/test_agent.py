import pytest
from unittest.mock import patch, MagicMock
import bridge_pb2


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _clear_llm_cache():
    """Clear the module-level LLM cache between tests."""
    import agent_factory
    agent_factory._llm_cache.clear()


def _make_mock_agent():
    from langgraph.graph.state import CompiledStateGraph
    return MagicMock(spec=CompiledStateGraph)


# ---------------------------------------------------------------------------
# Agent factory tests
# ---------------------------------------------------------------------------

class TestAgentCache:
    """Verify create_agent_for_query builds agents correctly."""

    def setup_method(self):
        _clear_llm_cache()

    def test_same_model_reuses_llm_instance(self):
        """Repeated calls with the same model must reuse the cached LLM."""
        from agent_factory import create_agent_for_query
        with (
            patch("agent_factory._resolve_model", side_effect=lambda m: m),
            patch("agent_factory.create_react_agent", return_value=_make_mock_agent()),
            patch("agent_factory.set_local_model"),
        ):
            create_agent_for_query("llama3", [])
            create_agent_for_query("llama3", [])
            import agent_factory
            assert "llama3" in agent_factory._llm_cache, (
                "LLM should be cached after first call"
            )

    def test_different_models_return_different_agents(self):
        """Switching models must produce distinct agents."""
        agents = []
        with (
            patch("agent_factory._resolve_model", side_effect=lambda m: m),
            patch("agent_factory.create_react_agent", side_effect=lambda **kw: _make_mock_agent()),
            patch("agent_factory.set_local_model"),
        ):
            from agent_factory import create_agent_for_query
            a_llama = create_agent_for_query("llama3", [])
            a_qwen = create_agent_for_query("qwen3:8b", [])
            assert a_llama is not a_qwen, (
                "Different models must produce separate agent instances"
            )

    def test_switching_back_to_previous_model_reuses_llm(self):
        """Switching A→B→A must reuse A's LLM, not recreate it."""
        with (
            patch("agent_factory._resolve_model", side_effect=lambda m: m),
            patch("agent_factory.create_react_agent", return_value=_make_mock_agent()),
            patch("agent_factory.set_local_model"),
        ):
            from agent_factory import create_agent_for_query
            create_agent_for_query("llama3", [])
            create_agent_for_query("qwen3:8b", [])
            create_agent_for_query("llama3", [])
            import agent_factory
            assert len(agent_factory._llm_cache) == 2, (
                "Only two distinct LLM instances should be created"
            )

    def test_set_local_model_called_on_every_request(self):
        """Browser-tool global must be updated on every call."""
        with (
            patch("agent_factory._resolve_model", side_effect=lambda m: m),
            patch("agent_factory.create_react_agent", return_value=_make_mock_agent()),
            patch("agent_factory.set_local_model") as mock_set,
        ):
            from agent_factory import create_agent_for_query
            create_agent_for_query("llama3", [])
            create_agent_for_query("llama3", [])
            assert mock_set.call_count == 2, (
                "set_local_model must be called on every request so the "
                "browser tool always uses the current model"
            )


# ---------------------------------------------------------------------------
# Model resolution tests
# ---------------------------------------------------------------------------

class TestResolveModel:
    """Verify _resolve_model picks the right backend and fallback."""

    def test_local_model_returned_as_is(self):
        """A model installed in Ollama should be returned unchanged."""
        from agent_factory import _resolve_model
        with patch("agent_factory._ollama_installed_models", return_value=["llama3:latest"]):
            assert _resolve_model("llama3:latest") == "llama3:latest"

    def test_cloud_model_with_groq_key(self):
        """A model NOT in Ollama but with a Groq key should be returned unchanged."""
        from agent_factory import _resolve_model
        with (
            patch("agent_factory._ollama_installed_models", return_value=["nomic-embed-text:latest"]),
            patch("agent_factory._get_groq_api_key", return_value="gsk_fake_key"),
        ):
            assert _resolve_model("openai/gpt-oss-20b") == "openai/gpt-oss-20b"

    def test_cloud_model_without_groq_key_falls_back(self):
        """Without a Groq key, a cloud model must fall back to a local model."""
        from agent_factory import _resolve_model
        with (
            patch("agent_factory._ollama_installed_models", return_value=["llama3:latest"]),
            patch("agent_factory._get_groq_api_key", return_value=None),
        ):
            assert _resolve_model("openai/gpt-oss-20b") == "llama3:latest"

    def test_fallback_skips_embedding_models(self):
        """Fallback must never pick an embedding-only model for chat."""
        from agent_factory import _resolve_model
        with (
            patch(
                "agent_factory._ollama_installed_models",
                return_value=["nomic-embed-text:latest", "llama3:latest"],
            ),
            patch("agent_factory._get_groq_api_key", return_value=None),
        ):
            result = _resolve_model("some-cloud-model")
            assert result == "llama3:latest", (
                f"Expected 'llama3:latest' but got {result!r} — "
                "embedding models must be skipped in fallback"
            )

    def test_fallback_all_embedding_returns_requested(self):
        """If every local model is embedding-only, return the requested name."""
        from agent_factory import _resolve_model
        with (
            patch(
                "agent_factory._ollama_installed_models",
                return_value=["nomic-embed-text:latest", "mxbai-embed-large:latest"],
            ),
            patch("agent_factory._get_groq_api_key", return_value=None),
        ):
            assert _resolve_model("openai/gpt-oss-20b") == "openai/gpt-oss-20b"

    def test_empty_or_default_uses_default_model(self):
        """Empty string or 'default' should resolve via DEFAULT_MODEL."""
        from agent_factory import _resolve_model, DEFAULT_MODEL
        with (
            patch("agent_factory._ollama_installed_models", return_value=[DEFAULT_MODEL]),
        ):
            assert _resolve_model("") == DEFAULT_MODEL
            assert _resolve_model("default") == DEFAULT_MODEL


class TestResolveBrowserModel:
    """Verify _resolve_browser_model respects the user's model selection."""

    def test_cloud_model_returned_as_is(self):
        """Cloud models are assumed capable — never overridden."""
        from agent_factory import _resolve_browser_model
        with patch("agent_factory._is_ollama_model", return_value=False):
            assert _resolve_browser_model("openai/gpt-oss-20b") == "openai/gpt-oss-20b"

    def test_local_model_with_known_large_size(self):
        """A local model with parseable size >= minimum is used as-is."""
        from agent_factory import _resolve_browser_model
        with patch("agent_factory._is_ollama_model", return_value=True):
            assert _resolve_browser_model("llama3:8b") == "llama3:8b"

    def test_local_model_with_unknown_size_not_overridden(self):
        """Models whose size can't be parsed from the name should be trusted."""
        from agent_factory import _resolve_browser_model
        with (
            patch("agent_factory._is_ollama_model", return_value=True),
            patch("agent_factory._ollama_installed_models", return_value=[
                "granite4:latest", "llama3:8b",
            ]),
        ):
            assert _resolve_browser_model("granite4:latest") == "granite4:latest", (
                "Unknown-size model should not be overridden — "
                "the user's selection must be respected"
            )

    def test_known_small_model_is_overridden(self):
        """A model known to be below the minimum gets replaced."""
        from agent_factory import _resolve_browser_model
        with (
            patch("agent_factory._is_ollama_model", return_value=True),
            patch("agent_factory._ollama_installed_models", return_value=[
                "tiny:350m", "llama3:8b",
            ]),
        ):
            result = _resolve_browser_model("tiny:350m")
            assert result == "llama3:8b", (
                f"Expected 'llama3:8b' but got {result!r} — "
                "known-small model should be replaced with a larger one"
            )

    def test_known_small_model_no_large_available_falls_back_to_groq(self):
        """If no large local model exists but Groq key is present, use Groq default."""
        from agent_factory import _resolve_browser_model, DEFAULT_MODEL
        with (
            patch("agent_factory._is_ollama_model", return_value=True),
            patch("agent_factory._ollama_installed_models", return_value=["tiny:350m"]),
            patch("agent_factory._get_groq_api_key", return_value="gsk_fake"),
        ):
            assert _resolve_browser_model("tiny:350m") == DEFAULT_MODEL


class TestGroqKeyDiscovery:
    """Verify the Groq API key is discovered from multiple sources."""

    def test_env_var_takes_priority(self):
        """GROQ_API_KEY env var should be used before any file."""
        from agent_factory import _get_groq_api_key
        with patch.dict("os.environ", {"GROQ_API_KEY": "gsk_from_env"}):
            assert _get_groq_api_key() == "gsk_from_env"

    def test_home_file_used_when_no_env(self):
        """~/.groq is read when GROQ_API_KEY is not set."""
        from agent_factory import _get_groq_api_key
        with (
            patch.dict("os.environ", {}, clear=True),
            patch("agent_factory._read_key_file") as mock_read,
        ):
            mock_read.return_value = "gsk_from_file"
            assert _get_groq_api_key() == "gsk_from_file"

    def test_sudo_user_fallback(self):
        """When ~/.groq is missing but SUDO_USER is set, try that user's home."""
        from agent_factory import _get_groq_api_key
        call_results = {0: None, 1: "gsk_sudo_user"}
        call_count = {"n": 0}

        def side_effect(_path):
            idx = call_count["n"]
            call_count["n"] += 1
            return call_results.get(idx)

        with (
            patch.dict("os.environ", {"SUDO_USER": "george"}, clear=True),
            patch("agent_factory._read_key_file", side_effect=side_effect),
        ):
            assert _get_groq_api_key() == "gsk_sudo_user"


    def test_key_reread_every_call(self):
        """Key must be re-read from disk, never served from stale cache."""
        from agent_factory import _get_groq_api_key
        with (
            patch.dict("os.environ", {}, clear=True),
            patch("agent_factory._read_key_file") as mock_read,
        ):
            mock_read.return_value = None
            assert _get_groq_api_key() is None

            mock_read.return_value = "gsk_appeared_later"
            assert _get_groq_api_key() == "gsk_appeared_later", (
                "Key should be re-read from disk, not returned from stale cache"
            )

    def test_home_scan_fallback(self):
        """When env, ~/,  and SUDO_USER all miss, scan /home/*/.groq."""
        from agent_factory import _get_groq_api_key

        fake_george = MagicMock(spec=Path)
        fake_george.is_dir.return_value = True
        fake_george.__truediv__ = lambda self, name: Path("/home/george/.groq")

        def read_side_effect(path):
            if str(path) == "/home/george/.groq":
                return "gsk_scanned"
            return None

        with (
            patch.dict("os.environ", {}, clear=True),
            patch("agent_factory._read_key_file", side_effect=read_side_effect),
            patch("agent_factory.Path") as MockPath,
        ):
            MockPath.home.return_value = Path("/root")
            MockPath.return_value.__truediv__ = Path.__truediv__
            mock_home_dir = MagicMock()
            mock_home_dir.iterdir.return_value = [fake_george]
            MockPath.__call__ = lambda self, p: mock_home_dir if p == "/home" else Path(p)
            MockPath.side_effect = lambda p: mock_home_dir if p == "/home" else Path(p)

            result = _get_groq_api_key()
            assert result == "gsk_scanned", (
                f"Expected key from /home scan but got {result!r}"
            )

    def test_none_when_all_sources_exhausted(self):
        """Returns None when no env var, no file, no /home scan."""
        from agent_factory import _get_groq_api_key
        with (
            patch.dict("os.environ", {}, clear=True),
            patch("agent_factory._read_key_file", return_value=None),
            patch("agent_factory.Path") as MockPath,
        ):
            MockPath.home.return_value = Path("/root")
            mock_home_dir = MagicMock()
            mock_home_dir.iterdir.return_value = []
            MockPath.side_effect = lambda p: mock_home_dir if p == "/home" else Path(p)
            assert _get_groq_api_key() is None


class TestBrowserUseKeyDiscovery:
    """Verify the Browser Use Cloud API key is discovered from ~/.browser_use."""

    def test_home_file(self):
        """~/.browser_use is read first."""
        from agent_factory import _get_browser_use_api_key
        with patch("agent_factory._read_key_file") as mock_read:
            mock_read.return_value = "bu_from_file"
            assert _get_browser_use_api_key() == "bu_from_file"

    def test_sudo_user_fallback(self):
        """When ~/.browser_use is missing but SUDO_USER is set, try that user's home."""
        from agent_factory import _get_browser_use_api_key
        call_results = {0: None, 1: "bu_sudo_user"}
        call_count = {"n": 0}

        def side_effect(_path):
            idx = call_count["n"]
            call_count["n"] += 1
            return call_results.get(idx)

        with (
            patch.dict("os.environ", {"SUDO_USER": "george"}, clear=True),
            patch("agent_factory._read_key_file", side_effect=side_effect),
        ):
            assert _get_browser_use_api_key() == "bu_sudo_user"

    def test_none_when_no_file(self):
        """Returns None when no ~/.browser_use found anywhere."""
        from agent_factory import _get_browser_use_api_key
        with (
            patch.dict("os.environ", {}, clear=True),
            patch("agent_factory._read_key_file", return_value=None),
            patch("agent_factory.Path") as MockPath,
        ):
            MockPath.home.return_value = Path("/root")
            mock_home_dir = MagicMock()
            mock_home_dir.iterdir.return_value = []
            MockPath.side_effect = lambda p: mock_home_dir if p == "/home" else Path(p)
            assert _get_browser_use_api_key() is None


class TestIsChatCapable:
    """Verify the embedding model filter."""

    def test_embed_model_rejected(self):
        from agent_factory import _is_chat_capable
        assert not _is_chat_capable("nomic-embed-text:latest")
        assert not _is_chat_capable("mxbai-embed-large:latest")

    def test_chat_model_accepted(self):
        from agent_factory import _is_chat_capable
        assert _is_chat_capable("llama3:latest")
        assert _is_chat_capable("openai/gpt-oss-20b")
        assert _is_chat_capable("qwen3:8b")


def test_proto_serialization():
    """Test basic bridge_pb2 message instantiation"""
    req = bridge_pb2.AgentRequest(
        prompt="Test",
        model="llama3",
        images=[],
        context=[1, 2, 3]
    )
    assert req.prompt == "Test"
    assert req.model == "llama3"
    assert req.context == [1, 2, 3]

    res = bridge_pb2.AgentResponse(
        content="Response",
        done=True,
        status="Success"
    )
    assert res.content == "Response"
    assert res.done is True
