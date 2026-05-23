#!/bin/bash
# Run all cross-platform tests for atomos-app-handler.
#
# Covers:
#   - core crate (constants, gesture math, overlay state machine)
#   - core/tests/combined_stack.rs (namespace / env / layer disjointness
#     against atomos-home-bg + atomos-overview-chat-ui)
#   - core/tests/handle_paint.rs (visible swipe-up handle layout/colors)
#   - app-egui crate (layout helpers, headless render assertions)
#
# Does NOT exercise the GTK device binary — that requires a Linux host with
# GTK4 + layer-shell. Validate that path with the alpine container build:
#   scripts/app-handler/build-app-handler.sh <profile-env>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/atomos-app-handler"

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required." >&2
    exit 1
fi

cd "$CRATE_DIR"
cargo test -p atomos-app-handler
cargo test -p atomos-app-handler --test handle_paint
cargo test -p atomos-app-handler --test home_handler_contract
cargo test -p atomos-app-handler --test phosh_home_c_source_contract

# Cross-layer: Phosh home.c must not send --show on unfold (post-unlock regression).
(cd "$ROOT_DIR" && python3 -m unittest tests.test_phosh_home_c_lifecycle_contract -q)

# Gate (4): Phosh org.atomos.PhoshHome gdbus source/compile checks (Linux only).
if [ "$(uname -s)" = "Linux" ] || [ "${ATOMOS_PHOSH_DBUS_COMPILE_TEST:-0}" = "1" ]; then
    bash "$ROOT_DIR/scripts/phosh/test-phosh-home-dbus-compile.sh"
else
    bash "$ROOT_DIR/scripts/phosh/verify-vendor-phosh-build.sh" --source-only
fi

# Optional dev-preview crate (eframe). Skip when ATOMOS_SKIP_EGUI_TESTS=1 or
# when the host cannot compile eframe (e.g. atspi breakage with default features).
if [ "${ATOMOS_SKIP_EGUI_TESTS:-0}" != "1" ]; then
    if cargo test -p atomos-app-handler-egui 2>&1; then
        :
    else
        echo "WARN: atomos-app-handler-egui tests failed or could not compile." >&2
        echo "      The device binary (app-gtk) is unaffected. Set ATOMOS_SKIP_EGUI_TESTS=1 to silence." >&2
        echo "      If you see 'Operation not permitted' under target/, run: rm -rf $CRATE_DIR/target" >&2
        exit 1
    fi
else
    echo "INFO: skipping atomos-app-handler-egui tests (ATOMOS_SKIP_EGUI_TESTS=1)"
fi
