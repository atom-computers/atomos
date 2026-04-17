#!/bin/bash
# Clone or refresh local Phosh fork at rust/phosh/phosh (no patch replay).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHOSH_GIT_URL="https://gitlab.gnome.org/World/Phosh/phosh.git"
PHOSH_CLONE_DIR="${PHOSH_CLONE_DIR:-${ATOMOS_PHOSH_SRC:-$ROOT_DIR/rust/phosh/phosh}}"
PHOSH_GIT_REF="${ATOMOS_PHOSH_GIT_REF:-}"

if [ -e "$PHOSH_CLONE_DIR" ] && [ ! -d "$PHOSH_CLONE_DIR/.git" ]; then
    echo "ERROR: $PHOSH_CLONE_DIR exists but is not a git clone." >&2
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
