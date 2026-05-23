"""Parse Phosh home.c lifecycle sync and enforce the Rust shell policy."""

from __future__ import annotations

import re
from pathlib import Path

# Pre-fix regression: unfold sent --show → SIGUSR1 covered home after unlock.
BUGGY_ATOMOS_PHOSH_SYNC_APP_HANDLER_LIFECYCLE = """
static void
atomos_phosh_sync_app_handler_lifecycle (PhoshHomeState state)
{
  const char *action = NULL;
  switch (state) {
  case PHOSH_HOME_STATE_FOLDED:
    action = "--hide";
    break;
  case PHOSH_HOME_STATE_UNFOLDED:
    action = "--show";
    break;
  default:
    return;
  }
}
"""

ALLOWED_SHELL_LIFECYCLE_ARGV = frozenset({"--hide"})


def strip_c_comments(source: str) -> str:
    """Remove block and line comments so policy checks ignore doc text."""
    out = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    return re.sub(r"//.*?$", "", out, flags=re.MULTILINE)


def extract_c_function(source: str, name: str) -> str:
    """Return the function body (including outer braces) for a void name(...)."""
    pattern = re.compile(
        rf"(?:static\s+)?void\s+{re.escape(name)}\s*\([^)]*\)\s*\{{",
        re.MULTILINE,
    )
    match = pattern.search(source)
    if not match:
        raise AssertionError(f"function {name!r} not found in source")
    start = match.end() - 1  # opening brace
    depth = 0
    for idx in range(start, len(source)):
        ch = source[idx]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[match.start() : idx + 1]
    raise AssertionError(f"unbalanced braces in function {name!r}")


def extract_switch_case(function_body: str, case_label: str) -> str:
    """Text from ``case LABEL:`` until the next case/default (exclusive)."""
    pattern = re.compile(
        rf"case\s+{re.escape(case_label)}\s*:(.*?)(?=case\s+|default\s*:|$)",
        re.DOTALL,
    )
    match = pattern.search(function_body)
    if not match:
        raise AssertionError(f"switch case {case_label!r} not found")
    return match.group(1)


def lifecycle_spawn_argv_tokens(function_body: str) -> set[str]:
    """Argv fragments passed to the libexec launcher inside the lifecycle function."""
    return set(re.findall(r'action\s*=\s*"([^"]+)"', function_body))


def assert_phosh_home_c_shell_lifecycle_contract(function_body: str) -> None:
    code = strip_c_comments(function_body)
    unfolded = extract_switch_case(code, "PHOSH_HOME_STATE_UNFOLDED")
    folded = extract_switch_case(code, "PHOSH_HOME_STATE_FOLDED")

    unfolded_actions = lifecycle_spawn_argv_tokens(unfolded)
    if unfolded_actions:
        raise AssertionError(
            f"PHOSH_HOME_STATE_UNFOLDED must not assign action; got {unfolded_actions!r} "
            "(post-unlock must not spawn --show / SIGUSR1)"
        )

    folded_actions = lifecycle_spawn_argv_tokens(folded)
    if folded_actions != {"--hide"}:
        raise AssertionError(
            f"PHOSH_HOME_STATE_FOLDED must only set action=\"--hide\", got {folded_actions!r}"
        )

    all_actions = lifecycle_spawn_argv_tokens(code)
    unknown = all_actions - ALLOWED_SHELL_LIFECYCLE_ARGV
    if unknown:
        raise AssertionError(
            f"disallowed libexec lifecycle argv in atomos_phosh_sync_app_handler_lifecycle: "
            f"{unknown!r} (allowed {sorted(ALLOWED_SHELL_LIFECYCLE_ARGV)!r})"
        )
    if "--show" in all_actions:
        raise AssertionError(
            "atomos_phosh_sync_app_handler_lifecycle must never spawn --show"
        )


def load_home_c(path: Path) -> str:
    return path.read_text(encoding="utf-8")
