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
JHBUILD_BIN_DEFAULT="$HOME/.new_local/bin/jhbuild"
MACOS_GTK_ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/atomos-overview-chat-ui/macos-gtk.env"

have_jhbuild_gtk4_stack() {
    local jhbuild_bin="$1"
    [ -x "$jhbuild_bin" ] && "$jhbuild_bin" run pkg-config --exists gtk4 gdk-pixbuf-2.0 graphene-gobject-1.0 2>/dev/null
}

have_host_gtk4_stack() {
    command -v pkg-config >/dev/null 2>&1 &&
        pkg-config --exists gtk4 libadwaita-1 gdk-pixbuf-2.0 graphene-gobject-1.0
}

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
        case "$(uname -s)" in
            Darwin)
                JHBUILD_BIN="${ATOMOS_OVERVIEW_CHAT_UI_JHBUILD_BIN:-$JHBUILD_BIN_DEFAULT}"
                if [ -f "$MACOS_GTK_ENV_FILE" ]; then
                    # shellcheck source=/dev/null
                    source "$MACOS_GTK_ENV_FILE"
                fi
                if ! have_jhbuild_gtk4_stack "$JHBUILD_BIN" && ! have_host_gtk4_stack; then
                    if [ "${ATOMOS_OVERVIEW_CHAT_UI_BOOTSTRAP_GTK_OSX:-1}" = "1" ]; then
                        bash "$ROOT_DIR/scripts/overview-chat-ui/setup-gtk-osx.sh"
                        if [ -f "$MACOS_GTK_ENV_FILE" ]; then
                            # shellcheck source=/dev/null
                            source "$MACOS_GTK_ENV_FILE"
                        fi
                    fi
                fi
                if have_jhbuild_gtk4_stack "$JHBUILD_BIN"; then
                    exec "$JHBUILD_BIN" run cargo run \
                        --manifest-path "$CRATE_DIR/Cargo.toml" \
                        -p atomos-overview-chat-ui-app \
                        --bin atomos-overview-chat-ui
                fi
                if have_host_gtk4_stack; then
                    exec cargo run \
                        --manifest-path "$CRATE_DIR/Cargo.toml" \
                        -p atomos-overview-chat-ui-app \
                        --bin atomos-overview-chat-ui
                fi
                echo "preview (gtk): gtk4 runtime deps still unavailable on macOS." >&2
                echo "Run: bash scripts/overview-chat-ui/setup-gtk-osx.sh" >&2
                echo "Or set ATOMOS_OVERVIEW_CHAT_UI_PREVIEW=egui for logic-only preview." >&2
                exit 1
                ;;
            *)
                if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
                    echo "preview (gtk): no WAYLAND_DISPLAY or DISPLAY; start a Wayland/X11 session (e.g. GNOME on Linux) or run nested compositor." >&2
                    echo "  Force egui-only: ATOMOS_OVERVIEW_CHAT_UI_PREVIEW=egui $0" >&2
                    exit 1
                fi
                ;;
        esac
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
