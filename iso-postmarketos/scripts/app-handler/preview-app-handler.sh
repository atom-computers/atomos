#!/bin/bash
# Local preview of the real atomos-app-handler binary on a Linux host with
# GTK4 + wlr-layer-shell + wlr-foreign-toplevel-management. Mirrors
# scripts/home-bg/preview-atomos-home-bg.sh in shape.
#
# Requires:
#   - pkg-config --exists gtk4 gtk4-layer-shell-0
#   - a Wayland session whose compositor speaks wlr-layer-shell
#     (phoc, sway, hyprland, river, wayfire, etc.)
#   - the compositor also advertises zwlr_foreign_toplevel_manager_v1 (sway,
#     hyprland, river, phoc all do; weston by default does not)
#
# macOS dev iteration: run scripts/app-handler/preview-app-handler-egui.sh
# instead — that runs eframe with mock toplevels.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/atomos-app-handler"

if [ "$(uname -s)" != "Linux" ]; then
    echo "preview-app-handler: only supported on Linux (needs GTK4 + layer-shell)." >&2
    echo "  For cross-platform iteration run: scripts/app-handler/preview-app-handler-egui.sh" >&2
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

for dep in gtk4 gtk4-layer-shell-0; do
    if ! pkg-config --exists "$dep"; then
        echo "missing pkg-config dep: $dep" >&2
        echo "  Alpine: apk add gtk4.0-dev gtk4-layer-shell-dev" >&2
        echo "  Debian/Ubuntu: apt install libgtk-4-dev libgtk4-layer-shell-dev" >&2
        exit 1
    fi
done

if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "preview-app-handler: no WAYLAND_DISPLAY; layer-shell requires a Wayland compositor." >&2
    exit 1
fi

export ATOMOS_APP_HANDLER_ENABLE_RUNTIME="${ATOMOS_APP_HANDLER_ENABLE_RUNTIME:-1}"

exec cargo run \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    -p atomos-app-handler-app \
    --bin atomos-app-handler
