#!/bin/bash
# Clone or refresh local Phosh fork at rust/phosh/phosh.
#
# Tolerates two supported layouts:
#   (a) Git working tree  -- .git/ present; fetch+pull as before.
#   (b) Vendored snapshot -- the phosh source tree is committed directly
#       into the atomos parent repo (no nested .git/; `git rev-parse
#       --git-dir` from inside resolves to the atomos repo). This is the
#       default layout on build hosts that clone atomos via plain
#       `git clone` rather than using submodules. We treat it as
#       authoritative: skip the upstream sync step entirely and use the
#       tree as-is. Bumping the vendored phosh is then a normal atomos
#       commit (not a submodule rev-bump), which matches the existing
#       workflow where `rust/phosh/phosh/...` is edited directly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHOSH_GIT_URL="https://gitlab.gnome.org/World/Phosh/phosh.git"
PHOSH_CLONE_DIR="${PHOSH_CLONE_DIR:-${ATOMOS_PHOSH_SRC:-$ROOT_DIR/rust/phosh/phosh}}"
PHOSH_GIT_REF="${ATOMOS_PHOSH_GIT_REF:-}"

is_vendored_snapshot() {
    # Has the files we need to build but is NOT its own git repo
    # (either no .git at all, or .git resolves to some parent's repo).
    [ -d "$PHOSH_CLONE_DIR" ] || return 1
    [ -f "$PHOSH_CLONE_DIR/meson.build" ] || return 1
    [ ! -d "$PHOSH_CLONE_DIR/.git" ] || return 1
    return 0
}

if is_vendored_snapshot; then
    echo "Using local vendored Phosh source tree at $PHOSH_CLONE_DIR"
    echo "Skipping upstream sync (non-git source tree; tracked as plain files in the atomos repo)."
    echo "Phosh source: $PHOSH_CLONE_DIR"
    exit 0
fi

if [ -e "$PHOSH_CLONE_DIR" ] && [ ! -d "$PHOSH_CLONE_DIR/.git" ]; then
    echo "ERROR: $PHOSH_CLONE_DIR exists but is neither a git clone nor a vendored snapshot (missing meson.build)." >&2
    echo "       Remove the directory to have this script clone $PHOSH_GIT_URL, or populate it with the AtomOS phosh source tree." >&2
    exit 1
fi

if [ -d "$PHOSH_CLONE_DIR/.git" ]; then
    echo "Updating Phosh clone at $PHOSH_CLONE_DIR"
    git -C "$PHOSH_CLONE_DIR" fetch origin
    if [ -n "$PHOSH_GIT_REF" ]; then
        echo "Using pinned Phosh ref: $PHOSH_GIT_REF"
        if ! git -C "$PHOSH_CLONE_DIR" rev-parse -q --verify "${PHOSH_GIT_REF}^{commit}" >/dev/null 2>&1; then
            git -C "$PHOSH_CLONE_DIR" fetch origin "$PHOSH_GIT_REF"
        fi
        git -C "$PHOSH_CLONE_DIR" checkout -q "$PHOSH_GIT_REF"
    elif git -C "$PHOSH_CLONE_DIR" rev-parse -q --verify "@{upstream}" >/dev/null 2>&1; then
        if git -C "$PHOSH_CLONE_DIR" diff --quiet && git -C "$PHOSH_CLONE_DIR" diff --cached --quiet && [ -z "$(git -C "$PHOSH_CLONE_DIR" ls-files --others --exclude-standard)" ]; then
            if ! git -C "$PHOSH_CLONE_DIR" pull --ff-only; then
                echo "NOTE: fast-forward pull failed; resolve in $PHOSH_CLONE_DIR" >&2
            fi
        else
            echo "NOTE: local edits present; skipping automatic pull in $PHOSH_CLONE_DIR"
        fi
    else
        echo "NOTE: current branch has no upstream; fetched origin only."
    fi
else
    mkdir -p "$(dirname "$PHOSH_CLONE_DIR")"
    echo "Cloning Phosh from $PHOSH_GIT_URL -> $PHOSH_CLONE_DIR"
    git clone "$PHOSH_GIT_URL" "$PHOSH_CLONE_DIR"
    if [ -n "$PHOSH_GIT_REF" ]; then
        echo "Using pinned Phosh ref: $PHOSH_GIT_REF"
        git -C "$PHOSH_CLONE_DIR" fetch origin "$PHOSH_GIT_REF"
        git -C "$PHOSH_CLONE_DIR" checkout -q "$PHOSH_GIT_REF"
    fi
fi

echo "Phosh source: $PHOSH_CLONE_DIR"
