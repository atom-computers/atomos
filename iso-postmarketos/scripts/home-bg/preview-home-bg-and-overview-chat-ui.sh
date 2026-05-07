#!/bin/bash
# Combined local preview: spin up atomos-home-bg behind atomos-overview-chat-ui
# so you can eyeball the stacked composition the way phosh will see it on
# device. Two modes, auto-detected:
#
#   layered (Linux + Wayland + layer-shell + WebKitGTK 6)
#     - Launches atomos-home-bg on Layer::Background in the real compositor.
#     - Launches atomos-overview-chat-ui (GTK4/libadwaita) in front, defaulting
#       to its normal `top` layer when layer-shell is enabled.
#     - Exits when overview-chat-ui exits; always tears down the home-bg child.
#
#   egui-fallback (macOS, or Linux without WebKit / layer-shell)
#     - atomos-home-bg cannot render without WebKitGTK on Linux, so we skip
#       its runtime and run a single-window egui combined preview that
#       simulates the layering visually (#0a0a0a base under the chat input
#       strip — matches the dark base of the shipped placeholder; the
#       WebGL event-horizon shader does not run in this mode).
#
# Override selection: ATOMOS_HOME_BG_COMBINED_MODE=layered|egui-fallback
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOME_BG_DIR="$ROOT_DIR/rust/atomos-home-bg"
OVERVIEW_DIR="$ROOT_DIR/rust/atomos-overview-chat-ui"

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required." >&2
    exit 1
fi

MODE="${ATOMOS_HOME_BG_COMBINED_MODE:-auto}"

detect_mode() {
    if [ "$(uname -s)" != "Linux" ]; then
        echo "egui-fallback"
        return
    fi
    if [ -z "${WAYLAND_DISPLAY:-}" ]; then
        echo "egui-fallback"
        return
    fi
    if ! command -v pkg-config >/dev/null 2>&1; then
        echo "egui-fallback"
        return
    fi
    if ! pkg-config --exists gtk4 gtk4-layer-shell-0 webkitgtk-6.0 libadwaita-1; then
        echo "egui-fallback"
        return
    fi
    echo "layered"
}

if [ "$MODE" = "auto" ]; then
    MODE="$(detect_mode)"
fi

case "$MODE" in
    layered)
        echo "preview-combined: mode=layered (home-bg on Layer::Background + overview-chat-ui on top)"
        export ATOMOS_HOME_BG_ENABLE_RUNTIME=1
        export ATOMOS_HOME_BG_LAYER="${ATOMOS_HOME_BG_LAYER:-bottom}"
        export ATOMOS_HOME_BG_INTERACTIVE="${ATOMOS_HOME_BG_INTERACTIVE:-0}"
        if [ -z "${ATOMOS_HOME_BG_URL:-}" ]; then
            export ATOMOS_HOME_BG_URL="file://$ROOT_DIR/data/atomos-home-bg/index.html"
        fi
        export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL:-1}"
        export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-1}"
        export ATOMOS_OVERVIEW_CHAT_UI_LAYER="${ATOMOS_OVERVIEW_CHAT_UI_LAYER:-top}"

        HOME_BG_PID=""
        cleanup() {
            if [ -n "$HOME_BG_PID" ] && kill -0 "$HOME_BG_PID" 2>/dev/null; then
                echo "preview-combined: stopping home-bg (pid=$HOME_BG_PID)"
                kill "$HOME_BG_PID" 2>/dev/null || true
                wait "$HOME_BG_PID" 2>/dev/null || true
            fi
        }
        trap cleanup EXIT INT TERM

        echo "preview-combined: cargo run home-bg (layer-shell default: bottom)"
        cargo run \
            --manifest-path "$HOME_BG_DIR/Cargo.toml" \
            -p atomos-home-bg-app \
            --bin atomos-home-bg &
        HOME_BG_PID=$!
        sleep "${ATOMOS_HOME_BG_COMBINED_WARMUP_SECS:-2}"
        if ! kill -0 "$HOME_BG_PID" 2>/dev/null; then
            echo "preview-combined: ERROR home-bg exited during warmup. Re-run with" >&2
            echo "  ATOMOS_HOME_BG_COMBINED_MODE=egui-fallback" >&2
            echo "  or inspect \$XDG_RUNTIME_DIR/atomos-home-bg.log" >&2
            exit 1
        fi

        echo "preview-combined: cargo run overview-chat-ui (foreground)"
        cargo run \
            --manifest-path "$OVERVIEW_DIR/Cargo.toml" \
            -p atomos-overview-chat-ui-app \
            --bin atomos-overview-chat-ui
        ;;
    egui-fallback)
        cat <<EOF
preview-combined: mode=egui-fallback.

  atomos-home-bg needs GTK4 + WebKitGTK 6 + a wlr-layer-shell-capable Wayland
  compositor. Current host does not meet that bar (macOS, or Linux without
  the deps / WAYLAND_DISPLAY), so we cannot do a real compositor-level layered
  composition.

  Running the combined egui dev preview (atomos-home-bg-combined-preview),
  which renders the home-bg as a #0a0a0a opaque base in the background
  of a single eframe window and overlays an overview-chat-ui input strip
  on top. Layering parity with the on-device composition; the WebGL
  event-horizon shader is exclusive to the layered (WebKitGTK) mode.

  The combined integration tests (cargo test -p atomos-home-bg) continue to
  lock the actual layer-shell invariants between the two crates.
EOF
        exec cargo run \
            --manifest-path "$HOME_BG_DIR/Cargo.toml" \
            -p atomos-home-bg-egui \
            --bin atomos-home-bg-combined-preview
        ;;
    *)
        echo "Unknown ATOMOS_HOME_BG_COMBINED_MODE: $MODE" >&2
        echo "Valid values: auto (default), layered, egui-fallback" >&2
        exit 1
        ;;
esac
