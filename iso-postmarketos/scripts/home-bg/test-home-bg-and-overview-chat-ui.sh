#!/bin/bash
# Combined-stack test harness: runs the atomos-home-bg core suite (including
# the cross-crate integration tests that assert layering/namespace/runtime
# disjointness with atomos-overview-chat-ui) plus the overview-chat-ui core
# and egui suites, then cargo-checks both binaries in whichever mode the
# current host supports (native GTK on Linux, stub on macOS).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOME_BG_DIR="$ROOT_DIR/rust/atomos-home-bg"
OVERVIEW_DIR="$ROOT_DIR/rust/atomos-overview-chat-ui"

STRICT="${ATOMOS_HOME_BG_COMBINED_STRICT:-0}"
RUN_GTK="${ATOMOS_HOME_BG_COMBINED_TEST_GTK:-auto}"

if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo is required." >&2
    exit 1
fi

print_header() {
    echo ""
    echo "=== $1 ==="
}

summarize_skip() {
    local msg="$1"
    if [ "$STRICT" = "1" ]; then
        echo "ERROR: $msg (ATOMOS_HOME_BG_COMBINED_STRICT=1)" >&2
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

webkit_deps_ready() {
    command -v pkg-config >/dev/null 2>&1 || return 1
    pkg-config --exists webkitgtk-6.0 && pkg-config --exists gtk4-layer-shell-0
}

print_header "atomos-home-bg core + combined integration tests"
cargo test \
    --manifest-path "$HOME_BG_DIR/Cargo.toml" \
    -p atomos-home-bg

print_header "atomos-overview-chat-ui core tests"
cargo test \
    --manifest-path "$OVERVIEW_DIR/Cargo.toml" \
    -p atomos-overview-chat-ui

print_header "atomos-overview-chat-ui egui dev preview build/tests"
cargo test \
    --manifest-path "$OVERVIEW_DIR/Cargo.toml" \
    -p atomos-overview-chat-ui-egui

print_header "atomos-home-bg combined egui dev preview build/tests"
cargo test \
    --manifest-path "$HOME_BG_DIR/Cargo.toml" \
    -p atomos-home-bg-egui

print_header "cargo check: atomos-home-bg-app (stub on macOS, real GTK on Linux)"
cargo check \
    --manifest-path "$HOME_BG_DIR/Cargo.toml" \
    -p atomos-home-bg-app

if [ "$RUN_GTK" = "0" ]; then
    summarize_skip "GTK suites disabled by ATOMOS_HOME_BG_COMBINED_TEST_GTK=0"
elif gtk_deps_ready; then
    print_header "atomos-overview-chat-ui-app GTK tests (Linux GTK4/libadwaita)"
    cargo test \
        --manifest-path "$OVERVIEW_DIR/Cargo.toml" \
        -p atomos-overview-chat-ui-app
    if webkit_deps_ready; then
        print_header "atomos-home-bg-app GTK build check (Linux GTK4/WebKitGTK 6)"
        cargo build \
            --manifest-path "$HOME_BG_DIR/Cargo.toml" \
            -p atomos-home-bg-app \
            --bin atomos-home-bg
    else
        summarize_skip "WebKitGTK 6 / gtk4-layer-shell-0 missing; skipping home-bg GTK build"
    fi
else
    summarize_skip "GTK4/libadwaita dev packages missing; skipping native GTK suites"
fi

echo ""
echo "Combined home-bg + overview-chat-ui test harness completed."
