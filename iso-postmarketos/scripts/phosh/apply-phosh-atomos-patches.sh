#!/bin/bash
# Deprecated patch replay helper. The Phosh fork is now edited directly.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHOSH_DIR="${PHOSH_CLONE_DIR:-${ATOMOS_PHOSH_SRC:-$ROOT_DIR/rust/phosh/phosh}}"

if [ ! -d "$PHOSH_DIR/.git" ]; then
    echo "ERROR: No Phosh clone at $PHOSH_DIR — run: bash scripts/phosh/checkout-phosh.sh" >&2
    exit 1
fi

echo "scripts/phosh/apply-phosh-atomos-patches.sh is deprecated."
echo "Maintain Phosh directly in $PHOSH_DIR and commit changes there."
