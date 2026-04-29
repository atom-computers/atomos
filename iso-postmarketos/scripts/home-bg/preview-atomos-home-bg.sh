#!/bin/bash
# Local preview of atomos-home-bg on a Linux host with a GTK4/WebKitGTK 6
# desktop session. Requires:
#   - pkg-config --exists gtk4 gtk4-layer-shell-0 webkitgtk-6.0
#   - a Wayland session whose compositor speaks wlr-layer-shell
#     (phoc, sway, hyprland, river, wayfire, weston with the protocol, etc.)
#
# macOS is intentionally unsupported: webkit2gtk-6.0 is a Linux-only runtime.
# For logic-only iteration on macOS run: cargo test -p atomos-home-bg
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/atomos-home-bg"

if [ "$(uname -s)" != "Linux" ]; then
    echo "preview-atomos-home-bg: only supported on Linux (needs GTK4 + webkit2gtk-6.0)." >&2
    echo "  For cross-platform logic tests run: cargo test -p atomos-home-bg" >&2
    exit 1
fi

if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo is required." >&2
    exit 1
fi

if ! command -v pkg-config >/dev/null 2>&1; then
    echo "pkg-config is required." >&2
    exit 1
fi

for dep in gtk4 gtk4-layer-shell-0 webkitgtk-6.0; do
    if ! pkg-config --exists "$dep"; then
        echo "missing pkg-config dep: $dep" >&2
        echo "  Alpine: apk add gtk4.0-dev gtk4-layer-shell-dev webkit2gtk-6.0-dev" >&2
        echo "  Debian/Ubuntu: apt install libgtk-4-dev libgtk4-layer-shell-dev libwebkitgtk-6.0-dev" >&2
        exit 1
    fi
done

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "preview-atomos-home-bg: no WAYLAND_DISPLAY; layer-shell requires a Wayland compositor." >&2
    echo "  Start phosh/sway/etc. and re-run, or set WAYLAND_DISPLAY explicitly." >&2
    exit 1
fi

export ATOMOS_HOME_BG_ENABLE_RUNTIME="${ATOMOS_HOME_BG_ENABLE_RUNTIME:-1}"
export ATOMOS_HOME_BG_LAYER="${ATOMOS_HOME_BG_LAYER:-bottom}"
export ATOMOS_HOME_BG_INTERACTIVE="${ATOMOS_HOME_BG_INTERACTIVE:-0}"

if [ -z "${ATOMOS_HOME_BG_URL:-}" ]; then
    export ATOMOS_HOME_BG_URL="file://$ROOT_DIR/data/atomos-home-bg/index.html"
fi

exec cargo run \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    -p atomos-home-bg-app \
    --bin atomos-home-bg
