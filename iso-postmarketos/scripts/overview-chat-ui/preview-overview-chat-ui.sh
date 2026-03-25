#!/bin/bash
# Run the overview chat UI locally without flashing.
#
# Default:
#   Linux: GTK4 + libadwaita (same binary as production — real GNOME stack in your session).
#   macOS: egui dev preview (GTK is not wired for typical macOS dev setups).
#
# Override: ATOMOS_OVERVIEW_CHAT_UI_PREVIEW=gtk|egui
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/atomos-overview-chat-ui"

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required." >&2
    exit 1
fi

MODE="${ATOMOS_OVERVIEW_CHAT_UI_PREVIEW:-}"
if [ -z "$MODE" ]; then
    case "$(uname -s)" in
        Darwin)
            MODE=egui
            ;;
        *)
            MODE=gtk
            ;;
    esac
fi

case "$MODE" in
    gtk)
        if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
            echo "preview (gtk): no WAYLAND_DISPLAY or DISPLAY; start a Wayland/X11 session (e.g. GNOME on Linux) or run nested compositor." >&2
            echo "  Force egui-only: ATOMOS_OVERVIEW_CHAT_UI_PREVIEW=egui $0" >&2
            exit 1
        fi
        exec cargo run \
            --manifest-path "$CRATE_DIR/Cargo.toml" \
            -p atomos-overview-chat-ui-app \
            --bin atomos-overview-chat-ui
        ;;
    egui)
        exec cargo run \
            --manifest-path "$CRATE_DIR/Cargo.toml" \
            -p atomos-overview-chat-ui-egui \
            --bin atomos-overview-chat-ui-dev
        ;;
    *)
        echo "ATOMOS_OVERVIEW_CHAT_UI_PREVIEW must be gtk or egui (got: $MODE)" >&2
        exit 1
        ;;
esac
