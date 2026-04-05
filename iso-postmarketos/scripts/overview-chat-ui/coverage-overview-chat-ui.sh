#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/atomos-overview-chat-ui"

CORE_MIN_LINES="${ATOMOS_OVERVIEW_CHAT_UI_CORE_MIN_LINES:-95}"
APP_GTK_MIN_LINES="${ATOMOS_OVERVIEW_CHAT_UI_APP_GTK_MIN_LINES:-90}"
INCLUDE_APP_GTK="${ATOMOS_OVERVIEW_CHAT_UI_COVERAGE_INCLUDE_GTK:-0}"

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required." >&2
    exit 1
fi

if ! cargo llvm-cov --version >/dev/null 2>&1; then
    echo "cargo-llvm-cov is required." >&2
    echo "Install with: cargo install cargo-llvm-cov" >&2
    exit 1
fi

echo "Running core coverage (min lines: ${CORE_MIN_LINES}%)..."
cargo llvm-cov clean --manifest-path "$CRATE_DIR/Cargo.toml"
cargo llvm-cov \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    -p atomos-overview-chat-ui \
    --summary-only \
    --fail-under-lines "$CORE_MIN_LINES"

if [ "$INCLUDE_APP_GTK" != "1" ]; then
    echo "Skipping app-gtk coverage (set ATOMOS_OVERVIEW_CHAT_UI_COVERAGE_INCLUDE_GTK=1 to enable)."
    exit 0
fi

if ! command -v pkg-config >/dev/null 2>&1; then
    echo "pkg-config not found; cannot run app-gtk coverage." >&2
    exit 1
fi

for dep in gtk4 gdk-pixbuf-2.0 graphene-gobject-1.0; do
    if ! pkg-config --exists "$dep"; then
        echo "Missing pkg-config dependency for app-gtk coverage: $dep" >&2
        echo "Install GTK development packages or skip app-gtk coverage on this host." >&2
        exit 1
    fi
done

echo "Running app-gtk coverage (min lines: ${APP_GTK_MIN_LINES}%)..."
cargo llvm-cov clean --manifest-path "$CRATE_DIR/Cargo.toml"
cargo llvm-cov \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    -p atomos-overview-chat-ui-app \
    --summary-only \
    --fail-under-lines "$APP_GTK_MIN_LINES"
