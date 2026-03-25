#!/bin/bash
# Apply AtomOS Phosh patches from vendor/phosh/patches/*.patch (sorted by name).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHOSH_DIR="${PHOSH_CLONE_DIR:-$ROOT_DIR/vendor/phosh/phosh}"
PATCH_DIR="$ROOT_DIR/vendor/phosh/patches"

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
    apply_one "$patch"
done

echo "Phosh patches done: $PHOSH_DIR"
