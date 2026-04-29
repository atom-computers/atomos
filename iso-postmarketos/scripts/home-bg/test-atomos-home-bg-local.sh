#!/bin/bash
# Runs the atomos-home-bg core test suite. Intentionally cross-platform:
# the core crate is pure logic, so macOS developer boxes exercise the
# contract even without GTK/WebKit runtime deps.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/atomos-home-bg"

if ! command -v cargo >/dev/null 2>&1; then
    echo "ERROR: cargo is required." >&2
    exit 1
fi

echo "=== Core logic tests (crate: atomos-home-bg) ==="
cargo test \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    -p atomos-home-bg

echo "=== Combined egui preview tests (crate: atomos-home-bg-egui) ==="
cargo test \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    -p atomos-home-bg-egui

echo "=== cargo check (crate: atomos-home-bg-app) ==="
cargo check \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    -p atomos-home-bg-app

echo ""
echo "atomos-home-bg local test harness completed."
