"""Superpowers workflow skills for atomos-agents.

Vendors the `superpowers` skills library (obra/superpowers) by reading
skill markdown files from a local directory and exposing them as
LangChain tools.  On first use the skills repository is cloned
automatically; alternatively set ``SUPERPOWERS_SKILLS_DIR`` to point at
an existing checkout.

The seven tools mirror the MCP server (erophames/superpowers-mcp):

  superpowers_list_skills       — catalogue every available skill
  superpowers_use_skill         — load a skill's full content
  superpowers_get_skill_file    — read a supporting file from a skill
  superpowers_recommend_skills  — rank skills for a task
  superpowers_compose_workflow  — build an ordered multi-skill plan
  superpowers_validate_workflow — check guardrail compliance
  superpowers_search_skills     — semantic search across skill content

Intelligence logic (tokenisation, FNV-1a hashing, cosine similarity,
intent inference, guardrail policies) is ported from the TypeScript
reference implementation so results are compatible.
"""

from __future__ import annotations

import json
import logging
import math
import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from langchain_core.tools import tool

logger = logging.getLogger(__name__)

SKILLS_REPO = "https://github.com/obra/superpowers.git"
EMBEDDING_DIMENSION = 256

STOP_WORDS = frozenset({
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
    "has", "have", "in", "is", "it", "its", "of", "on", "or", "that",
    "the", "to", "was", "were", "with", "this", "these", "those",
    "into", "over", "under", "we", "you", "your", "our", "their",
    "before", "after", "then", "than", "when", "what", "which", "how",
    "why",
})

WorkflowIntent = str  # one of the INTENT_POLICIES keys

INTENT_POLICIES: dict[str, dict[str, list[str]]] = {
    "creative":       {"required": ["brainstorming"],
                       "recommended": ["writing-plans"]},
    "planning":       {"required": ["writing-plans"],
                       "recommended": ["test-driven-development"]},
    "implementation": {"required": ["test-driven-development"],
                       "recommended": ["verification-before-completion"]},
    "debugging":      {"required": ["systematic-debugging"],
                       "recommended": ["test-driven-development"]},
    "review":         {"required": ["requesting-code-review"],
                       "recommended": ["receiving-code-review"]},
    "completion":     {"required": ["verification-before-completion"],
                       "recommended": ["finishing-a-development-branch"]},
    "general":        {"required": [], "recommended": []},
}


# ── data types ─────────────────────────────────────────────────────────────


@dataclass
class SkillFile:
    name: str
    relative_path: str


@dataclass
class Skill:
    directory_name: str
    name: str
    description: str
    content: str
    files: list[SkillFile] = field(default_factory=list)


@dataclass
class _IndexedDocument:
    skill: str
    file: str
    source: str
    uri: str
    content: str
    tokens: list[str] = field(default_factory=list)
    token_set: set[str] = field(default_factory=set)
    embedding: list[float] = field(default_factory=list)


@dataclass
class _IndexedSkill:
    name: str
    display_name: str
    description: str
    tokens: list[str] = field(default_factory=list)
    token_set: set[str] = field(default_factory=set)
    embedding: list[float] = field(default_factory=list)


@dataclass
class _SkillIntelligenceIndex:
    documents: list[_IndexedDocument] = field(default_factory=list)
    skills: list[_IndexedSkill] = field(default_factory=list)


# ── text / embedding helpers (ported from intelligence.ts) ─────────────────


def _tokenize(text: str) -> list[str]:
    lowered = text.lower()
    lowered = re.sub(r"[_/.\-]+", " ", lowered)
    tokens = re.split(r"[^a-z0-9]+", lowered)
    return [t for t in tokens if len(t) > 1 and t not in STOP_WORDS]


def _fnv1a_hash(s: str) -> int:
    h = 0x811C9DC5
    for ch in s:
        h ^= ord(ch)
        h = (
            h
            + (h << 1)
            + (h << 4)
            + (h << 7)
            + (h << 8)
            + (h << 24)
        ) & 0xFFFFFFFF
    return h


def _create_embedding(tokens: list[str]) -> list[float]:
    vec = [0.0] * EMBEDDING_DIMENSION
    counts: dict[str, int] = {}
    for t in tokens:
        counts[t] = counts.get(t, 0) + 1
    for token, count in counts.items():
        h = _fnv1a_hash(token)
        idx = h % EMBEDDING_DIMENSION
        sign = 1 if ((h >> 8) & 1) == 0 else -1
        vec[idx] += sign * (1 + math.log(count))
    magnitude = math.sqrt(sum(v * v for v in vec))
    if magnitude == 0:
        return vec
    return [v / magnitude for v in vec]


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    if len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    return max(0.0, dot)


def _keyword_overlap(query_tokens: list[str], target_set: set[str]) -> float:
    if not query_tokens:
        return 0.0
    return sum(1 for t in query_tokens if t in target_set) / len(query_tokens)


def _intersecting_tokens(
    query_tokens: list[str], target_set: set[str], max_terms: int = 4
) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for t in query_tokens:
        if t in target_set and t not in seen:
            out.append(t)
            seen.add(t)
    out.sort(key=len, reverse=True)
    return out[:max_terms]


def _normalize_ws(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def _create_snippet(content: str, query_tokens: list[str]) -> str:
    normalized = _normalize_ws(content)
    if not normalized:
        return ""
    lowered = normalized.lower()
    pivot = 0
    for t in query_tokens:
        idx = lowered.find(t)
        if idx >= 0:
            pivot = idx
            break
    start = max(0, pivot - 80)
    end = min(len(normalized), pivot + 180)
    return normalized[start:end]


# ── intent inference ───────────────────────────────────────────────────────


def _has_any(text: str, keywords: list[str]) -> bool:
    return any(kw in text for kw in keywords)


def infer_intent(text: str) -> WorkflowIntent:
    t = text.lower()
    if _has_any(t, ["debug", "bug", "flaky", "regression", "incident", "failure", "trace"]):
        return "debugging"
    if _has_any(t, ["review", "feedback", "pr ", "pull request", "code review"]):
        return "review"
    if _has_any(t, ["complete", "finish", "ship", "release", "done"]):
        return "completion"
    if _has_any(t, ["design", "brainstorm", "idea", "approach", "architecture"]):
        return "creative"
    if _has_any(t, ["plan", "roadmap", "breakdown", "task list"]):
        return "planning"
    if _has_any(t, ["implement", "build", "feature", "refactor", "write tests", "tdd", "code"]):
        return "implementation"
    return "general"


def _get_intent_policy(
    intent: WorkflowIntent,
    available: set[str] | None = None,
) -> dict[str, list[str]]:
    policy = INTENT_POLICIES.get(intent, INTENT_POLICIES["general"])
    if available is None:
        return policy
    return {
        "required": [s for s in policy["required"] if s in available],
        "recommended": [s for s in policy["recommended"] if s in available],
    }


# ── skill discovery ────────────────────────────────────────────────────────


def _parse_frontmatter(raw: str) -> tuple[str, str, str]:
    """Return (name, description, body) from a SKILL.md with YAML frontmatter."""
    if not raw.startswith("---"):
        return ("", "", raw)
    end = raw.find("---", 3)
    if end == -1:
        return ("", "", raw)
    fm_block = raw[3:end]
    body = raw[end + 3:].lstrip("\n")
    name = ""
    desc = ""
    for line in fm_block.splitlines():
        if line.startswith("name:"):
            name = line[len("name:"):].strip().strip("\"'")
        elif line.startswith("description:"):
            desc = line[len("description:"):].strip().strip("\"'")
    return (name, desc, body)


def _resolve_skills_dir() -> str | None:
    env = os.environ.get("SUPERPOWERS_SKILLS_DIR", "").strip()
    if env and Path(env).is_dir():
        return env

    default = Path.home() / ".superpowers" / "repo" / "skills"
    if default.is_dir():
        return str(default)

    return None


def _clone_skills_repo() -> str | None:
    """Clone the superpowers repo into ~/.superpowers/repo."""
    dest = Path.home() / ".superpowers" / "repo"
    if dest.exists():
        skills = dest / "skills"
        if skills.is_dir():
            return str(skills)
        return None
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            ["git", "clone", "--depth", "1", SKILLS_REPO, str(dest)],
            check=True,
            capture_output=True,
            timeout=120,
        )
        skills = dest / "skills"
        if skills.is_dir():
            logger.info("Cloned superpowers skills to %s", skills)
            return str(skills)
    except Exception as exc:
        logger.warning("Failed to clone superpowers repo: %s", exc)
    return None


def discover_skills(skills_dir: str | None = None) -> list[Skill]:
    """Scan *skills_dir* for skill directories containing SKILL.md."""
    if skills_dir is None:
        skills_dir = _resolve_skills_dir()
    if skills_dir is None:
        skills_dir = _clone_skills_repo()
    if skills_dir is None:
        return []

    root = Path(skills_dir)
    if not root.is_dir():
        return []

    skills: list[Skill] = []
    for entry in sorted(root.iterdir()):
        if not entry.is_dir() or entry.name.startswith("."):
            continue
        skill_md = entry / "SKILL.md"
        if not skill_md.exists():
            continue
        try:
            raw = skill_md.read_text(encoding="utf-8")
        except OSError:
            continue
        name, desc, _body = _parse_frontmatter(raw)
        supporting: list[SkillFile] = []
        for f in sorted(entry.iterdir()):
            if f.name == "SKILL.md" or f.name.startswith("."):
                continue
            if f.is_file():
                supporting.append(SkillFile(
                    name=f.name,
                    relative_path=f"{entry.name}/{f.name}",
                ))
        skills.append(Skill(
            directory_name=entry.name,
            name=name or entry.name,
            description=desc,
            content=raw,
            files=supporting,
        ))
    return skills


# ── intelligence index ─────────────────────────────────────────────────────

_index: _SkillIntelligenceIndex | None = None
_skills: list[Skill] | None = None
_skill_map: dict[str, Skill] | None = None
_session_history: list[str] = []


def _ensure_loaded() -> tuple[list[Skill], dict[str, Skill]]:
    global _skills, _skill_map
    if _skills is not None and _skill_map is not None:
        return _skills, _skill_map
    _skills = discover_skills()
    _skill_map = {s.directory_name: s for s in _skills}
    return _skills, _skill_map


def _ensure_index() -> _SkillIntelligenceIndex:
    global _index
    if _index is not None:
        return _index

    skills, _ = _ensure_loaded()
    skills_dir = _resolve_skills_dir()

    documents: list[_IndexedDocument] = []
    for skill in skills:
        txt = f"{skill.name} {skill.description} {skill.content}"
        toks = _tokenize(txt)
        documents.append(_IndexedDocument(
            skill=skill.directory_name,
            file="SKILL.md",
            source="skill",
            uri=f"superpowers://skills/{skill.directory_name}/SKILL.md",
            content=skill.content,
            tokens=toks,
            token_set=set(toks),
            embedding=_create_embedding(toks),
        ))
        for sf in skill.files:
            file_content = sf.name
            if skills_dir:
                fp = Path(skills_dir) / sf.relative_path
                try:
                    file_content = fp.read_text(encoding="utf-8")
                except OSError:
                    pass
            ftxt = f"{skill.name} {skill.description} {sf.name} {file_content}"
            ftoks = _tokenize(ftxt)
            documents.append(_IndexedDocument(
                skill=skill.directory_name,
                file=sf.name,
                source="supporting-file",
                uri=f"superpowers://skills/{skill.directory_name}/{sf.name}",
                content=file_content,
                tokens=ftoks,
                token_set=set(ftoks),
                embedding=_create_embedding(ftoks),
            ))

    indexed_skills: list[_IndexedSkill] = []
    for skill in skills:
        skill_docs = [d for d in documents if d.skill == skill.directory_name]
        aggregate = "\n".join(
            [skill.name, skill.description] + [d.content for d in skill_docs]
        )
        toks = _tokenize(aggregate)
        indexed_skills.append(_IndexedSkill(
            name=skill.directory_name,
            display_name=skill.name,
            description=skill.description,
            tokens=toks,
            token_set=set(toks),
            embedding=_create_embedding(toks),
        ))

    _index = _SkillIntelligenceIndex(documents=documents, skills=indexed_skills)
    return _index


# ── tools ──────────────────────────────────────────────────────────────────


@tool
def superpowers_list_skills() -> str:
    """List all available superpowers workflow skills.

    Returns a JSON array of skill names, display names, descriptions,
    and supporting file lists.
    """
    skills, _ = _ensure_loaded()
    if not skills:
        return "(no superpowers skills found — set SUPERPOWERS_SKILLS_DIR or clone the repo)"
    listing = [
        {
            "name": s.directory_name,
            "displayName": s.name,
            "description": s.description,
            "files": [f.name for f in s.files],
        }
        for s in skills
    ]
    return json.dumps(listing, indent=2)


@tool
def superpowers_use_skill(
    name: str,
    goal: Optional[str] = None,
    enforce_guardrails: bool = False,
) -> str:
    """Load a superpowers skill by directory name and return its full content.

    Pass the skill directory name (e.g. 'brainstorming',
    'test-driven-development').  The returned content is the complete
    SKILL.md — follow it as instructions.

    Set enforce_guardrails=True together with a goal to block this skill
    when prerequisite guardrail skills have not been used yet.
    """
    _, skill_map = _ensure_loaded()
    if name not in skill_map:
        return f"Skill '{name}' not found. Use superpowers_list_skills to see available skills."

    if enforce_guardrails:
        available = set(skill_map.keys())
        validation = _validate_next_skill(goal or "", _session_history, name, available)
        if not validation["valid"]:
            return (
                f"Guardrail check failed for intent '{validation['intent']}'. "
                + " ".join(validation["violations"])
            )

    _session_history.append(name)
    return skill_map[name].content


@tool
def superpowers_get_skill_file(skill: str, file: str) -> str:
    """Load a supporting file from a superpowers skill.

    Give the skill directory name and the filename (e.g.
    skill='test-driven-development', file='testing-anti-patterns.md').
    """
    _, skill_map = _ensure_loaded()
    if skill not in skill_map:
        return f"Skill '{skill}' not found. Use superpowers_list_skills to see available skills."

    sk = skill_map[skill]
    entry = next((f for f in sk.files if f.name == file), None)
    if entry is None:
        available = ", ".join(f.name for f in sk.files) or "none"
        return f"File '{file}' not found in skill '{skill}'. Available files: {available}"

    skills_dir = _resolve_skills_dir()
    if not skills_dir:
        return "Cannot read supporting files: skills directory not available."

    fp = Path(skills_dir) / entry.relative_path
    try:
        return fp.read_text(encoding="utf-8")
    except OSError:
        return f"Error reading file '{file}' from skill '{skill}'."


@tool
def superpowers_recommend_skills(
    task: str,
    repo_context: Optional[str] = None,
    max_results: int = 5,
) -> str:
    """Recommend the most relevant superpowers skills for a task.

    Uses semantic ranking and workflow policy boosts to order skills by
    relevance.  Provide optional repo_context for better matching.
    """
    index = _ensure_index()
    if not index.skills:
        return "(no skills indexed)"

    limit = max(1, min(10, max_results))
    full_query = _normalize_ws(f"{task} {repo_context or ''}")
    query_tokens = _tokenize(full_query)
    query_emb = _create_embedding(query_tokens)
    intent = infer_intent(full_query)
    available = {s.name for s in index.skills}
    policy = _get_intent_policy(intent, available)

    recs: list[dict] = []
    for sk in index.skills:
        sem = _cosine_similarity(query_emb, sk.embedding)
        overlap = _keyword_overlap(query_tokens, sk.token_set)
        intent_score = (
            1.0 if sk.name in policy["required"]
            else 0.6 if sk.name in policy["recommended"]
            else 0.0
        )
        score = sem * 0.65 + overlap * 0.25 + intent_score * 0.1

        reasons: list[str] = []
        if sk.name in policy["required"]:
            reasons.append(f"Required by {intent} workflow guardrails")
        elif sk.name in policy["recommended"]:
            reasons.append(f"Recommended by {intent} workflow guardrails")
        overlaps = _intersecting_tokens(query_tokens, sk.token_set)
        if overlaps:
            reasons.append(f"Keyword overlap: {', '.join(overlaps)}")
        if sem >= 0.2:
            reasons.append("High semantic similarity to the task")
        if not reasons:
            reasons.append("General relevance to the task")

        recs.append({
            "name": sk.name,
            "display_name": sk.display_name,
            "description": sk.description,
            "score": round(score, 4),
            "reasons": reasons,
        })

    recs.sort(key=lambda r: r["score"], reverse=True)
    return json.dumps(recs[:limit], indent=2)


@tool
def superpowers_compose_workflow(goal: str, max_steps: int = 6) -> str:
    """Build an ordered multi-skill workflow for a goal.

    Uses guardrails and semantic relevance to arrange skills in the
    correct execution order.
    """
    index = _ensure_index()
    if not index.skills:
        return "(no skills indexed)"

    limit = max(1, min(12, max_steps))
    available = {s.name for s in index.skills}
    intent = infer_intent(goal)
    policy = _get_intent_policy(intent, available)

    recs_raw = json.loads(superpowers_recommend_skills.invoke(
        {"task": goal, "max_results": max(limit, 6)}
    ))
    rec_map = {r["name"]: r for r in recs_raw}

    seen: set[str] = set()
    ordered: list[str] = []
    for s in (policy["required"] + policy["recommended"] + [r["name"] for r in recs_raw]):
        if s not in seen:
            seen.add(s)
            ordered.append(s)
    ordered = ordered[:limit]

    steps = []
    for s in ordered:
        r = rec_map.get(s)
        required = s in policy["required"]
        if required:
            reason = f"Required by guardrails for {intent} work"
        elif s in policy["recommended"]:
            reason = f"Recommended by guardrails for {intent} work"
        elif r:
            reason = r["reasons"][0] if r["reasons"] else "Relevant to the current goal"
        else:
            reason = "Relevant to the current goal"
        steps.append({
            "skill": s,
            "required": required,
            "score": r["score"] if r else 0,
            "reason": reason,
        })

    workflow = {
        "goal": goal,
        "intent": intent,
        "required_skills": policy["required"],
        "steps": steps,
    }
    return json.dumps(workflow, indent=2)


def _dedupe_ordered(values: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for v in values:
        if v not in seen:
            seen.add(v)
            out.append(v)
    return out


def _validate_workflow_logic(
    goal: str,
    selected_skills: list[str],
    enforce_order: bool = True,
    available: set[str] | None = None,
) -> dict:
    intent = infer_intent(goal)
    policy = _get_intent_policy(intent, available)
    selected = _dedupe_ordered(selected_skills)
    selected_set = set(selected)
    missing = [s for s in policy["required"] if s not in selected_set]
    violations: list[str] = []

    if missing:
        violations.append(f"Missing required skills: {', '.join(missing)}")

    if enforce_order and policy["required"]:
        first_optional = next(
            (i for i, s in enumerate(selected) if s not in policy["required"]),
            -1,
        )
        if first_optional >= 0:
            before = set(selected[:first_optional])
            missing_before = [s for s in policy["required"] if s not in before]
            if missing_before:
                violations.append(
                    f"Required skills must come before optional skills: {', '.join(missing_before)}"
                )

        last_req_idx = -1
        for req in policy["required"]:
            try:
                idx = selected.index(req)
            except ValueError:
                continue
            if idx < last_req_idx:
                violations.append("Required skills are out of order")
                break
            last_req_idx = idx

    return {
        "valid": len(violations) == 0,
        "intent": intent,
        "required_skills": policy["required"],
        "missing_required_skills": missing,
        "selected_skills": selected,
        "violations": violations,
    }


def _validate_next_skill(
    goal: str,
    used_skills: list[str],
    next_skill: str,
    available: set[str] | None = None,
) -> dict:
    intent = infer_intent(goal)
    policy = _get_intent_policy(intent, available)
    if not policy["required"]:
        return {
            "valid": True,
            "intent": intent,
            "required_skills": [],
            "missing_required_skills": [],
            "violations": [],
        }

    used = set(used_skills)
    required = policy["required"]
    missing = [s for s in required if s not in used]
    violations: list[str] = []

    if next_skill in required:
        req_idx = required.index(next_skill)
        missing_before = [s for s in required[:req_idx] if s not in used]
        if missing_before:
            violations.append(f"Required skills must be used first: {', '.join(missing_before)}")
    elif missing:
        violations.append(f"Required skills must be used first: {', '.join(missing)}")

    return {
        "valid": len(violations) == 0,
        "intent": intent,
        "required_skills": required,
        "missing_required_skills": missing,
        "violations": violations,
    }


@tool
def superpowers_validate_workflow(
    goal: str,
    selected_skills: list[str],
    enforce_order: bool = True,
) -> str:
    """Validate whether selected skills satisfy guardrails for a goal.

    Returns a JSON object with valid (bool), intent, required/missing
    skills, and any violations.
    """
    _, skill_map = _ensure_loaded()
    available = set(skill_map.keys())
    result = _validate_workflow_logic(goal, selected_skills, enforce_order, available)
    return json.dumps(result, indent=2)


@tool
def superpowers_search_skills(
    query: str,
    skill: Optional[str] = None,
    max_results: int = 5,
) -> str:
    """Semantic search across all superpowers skill content.

    Returns ranked matches with skill name, file, score, and a snippet.
    Optionally restrict to a single skill directory.
    """
    index = _ensure_index()
    if not index.documents:
        return "(no skills indexed)"

    limit = max(1, min(20, max_results))
    query_tokens = _tokenize(query)
    query_emb = _create_embedding(query_tokens)

    docs = index.documents
    if skill:
        docs = [d for d in docs if d.skill == skill]

    matches: list[dict] = []
    for doc in docs:
        sem = _cosine_similarity(query_emb, doc.embedding)
        overlap = _keyword_overlap(query_tokens, doc.token_set)
        score = sem * 0.7 + overlap * 0.3
        if score <= 0:
            continue
        matches.append({
            "skill": doc.skill,
            "file": doc.file,
            "source": doc.source,
            "uri": doc.uri,
            "score": round(score, 4),
            "snippet": _create_snippet(doc.content, query_tokens),
        })

    matches.sort(key=lambda m: m["score"], reverse=True)
    return json.dumps(matches[:limit], indent=2)


# ── registration helper ───────────────────────────────────────────────────

_SUPERPOWERS_TOOLS = None


def get_superpowers_tools() -> list:
    """Return all superpowers tools.

    The skills directory is resolved lazily; if no skills are found the
    tools are still registered — they gracefully report the missing
    directory at invocation time.
    """
    global _SUPERPOWERS_TOOLS
    if _SUPERPOWERS_TOOLS is not None:
        return _SUPERPOWERS_TOOLS

    _SUPERPOWERS_TOOLS = [
        superpowers_list_skills,
        superpowers_use_skill,
        superpowers_get_skill_file,
        superpowers_recommend_skills,
        superpowers_compose_workflow,
        superpowers_validate_workflow,
        superpowers_search_skills,
    ]
    return _SUPERPOWERS_TOOLS
