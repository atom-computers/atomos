#!/bin/bash
# Gate (4): compile-time + gdbus header checks for org.atomos.PhoshHome (Linux).
#
# Does not need a running Phosh session. Catches gdbus naming collisions,
# missing meson entries, and handler signature drift before image build.
#
# Usage:
#   bash scripts/phosh/test-phosh-home-dbus-compile.sh
#   bash scripts/phosh/test-phosh-home-dbus-compile.sh --with-ninja
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/phosh/_lib-verify-vendor-phosh-atomos.sh
source "$ROOT_DIR/scripts/phosh/_lib-verify-vendor-phosh-atomos.sh"

PHOSH_SRC="${PHOSH_SRC:-$ROOT_DIR/rust/phosh/phosh}"
WITH_NINJA=0

for arg in "$@"; do
    case "$arg" in
        --with-ninja) WITH_NINJA=1 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

atomos_verify_phosh_source_atomos_dbus "$PHOSH_SRC"

if [ "$WITH_NINJA" -eq 1 ]; then
    if ! command -v meson >/dev/null 2>&1 || ! command -v ninja >/dev/null 2>&1; then
        echo "ERROR: --with-ninja requires meson and ninja on PATH" >&2
        exit 1
    fi
    BUILD_DIR="$(mktemp -d)"
    trap 'rm -rf "$BUILD_DIR"' EXIT
    echo "=== meson setup (minimal, tests=false) ==="
    meson setup "$BUILD_DIR" "$PHOSH_SRC" --prefix=/usr -Dtests=false
    echo "=== ninja atomos-phosh-home-dbus ==="
    ninja -C "$BUILD_DIR" src/libphosh-tool.a.p/atomos-phosh-home-dbus.c.o
    atomos_verify_phosh_meson_build_has_atomos_dbus "$BUILD_DIR"
fi

echo "test-phosh-home-dbus-compile: PASS"
