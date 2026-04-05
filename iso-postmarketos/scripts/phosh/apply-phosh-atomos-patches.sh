#!/bin/bash
# Apply AtomOS Phosh patches from vendor/phosh/patches/*.patch (sorted by name).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHOSH_DIR="${PHOSH_CLONE_DIR:-$ROOT_DIR/vendor/phosh/phosh}"
PATCH_DIR="$ROOT_DIR/vendor/phosh/patches"
PATCHES_MODE="${ATOMOS_PHOSH_PATCHES:-all}"
APPLY_PATCHES="${ATOMOS_PHOSH_APPLY_PATCHES:-1}"

if [ ! -d "$PHOSH_DIR/.git" ]; then
    echo "ERROR: No Phosh clone at $PHOSH_DIR — run: bash scripts/phosh/checkout-phosh.sh" >&2
    exit 1
fi

shopt -s nullglob
patches=( "$PATCH_DIR"/*.patch )
shopt -u nullglob

if [ "${#patches[@]}" -eq 0 ]; then
    echo "No patches in $PATCH_DIR"
    exit 0
fi

if [ "$APPLY_PATCHES" != "1" ] || [ "$PATCHES_MODE" = "none" ]; then
    echo "Skipping AtomOS phosh patches (ATOMOS_PHOSH_APPLY_PATCHES=$APPLY_PATCHES, ATOMOS_PHOSH_PATCHES=$PATCHES_MODE)."
    exit 0
fi

patch_is_selected() {
    local base="$1"
    local token
    if [ "$PATCHES_MODE" = "all" ]; then
        return 0
    fi
    local IFS=','
    read -r -a tokens <<< "$PATCHES_MODE"
    for token in "${tokens[@]}"; do
        token="$(echo "$token" | tr -d '[:space:]')"
        [ -n "$token" ] || continue
        if [ "$base" = "$token" ] || [[ "$base" == "$token"* ]]; then
            return 0
        fi
    done
    return 1
}

apply_one() {
    local patch="$1"
    local base
    base="$(basename "$patch")"
    if git -C "$PHOSH_DIR" apply --check "$patch" 2>/dev/null; then
        git -C "$PHOSH_DIR" apply --whitespace=nowarn "$patch"
        echo "Applied $base"
    elif git -C "$PHOSH_DIR" apply --reverse --check "$patch" 2>/dev/null; then
        echo "Skip $base (already applied)"
    else
        echo "ERROR: $base does not apply cleanly; rebase the patch on your Phosh revision" >&2
        exit 1
    fi
}

for patch in "${patches[@]}"; do
    base="$(basename "$patch")"
    if patch_is_selected "$base"; then
        apply_one "$patch"
    else
        echo "Skip $base (not selected by ATOMOS_PHOSH_PATCHES=$PATCHES_MODE)"
    fi
done

echo "Phosh patches done: $PHOSH_DIR"
