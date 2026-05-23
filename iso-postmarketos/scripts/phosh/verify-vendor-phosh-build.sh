#!/bin/bash
# Gate (1): fail if vendor Phosh was built without org.atomos.PhoshHome D-Bus.
#
# Usage:
#   # After container phosh build (lib under /target):
#   bash scripts/phosh/verify-vendor-phosh-build.sh
#
#   # Host-side source-only check:
#   bash scripts/phosh/verify-vendor-phosh-build.sh --source-only
#
#   # Explicit paths:
#   PHOSH_SRC=... PHOSH_BUILD=... bash scripts/phosh/verify-vendor-phosh-build.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/phosh/_lib-verify-vendor-phosh-atomos.sh
source "$ROOT_DIR/scripts/phosh/_lib-verify-vendor-phosh-atomos.sh"

PHOSH_SRC="${PHOSH_SRC:-$ROOT_DIR/rust/phosh/phosh}"
PHOSH_BUILD="${PHOSH_BUILD:-/cache/phosh}"
SOURCE_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --source-only) SOURCE_ONLY=1 ;;
        -h|--help)
            echo "Usage: $0 [--source-only]" >&2
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

atomos_verify_phosh_source_atomos_dbus "$PHOSH_SRC"

if [ "$SOURCE_ONLY" -eq 0 ]; then
    if [ -d "$PHOSH_BUILD" ]; then
        atomos_verify_phosh_meson_build_has_atomos_dbus "$PHOSH_BUILD"
    fi
    atomos_verify_built_libphosh_has_atomos_dbus ""
fi

echo "verify-vendor-phosh-build: PASS"
