#!/bin/bash
# Local test harness for atomos-overview-chat-ui.
# Runs all function-level tests available on the current host and reports
# which suites are skipped due to missing platform/runtime dependencies.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/atomos-overview-chat-ui"

STRICT="${ATOMOS_OVERVIEW_CHAT_UI_LOCAL_TEST_STRICT:-0}"
RUN_GTK="${ATOMOS_OVERVIEW_CHAT_UI_LOCAL_TEST_GTK:-auto}"
RUN_SMOKE="${ATOMOS_OVERVIEW_CHAT_UI_LOCAL_TEST_SMOKE:-0}"

if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo is required." >&2
    exit 1
fi

if [ ! -f "$CRATE_DIR/Cargo.toml" ]; then
    echo "ERROR: missing workspace manifest at $CRATE_DIR/Cargo.toml" >&2
    exit 1
fi

summarize_skip() {
    local msg="$1"
    if [ "$STRICT" = "1" ]; then
        echo "ERROR: $msg (strict mode enabled)" >&2
        exit 2
    fi
    echo "SKIP: $msg"
}

gtk_deps_ready() {
    command -v pkg-config >/dev/null 2>&1 || return 1
    local dep
    for dep in gtk4 gdk-pixbuf-2.0 graphene-gobject-1.0 libadwaita-1; do
        pkg-config --exists "$dep" || return 1
    done
    return 0
}

print_header() {
    echo ""
    echo "=== $1 ==="
}

print_header "Core logic tests (crate: atomos-overview-chat-ui)"
cargo test \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    -p atomos-overview-chat-ui

print_header "egui integration tests/build checks (crate: atomos-overview-chat-ui-egui)"
cargo test \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    -p atomos-overview-chat-ui-egui

if [ "$RUN_GTK" = "0" ]; then
    summarize_skip "GTK suite disabled by ATOMOS_OVERVIEW_CHAT_UI_LOCAL_TEST_GTK=0"
else
    if gtk_deps_ready; then
        print_header "GTK module tests/build checks (crate: atomos-overview-chat-ui-app)"
        cargo test \
            --manifest-path "$CRATE_DIR/Cargo.toml" \
            -p atomos-overview-chat-ui-app
    else
        summarize_skip "GTK dependencies missing (need pkg-config + gtk4/gdk-pixbuf/graphene/libadwaita dev packages)"
    fi
fi

if [ "$RUN_SMOKE" = "1" ]; then
    print_header "Optional preview smoke check"
    if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
        timeout_cmd=""
        if command -v timeout >/dev/null 2>&1; then
            timeout_cmd="timeout 8s"
        fi
        # Smoke-launch in GTK mode when display is available.
        # Timeout-based exit is expected and treated as success.
        set +e
        ATOMOS_OVERVIEW_CHAT_UI_PREVIEW=gtk $timeout_cmd \
            bash "$ROOT_DIR/scripts/overview-chat-ui/preview-overview-chat-ui.sh"
        rc=$?
        set -e
        if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
            echo "ERROR: GTK smoke preview failed (rc=$rc)" >&2
            exit "$rc"
        fi
    else
        summarize_skip "smoke check requested but no WAYLAND_DISPLAY/DISPLAY available"
    fi
fi

echo ""
echo "Local overview-chat-ui test harness completed."
