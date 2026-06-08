#!/bin/bash
# Local preview of the light-earth background in the egui-fallback combined preview.
# Stacks a simulated #ffffff light-earth background under the chat input strip
# inside a single eframe (egui) window.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOME_BG_DIR="$ROOT_DIR/rust/atomos-home-bg"

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required." >&2
    exit 1
fi

echo "=== Starting light-earth egui preview ==="
export ATOMOS_LIGHT_EARTH=1

exec cargo run \
    --manifest-path "$HOME_BG_DIR/Cargo.toml" \
    -p atomos-home-bg-egui \
    --bin atomos-home-bg-combined-preview
