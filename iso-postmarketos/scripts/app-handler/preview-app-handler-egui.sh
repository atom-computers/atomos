#!/bin/bash
# Local egui dev preview for atomos-app-handler.
#
# Runs cross-platform (macOS / Linux) without GTK or a Wayland compositor.
# The preview mirrors what the real device sees:
#   - opaque #0a0a0a backdrop (matching atomos-home-bg's HOME_BG_BASE_COLOR)
#   - mock running-apps card row with swipe-to-dismiss + tap-to-activate
#   - bottom-edge invisible drag handle (click also toggles for non-touch hosts)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/atomos-app-handler"

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required." >&2
    exit 1
fi

exec cargo run \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    -p atomos-app-handler-egui \
    --bin atomos-app-handler-preview
