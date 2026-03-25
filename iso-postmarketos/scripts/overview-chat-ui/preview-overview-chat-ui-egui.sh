#!/bin/bash
# Cross-platform egui preview (input logic + rough layout only; not libadwaita).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/atomos-overview-chat-ui"

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required." >&2
    exit 1
fi

exec cargo run \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    -p atomos-overview-chat-ui-egui \
    --bin atomos-overview-chat-ui-dev
