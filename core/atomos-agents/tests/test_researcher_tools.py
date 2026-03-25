"""
Tests for the researcher tools (tools/researcher.py).

Covers:
  - Tool registration and discovery via get_researcher_tools()
  - Tool names, descriptions, and argument schemas
  - Handler invocation round-trip (mock GPTResearcher)
  - API key checking and injection
  - Error handling when gpt-researcher is unavailable
  - Getter tools handle missing session gracefully
  - Integration with tool_registry allowed-tools list
"""

import asyncio
import json
import os
import sys
import types as builtin_types
from unittest.mock import AsyncMock, MagicMock, patch

import pytest


# ── helpers ────────────────────────────────────────────────────────────────


def _install_fake_gpt_researcher():
    """Inject a fake gpt_researcher package into sys.modules."""
    pkg = builtin_types.ModuleType("gpt_researcher")

    mock_researcher_cls = MagicMock()
    mock_instance = MagicMock()
    mock_instance.conduct_research = AsyncMock(return_value=None)
    mock_instance.write_report = AsyncMock(return_value="# Report\n\nFindings here.")
    mock_instance.get_source_urls = MagicMock(return_value=[
        "https://example.com/a",
        "https://example.com/b",
    ])
    mock_instance.get_research_context = MagicMock(return_value="Context data")
    mock_instance.get_costs = MagicMock(return_value=0.042)
    mock_instance.get_research_images = MagicMock(return_value=[])
    mock_instance.get_research_sources = MagicMock(return_value=[])
    mock_researcher_cls.return_value = mock_instance

    pkg.GPTResearcher = mock_researcher_cls
    sys.modules["gpt_researcher"] = pkg
    return pkg, mock_researcher_cls, mock_instance


def _uninstall_fake_gpt_researcher():
    sys.modules.pop("gpt_researcher", None)


@pytest.fixture(autouse=True)
def _reset_module_state():
    """Reset the researcher module's cached state between tests."""
    yield
    try:
        import tools.researcher as mod
        mod._RESEARCHER_TOOLS = None
        mod._last_researcher = None
    except ImportError:
        pass


@pytest.fixture(autouse=True)
def _fake_api_keys(monkeypatch):
    """Ensure API key checks pass by default."""
    monkeypatch.setenv("OPENAI_API_KEY", "test-openai-key")
    monkeypatch.setenv("TAVILY_API_KEY", "test-tavily-key")


# ── tool registration ─────────────────────────────────────────────────────


class TestResearcherToolRegistration:

    def test_get_researcher_tools_returns_four_tools(self):
        _install_fake_gpt_researcher()
        try:
            import tools.researcher as mod
            mod._RESEARCHER_TOOLS = None
            result = mod.get_researcher_tools()
            assert len(result) == 4
        finally:
            _uninstall_fake_gpt_researcher()

    def test_tool_names_are_namespaced(self):
        _install_fake_gpt_researcher()
        try:
            import tools.researcher as mod
            mod._RESEARCHER_TOOLS = None
            result = mod.get_researcher_tools()
            names = {t.name for t in result}
            assert names == {
                "researcher_research",
                "researcher_get_sources",
                "researcher_get_context",
                "researcher_get_costs",
            }
        finally:
            _uninstall_fake_gpt_researcher()

    def test_research_tool_has_query_arg(self):
        from tools.researcher import researcher_research
        schema = researcher_research.args_schema
        if schema:
            assert "query" in schema.model_fields

    def test_research_tool_has_report_type_arg(self):
        from tools.researcher import researcher_research
        schema = researcher_research.args_schema
        if schema:
            assert "report_type" in schema.model_fields

    def test_graceful_when_package_missing(self):
        _uninstall_fake_gpt_researcher()
        import tools.researcher as mod
        mod._RESEARCHER_TOOLS = None
        result = mod.get_researcher_tools()
        assert result == []


# ── API key checks ────────────────────────────────────────────────────────


class TestApiKeyChecks:

    def test_check_api_keys_passes_with_env_vars(self, monkeypatch):
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
        monkeypatch.setenv("TAVILY_API_KEY", "tvly-test")
        from tools.researcher import _check_api_keys
        assert _check_api_keys() is None

    def test_check_api_keys_reports_missing_openai(self, monkeypatch):
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        monkeypatch.setenv("TAVILY_API_KEY", "tvly-test")
        from tools.researcher import _check_api_keys
        with patch("tools.researcher._resolve_api_key", side_effect=lambda e, d: (
            "tvly-test" if e == "TAVILY_API_KEY" else None
        )):
            result = _check_api_keys()
            assert result is not None
            assert "OPENAI_API_KEY" in result

    def test_check_api_keys_reports_missing_tavily(self, monkeypatch):
        monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
        monkeypatch.delenv("TAVILY_API_KEY", raising=False)
        from tools.researcher import _check_api_keys
        with patch("tools.researcher._resolve_api_key", side_effect=lambda e, d: (
            "sk-test" if e == "OPENAI_API_KEY" else None
        )):
            result = _check_api_keys()
            assert result is not None
            assert "TAVILY_API_KEY" in result

    def test_inject_api_keys_sets_env(self, monkeypatch):
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        monkeypatch.delenv("TAVILY_API_KEY", raising=False)
        from tools.researcher import _inject_api_keys
        with patch("tools.researcher._resolve_api_key", return_value="resolved-key"):
            _inject_api_keys()
            assert os.environ.get("OPENAI_API_KEY") == "resolved-key"
            assert os.environ.get("TAVILY_API_KEY") == "resolved-key"


# ── researcher_research invocation ────────────────────────────────────────


class TestResearcherResearch:

    def test_research_returns_report(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        instance.write_report = AsyncMock(return_value="# Deep Research\n\nKey findings.")
        try:
            from tools.researcher import researcher_research
            result = asyncio.run(
                researcher_research.coroutine(query="quantum computing advances")
            )
            assert "Deep Research" in result
            assert "Key findings" in result
        finally:
            _uninstall_fake_gpt_researcher()

    def test_research_passes_parameters(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        try:
            from tools.researcher import researcher_research
            asyncio.run(researcher_research.coroutine(
                query="AI safety",
                report_type="resource_report",
                report_format="MLA",
                tone="formal",
                max_subtopics=5,
                verbose=True,
            ))
            cls.assert_called_once()
            call_kwargs = cls.call_args[1]
            assert call_kwargs["query"] == "AI safety"
            assert call_kwargs["report_type"] == "resource_report"
            assert call_kwargs["report_format"] == "MLA"
            assert call_kwargs["tone"] == "formal"
            assert call_kwargs["max_subtopics"] == 5
            assert call_kwargs["verbose"] is True
        finally:
            _uninstall_fake_gpt_researcher()

    def test_research_omits_none_tone(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        try:
            from tools.researcher import researcher_research
            asyncio.run(researcher_research.coroutine(query="test query"))
            call_kwargs = cls.call_args[1]
            assert "tone" not in call_kwargs
        finally:
            _uninstall_fake_gpt_researcher()

    def test_research_rejects_invalid_report_type(self):
        _install_fake_gpt_researcher()
        try:
            from tools.researcher import researcher_research
            result = asyncio.run(
                researcher_research.coroutine(query="test", report_type="invalid_type")
            )
            assert "Invalid report_type" in result
        finally:
            _uninstall_fake_gpt_researcher()

    def test_research_empty_report_returns_placeholder(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        instance.write_report = AsyncMock(return_value="")
        try:
            from tools.researcher import researcher_research
            result = asyncio.run(
                researcher_research.coroutine(query="obscure topic")
            )
            assert "(research completed but no report was generated)" in result
        finally:
            _uninstall_fake_gpt_researcher()

    def test_research_returns_error_without_api_keys(self, monkeypatch):
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        monkeypatch.delenv("TAVILY_API_KEY", raising=False)
        _install_fake_gpt_researcher()
        try:
            from tools.researcher import researcher_research
            with patch("tools.researcher._resolve_api_key", return_value=None):
                result = asyncio.run(
                    researcher_research.coroutine(query="test")
                )
                assert "Missing API keys" in result
        finally:
            _uninstall_fake_gpt_researcher()

    def test_research_stores_last_researcher(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        try:
            import tools.researcher as mod
            from tools.researcher import researcher_research
            mod._last_researcher = None
            asyncio.run(researcher_research.coroutine(query="test"))
            assert mod._last_researcher is instance
        finally:
            _uninstall_fake_gpt_researcher()


# ── getter tools ──────────────────────────────────────────────────────────


class TestResearcherGetSources:

    def test_get_sources_returns_urls(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        try:
            import tools.researcher as mod
            from tools.researcher import researcher_research, researcher_get_sources
            asyncio.run(researcher_research.coroutine(query="test"))
            result = asyncio.run(researcher_get_sources.coroutine())
            parsed = json.loads(result)
            assert "https://example.com/a" in parsed
            assert "https://example.com/b" in parsed
        finally:
            _uninstall_fake_gpt_researcher()

    def test_get_sources_no_session(self):
        import tools.researcher as mod
        from tools.researcher import researcher_get_sources
        mod._last_researcher = None
        result = asyncio.run(researcher_get_sources.coroutine())
        assert "no research session" in result

    def test_get_sources_empty(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        instance.get_source_urls = MagicMock(return_value=[])
        try:
            import tools.researcher as mod
            from tools.researcher import researcher_research, researcher_get_sources
            asyncio.run(researcher_research.coroutine(query="test"))
            result = asyncio.run(researcher_get_sources.coroutine())
            assert "(no sources recorded)" in result
        finally:
            _uninstall_fake_gpt_researcher()


class TestResearcherGetContext:

    def test_get_context_returns_data(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        try:
            import tools.researcher as mod
            from tools.researcher import researcher_research, researcher_get_context
            asyncio.run(researcher_research.coroutine(query="test"))
            result = asyncio.run(researcher_get_context.coroutine())
            assert "Context data" in result
        finally:
            _uninstall_fake_gpt_researcher()

    def test_get_context_no_session(self):
        import tools.researcher as mod
        from tools.researcher import researcher_get_context
        mod._last_researcher = None
        result = asyncio.run(researcher_get_context.coroutine())
        assert "no research session" in result

    def test_get_context_handles_dict(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        instance.get_research_context = MagicMock(
            return_value={"sources": [{"url": "https://example.com", "content": "data"}]}
        )
        try:
            from tools.researcher import researcher_research, researcher_get_context
            asyncio.run(researcher_research.coroutine(query="test"))
            result = asyncio.run(researcher_get_context.coroutine())
            parsed = json.loads(result)
            assert "sources" in parsed
        finally:
            _uninstall_fake_gpt_researcher()

    def test_get_context_empty(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        instance.get_research_context = MagicMock(return_value=None)
        try:
            from tools.researcher import researcher_research, researcher_get_context
            asyncio.run(researcher_research.coroutine(query="test"))
            result = asyncio.run(researcher_get_context.coroutine())
            assert "(no research context available)" in result
        finally:
            _uninstall_fake_gpt_researcher()


class TestResearcherGetCosts:

    def test_get_costs_returns_data(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        try:
            from tools.researcher import researcher_research, researcher_get_costs
            asyncio.run(researcher_research.coroutine(query="test"))
            result = asyncio.run(researcher_get_costs.coroutine())
            parsed = json.loads(result)
            assert parsed["total_costs"] == 0.042
        finally:
            _uninstall_fake_gpt_researcher()

    def test_get_costs_no_session(self):
        import tools.researcher as mod
        from tools.researcher import researcher_get_costs
        mod._last_researcher = None
        result = asyncio.run(researcher_get_costs.coroutine())
        assert "no research session" in result

    def test_get_costs_none_value(self):
        pkg, cls, instance = _install_fake_gpt_researcher()
        instance.get_costs = MagicMock(return_value=None)
        try:
            from tools.researcher import researcher_research, researcher_get_costs
            asyncio.run(researcher_research.coroutine(query="test"))
            result = asyncio.run(researcher_get_costs.coroutine())
            assert "(cost data unavailable)" in result
        finally:
            _uninstall_fake_gpt_researcher()


# ── tool_registry integration ─────────────────────────────────────────────


class TestRegistryIntegration:

    def test_researcher_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS
        assert "researcher_research" in _ALLOWED_EXPOSED_TOOLS
        assert "researcher_get_sources" in _ALLOWED_EXPOSED_TOOLS
        assert "researcher_get_context" in _ALLOWED_EXPOSED_TOOLS
        assert "researcher_get_costs" in _ALLOWED_EXPOSED_TOOLS
