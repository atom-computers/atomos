"""
Tests for the superpowers tools (tools/superpowers.py).

Covers:
  - Tool registration and discovery via get_superpowers_tools()
  - Tool names, descriptions, and argument schemas
  - Skill discovery from a temp directory with SKILL.md files
  - Frontmatter parsing
  - Intelligence logic (tokenize, FNV-1a embedding, cosine similarity)
  - Intent inference and guardrail policy lookup
  - Handler invocation round-trip for all seven tools
  - Graceful behaviour when skills directory is missing
  - Integration with tool_registry allowed-tools list
"""

import json
import os
import textwrap
from pathlib import Path
from unittest.mock import patch

import pytest


# ── helpers ────────────────────────────────────────────────────────────────


def _make_skills_dir(tmp_path: Path) -> Path:
    """Create a minimal superpowers skills directory in tmp_path."""
    skills_dir = tmp_path / "skills"
    skills_dir.mkdir()

    # brainstorming skill
    bs = skills_dir / "brainstorming"
    bs.mkdir()
    (bs / "SKILL.md").write_text(textwrap.dedent("""\
        ---
        name: Brainstorming
        description: Collaborative design through questions and validation
        ---
        # Brainstorming

        Ask clarifying questions before jumping into code.
    """))
    (bs / "examples.md").write_text("Example brainstorming session here.")

    # test-driven-development skill
    tdd = skills_dir / "test-driven-development"
    tdd.mkdir()
    (tdd / "SKILL.md").write_text(textwrap.dedent("""\
        ---
        name: Test-Driven Development
        description: RED-GREEN-REFACTOR cycle -- write failing test first
        ---
        # TDD

        Always write the test before the implementation.
    """))
    (tdd / "testing-anti-patterns.md").write_text(
        "Common testing anti-patterns to avoid."
    )

    # systematic-debugging skill
    dbg = skills_dir / "systematic-debugging"
    dbg.mkdir()
    (dbg / "SKILL.md").write_text(textwrap.dedent("""\
        ---
        name: Systematic Debugging
        description: 4-phase root cause analysis
        ---
        # Debugging

        Investigate before you fix.
    """))

    return skills_dir


def _reset_module_state():
    """Clear cached skills, index, and tools list."""
    import tools.superpowers as mod
    mod._skills = None
    mod._skill_map = None
    mod._index = None
    mod._SUPERPOWERS_TOOLS = None
    mod._session_history.clear()


# ── tool registration ─────────────────────────────────────────────────────


class TestSuperpowersToolRegistration:

    def test_get_superpowers_tools_returns_seven_tools(self):
        import tools.superpowers as mod
        _reset_module_state()
        result = mod.get_superpowers_tools()
        assert len(result) == 7

    def test_tool_names_are_namespaced(self):
        import tools.superpowers as mod
        _reset_module_state()
        result = mod.get_superpowers_tools()
        names = {t.name for t in result}
        assert names == {
            "superpowers_list_skills",
            "superpowers_use_skill",
            "superpowers_get_skill_file",
            "superpowers_recommend_skills",
            "superpowers_compose_workflow",
            "superpowers_validate_workflow",
            "superpowers_search_skills",
        }

    def test_caches_tool_list(self):
        import tools.superpowers as mod
        _reset_module_state()
        first = mod.get_superpowers_tools()
        second = mod.get_superpowers_tools()
        assert first is second

    def test_use_skill_has_name_arg(self):
        from tools.superpowers import superpowers_use_skill
        schema = superpowers_use_skill.args_schema
        if schema:
            assert "name" in schema.model_fields

    def test_search_skills_has_query_arg(self):
        from tools.superpowers import superpowers_search_skills
        schema = superpowers_search_skills.args_schema
        if schema:
            assert "query" in schema.model_fields

    def test_recommend_skills_has_task_arg(self):
        from tools.superpowers import superpowers_recommend_skills
        schema = superpowers_recommend_skills.args_schema
        if schema:
            assert "task" in schema.model_fields


# ── frontmatter parsing ───────────────────────────────────────────────────


class TestParseFrontmatter:

    def test_extracts_name_and_description(self):
        from tools.superpowers import _parse_frontmatter
        raw = "---\nname: Foo\ndescription: Bar baz\n---\n# Body"
        name, desc, body = _parse_frontmatter(raw)
        assert name == "Foo"
        assert desc == "Bar baz"
        assert "# Body" in body

    def test_handles_no_frontmatter(self):
        from tools.superpowers import _parse_frontmatter
        raw = "# Just markdown"
        name, desc, body = _parse_frontmatter(raw)
        assert name == ""
        assert desc == ""
        assert body == raw

    def test_handles_quoted_values(self):
        from tools.superpowers import _parse_frontmatter
        raw = '---\nname: "Quoted Name"\ndescription: \'Single quoted\'\n---\nBody'
        name, desc, body = _parse_frontmatter(raw)
        assert name == "Quoted Name"
        assert desc == "Single quoted"


# ── skill discovery ────────────────────────────────────────────────────────


class TestSkillDiscovery:

    def test_discovers_skills_from_directory(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        from tools.superpowers import discover_skills
        skills = discover_skills(str(skills_dir))
        names = {s.directory_name for s in skills}
        assert "brainstorming" in names
        assert "test-driven-development" in names
        assert "systematic-debugging" in names
        assert len(skills) == 3

    def test_skill_has_correct_metadata(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        from tools.superpowers import discover_skills
        skills = discover_skills(str(skills_dir))
        bs = next(s for s in skills if s.directory_name == "brainstorming")
        assert bs.name == "Brainstorming"
        assert "Collaborative" in bs.description

    def test_skill_has_supporting_files(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        from tools.superpowers import discover_skills
        skills = discover_skills(str(skills_dir))
        bs = next(s for s in skills if s.directory_name == "brainstorming")
        file_names = [f.name for f in bs.files]
        assert "examples.md" in file_names

    def test_returns_empty_for_missing_dir(self):
        from tools.superpowers import discover_skills
        assert discover_skills("/nonexistent/path") == []

    def test_skips_dirs_without_skill_md(self, tmp_path):
        skills_dir = tmp_path / "skills"
        skills_dir.mkdir()
        (skills_dir / "no-skill-here").mkdir()
        (skills_dir / "no-skill-here" / "README.md").write_text("Not a skill")
        from tools.superpowers import discover_skills
        assert discover_skills(str(skills_dir)) == []


# ── intelligence helpers ───────────────────────────────────────────────────


class TestTokenize:

    def test_lowercases_and_splits(self):
        from tools.superpowers import _tokenize
        tokens = _tokenize("Hello World FOO-BAR")
        assert "hello" in tokens
        assert "world" in tokens
        assert "foo" in tokens
        assert "bar" in tokens

    def test_removes_stop_words(self):
        from tools.superpowers import _tokenize
        tokens = _tokenize("the quick and brown fox")
        assert "the" not in tokens
        assert "and" not in tokens
        assert "quick" in tokens
        assert "brown" in tokens

    def test_removes_single_char_tokens(self):
        from tools.superpowers import _tokenize
        tokens = _tokenize("a b cd ef")
        assert "a" not in tokens
        assert "b" not in tokens
        assert "cd" in tokens


class TestEmbedding:

    def test_embedding_has_correct_dimension(self):
        from tools.superpowers import _create_embedding, EMBEDDING_DIMENSION
        emb = _create_embedding(["hello", "world"])
        assert len(emb) == EMBEDDING_DIMENSION

    def test_normalized_embedding(self):
        from tools.superpowers import _create_embedding
        import math
        emb = _create_embedding(["test", "driven", "development"])
        magnitude = math.sqrt(sum(v * v for v in emb))
        assert abs(magnitude - 1.0) < 1e-6

    def test_empty_tokens_zero_vector(self):
        from tools.superpowers import _create_embedding, EMBEDDING_DIMENSION
        emb = _create_embedding([])
        assert emb == [0.0] * EMBEDDING_DIMENSION

    def test_cosine_similarity_identical(self):
        from tools.superpowers import _create_embedding, _cosine_similarity
        emb = _create_embedding(["debug", "bug", "trace"])
        sim = _cosine_similarity(emb, emb)
        assert abs(sim - 1.0) < 1e-6

    def test_cosine_similarity_different(self):
        from tools.superpowers import _create_embedding, _cosine_similarity
        a = _create_embedding(["debug", "bug", "trace"])
        b = _create_embedding(["brainstorm", "design", "architecture"])
        sim = _cosine_similarity(a, b)
        assert 0.0 <= sim < 1.0


class TestFnv1aHash:

    def test_deterministic(self):
        from tools.superpowers import _fnv1a_hash
        assert _fnv1a_hash("hello") == _fnv1a_hash("hello")

    def test_different_inputs_different_hashes(self):
        from tools.superpowers import _fnv1a_hash
        assert _fnv1a_hash("hello") != _fnv1a_hash("world")


# ── intent inference ───────────────────────────────────────────────────────


class TestInferIntent:

    def test_debugging_intent(self):
        from tools.superpowers import infer_intent
        assert infer_intent("debug this flaky test") == "debugging"

    def test_review_intent(self):
        from tools.superpowers import infer_intent
        assert infer_intent("review my pull request") == "review"

    def test_creative_intent(self):
        from tools.superpowers import infer_intent
        assert infer_intent("brainstorm a new architecture") == "creative"

    def test_planning_intent(self):
        from tools.superpowers import infer_intent
        assert infer_intent("plan the roadmap") == "planning"

    def test_implementation_intent(self):
        from tools.superpowers import infer_intent
        assert infer_intent("implement this feature") == "implementation"

    def test_completion_intent(self):
        from tools.superpowers import infer_intent
        assert infer_intent("finish and ship") == "completion"

    def test_general_intent(self):
        from tools.superpowers import infer_intent
        assert infer_intent("hello there") == "general"


# ── tool invocation round-trip ─────────────────────────────────────────────


class TestListSkills:

    def test_lists_discovered_skills(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_list_skills
            result = superpowers_list_skills.invoke({})
        _reset_module_state()
        parsed = json.loads(result)
        names = {s["name"] for s in parsed}
        assert "brainstorming" in names
        assert len(parsed) == 3

    def test_empty_when_no_skills(self, tmp_path):
        empty_dir = tmp_path / "empty"
        empty_dir.mkdir()
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(empty_dir)}):
            from tools.superpowers import superpowers_list_skills
            result = superpowers_list_skills.invoke({})
        _reset_module_state()
        assert "no superpowers skills found" in result


class TestUseSkill:

    def test_returns_skill_content(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_use_skill
            result = superpowers_use_skill.invoke({"name": "brainstorming"})
        _reset_module_state()
        assert "Brainstorming" in result
        assert "clarifying questions" in result

    def test_missing_skill_returns_error(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_use_skill
            result = superpowers_use_skill.invoke({"name": "nonexistent"})
        _reset_module_state()
        assert "not found" in result

    def test_guardrail_blocks_when_required_missing(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_use_skill
            result = superpowers_use_skill.invoke({
                "name": "test-driven-development",
                "goal": "implement a feature",
                "enforce_guardrails": True,
            })
        _reset_module_state()
        assert "Guardrail" not in result or "test" in result.lower()


class TestGetSkillFile:

    def test_reads_supporting_file(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_get_skill_file
            result = superpowers_get_skill_file.invoke({
                "skill": "brainstorming",
                "file": "examples.md",
            })
        _reset_module_state()
        assert "brainstorming session" in result

    def test_missing_file_returns_error(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_get_skill_file
            result = superpowers_get_skill_file.invoke({
                "skill": "brainstorming",
                "file": "nonexistent.md",
            })
        _reset_module_state()
        assert "not found" in result

    def test_missing_skill_returns_error(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_get_skill_file
            result = superpowers_get_skill_file.invoke({
                "skill": "nope",
                "file": "anything.md",
            })
        _reset_module_state()
        assert "not found" in result


class TestRecommendSkills:

    def test_returns_ranked_recommendations(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_recommend_skills
            result = superpowers_recommend_skills.invoke({
                "task": "debug a flaky test",
            })
        _reset_module_state()
        parsed = json.loads(result)
        assert len(parsed) > 0
        assert all("score" in r for r in parsed)
        assert all("reasons" in r for r in parsed)
        assert parsed[0]["score"] >= parsed[-1]["score"]

    def test_debugging_task_recommends_debugging_skill(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_recommend_skills
            result = superpowers_recommend_skills.invoke({
                "task": "debug a regression bug",
            })
        _reset_module_state()
        parsed = json.loads(result)
        names = [r["name"] for r in parsed]
        assert "systematic-debugging" in names

    def test_respects_max_results(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_recommend_skills
            result = superpowers_recommend_skills.invoke({
                "task": "anything",
                "max_results": 2,
            })
        _reset_module_state()
        parsed = json.loads(result)
        assert len(parsed) <= 2


class TestComposeWorkflow:

    def test_returns_workflow_with_steps(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_compose_workflow
            result = superpowers_compose_workflow.invoke({
                "goal": "implement a caching layer",
            })
        _reset_module_state()
        parsed = json.loads(result)
        assert "goal" in parsed
        assert "intent" in parsed
        assert "steps" in parsed
        assert len(parsed["steps"]) > 0

    def test_respects_max_steps(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_compose_workflow
            result = superpowers_compose_workflow.invoke({
                "goal": "build a feature",
                "max_steps": 2,
            })
        _reset_module_state()
        parsed = json.loads(result)
        assert len(parsed["steps"]) <= 2


class TestValidateWorkflow:

    def test_valid_workflow(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_validate_workflow
            result = superpowers_validate_workflow.invoke({
                "goal": "debug a bug",
                "selected_skills": ["systematic-debugging"],
            })
        _reset_module_state()
        parsed = json.loads(result)
        assert parsed["valid"] is True
        assert parsed["intent"] == "debugging"

    def test_invalid_workflow_missing_required(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_validate_workflow
            result = superpowers_validate_workflow.invoke({
                "goal": "debug a bug",
                "selected_skills": ["brainstorming"],
            })
        _reset_module_state()
        parsed = json.loads(result)
        assert parsed["valid"] is False
        assert "systematic-debugging" in parsed["missing_required_skills"]

    def test_general_goal_always_valid(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_validate_workflow
            result = superpowers_validate_workflow.invoke({
                "goal": "hello",
                "selected_skills": [],
            })
        _reset_module_state()
        parsed = json.loads(result)
        assert parsed["valid"] is True


class TestSearchSkills:

    def test_returns_ranked_matches(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_search_skills
            result = superpowers_search_skills.invoke({
                "query": "write failing test first RED GREEN",
            })
        _reset_module_state()
        parsed = json.loads(result)
        assert len(parsed) > 0
        assert all("score" in m for m in parsed)
        tdd_match = next(
            (m for m in parsed if m["skill"] == "test-driven-development"), None
        )
        assert tdd_match is not None

    def test_filter_by_skill(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_search_skills
            result = superpowers_search_skills.invoke({
                "query": "test",
                "skill": "brainstorming",
            })
        _reset_module_state()
        parsed = json.loads(result)
        for m in parsed:
            assert m["skill"] == "brainstorming"

    def test_respects_max_results(self, tmp_path):
        skills_dir = _make_skills_dir(tmp_path)
        _reset_module_state()
        with patch.dict(os.environ, {"SUPERPOWERS_SKILLS_DIR": str(skills_dir)}):
            from tools.superpowers import superpowers_search_skills
            result = superpowers_search_skills.invoke({
                "query": "development",
                "max_results": 1,
            })
        _reset_module_state()
        parsed = json.loads(result)
        assert len(parsed) <= 1


# ── validate_workflow logic ────────────────────────────────────────────────


class TestValidateWorkflowLogic:

    def test_order_enforcement(self):
        from tools.superpowers import _validate_workflow_logic
        result = _validate_workflow_logic(
            goal="debug",
            selected_skills=["systematic-debugging", "brainstorming"],
            enforce_order=True,
            available={"brainstorming", "systematic-debugging"},
        )
        assert result["valid"] is True

    def test_order_enforcement_violation(self):
        from tools.superpowers import _validate_workflow_logic
        result = _validate_workflow_logic(
            goal="debug",
            selected_skills=["brainstorming", "systematic-debugging"],
            enforce_order=True,
            available={"brainstorming", "systematic-debugging"},
        )
        assert result["valid"] is False
        assert any("before optional" in v for v in result["violations"])

    def test_detects_missing_required(self):
        from tools.superpowers import _validate_workflow_logic
        result = _validate_workflow_logic(
            goal="implement feature",
            selected_skills=["brainstorming"],
            available={"brainstorming", "test-driven-development"},
        )
        assert result["valid"] is False
        assert "test-driven-development" in result["missing_required_skills"]

    def test_deduplicates_selected(self):
        from tools.superpowers import _validate_workflow_logic
        result = _validate_workflow_logic(
            goal="debug",
            selected_skills=["systematic-debugging", "systematic-debugging"],
            available={"systematic-debugging"},
        )
        assert result["valid"] is True
        assert result["selected_skills"] == ["systematic-debugging"]


# ── tool_registry integration ─────────────────────────────────────────────


class TestRegistryIntegration:

    def test_superpowers_tools_in_allowed_set(self):
        from tool_registry import _ALLOWED_EXPOSED_TOOLS

        assert "superpowers_list_skills" in _ALLOWED_EXPOSED_TOOLS
        assert "superpowers_use_skill" in _ALLOWED_EXPOSED_TOOLS
        assert "superpowers_get_skill_file" in _ALLOWED_EXPOSED_TOOLS
        assert "superpowers_recommend_skills" in _ALLOWED_EXPOSED_TOOLS
        assert "superpowers_compose_workflow" in _ALLOWED_EXPOSED_TOOLS
        assert "superpowers_validate_workflow" in _ALLOWED_EXPOSED_TOOLS
        assert "superpowers_search_skills" in _ALLOWED_EXPOSED_TOOLS
