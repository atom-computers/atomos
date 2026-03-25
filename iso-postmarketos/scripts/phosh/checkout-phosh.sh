#!/bin/bash
# Clone or refresh local Phosh tree at vendor/phosh/phosh, then apply patches.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHOSH_GIT_URL="https://gitlab.gnome.org/World/Phosh/phosh.git"
PHOSH_CLONE_DIR="$ROOT_DIR/vendor/phosh/phosh"

if [ -e "$PHOSH_CLONE_DIR" ] && [ ! -d "$PHOSH_CLONE_DIR/.git" ]; then
    echo "ERROR: $PHOSH_CLONE_DIR exists but is not a git clone." >&2
    exit 1
fi

if [ -d "$PHOSH_CLONE_DIR/.git" ]; then
    if ! git -C "$PHOSH_CLONE_DIR" diff --quiet || ! git -C "$PHOSH_CLONE_DIR" diff --cached --quiet || [ -n "$(git -C "$PHOSH_CLONE_DIR" ls-files --others --exclude-standard)" ]; then
        echo "Resetting local Phosh checkout before applying AtomOS patches."
        git -C "$PHOSH_CLONE_DIR" reset --hard HEAD
        git -C "$PHOSH_CLONE_DIR" clean -fd
    fi

    echo "Updating Phosh clone at $PHOSH_CLONE_DIR"
    git -C "$PHOSH_CLONE_DIR" fetch origin
    if git -C "$PHOSH_CLONE_DIR" rev-parse -q --verify "@{upstream}" >/dev/null 2>&1; then
        if ! git -C "$PHOSH_CLONE_DIR" pull --ff-only; then
            echo "NOTE: fast-forward pull failed; resolve in $PHOSH_CLONE_DIR" >&2
        fi
    else
        echo "NOTE: current branch has no upstream; fetched origin only."
    fi
else
    mkdir -p "$(dirname "$PHOSH_CLONE_DIR")"
    echo "Cloning Phosh from $PHOSH_GIT_URL -> $PHOSH_CLONE_DIR"
    git clone "$PHOSH_GIT_URL" "$PHOSH_CLONE_DIR"
fi

PHOSH_CLONE_DIR="$PHOSH_CLONE_DIR" bash "$ROOT_DIR/scripts/phosh/apply-phosh-atomos-patches.sh"

echo "Phosh source: $PHOSH_CLONE_DIR"
