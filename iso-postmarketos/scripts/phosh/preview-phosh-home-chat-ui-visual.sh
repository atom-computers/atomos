#!/usr/bin/env bash
# Visual preview helper for AtomOS Phosh home chat integration.
# Runs until the window is closed by the user.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: preview-phosh-home-chat-ui-visual.sh [--skip-source-check]

Behavior:
  1) Validates Phosh home.c integration hooks (unless skipped)
  2) Launches GTK preview in a normal decorated window
  3) Stays open until you press the window close button
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKIP_SOURCE_CHECK=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-source-check)
            SKIP_SOURCE_CHECK=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ "$SKIP_SOURCE_CHECK" != "1" ]; then
    bash "$ROOT_DIR/scripts/phosh/test-phosh-home-chat-ui-local.sh"
fi

if [ "$(uname -s)" != "Darwin" ] && [ -z "${WAYLAND_DISPLAY:-}" ] && [ -z "${DISPLAY:-}" ]; then
    echo "ERROR: no WAYLAND_DISPLAY or DISPLAY; start a graphical session first." >&2
    exit 1
fi

echo "Launching visual GTK preview for manual inspection."
echo "Close the window to stop this script."

# Force a regular desktop-like window with window controls for manual visual QA.
export ATOMOS_OVERVIEW_CHAT_UI_PREVIEW=gtk
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL=0
export ATOMOS_OVERVIEW_CHAT_UI_DESKTOP_LIKE_OVERRIDE=1
export ATOMOS_OVERVIEW_CHAT_UI_EAGER_APP_GRID=1
export ATOMOS_OVERVIEW_CHAT_UI_STARTUP_TRACE="${ATOMOS_OVERVIEW_CHAT_UI_STARTUP_TRACE:-1}"
export ATOMOS_OVERVIEW_CHAT_UI_BOOTSTRAP_GTK_OSX="${ATOMOS_OVERVIEW_CHAT_UI_BOOTSTRAP_GTK_OSX:-1}"

exec bash "$ROOT_DIR/scripts/overview-chat-ui/preview-overview-chat-ui.sh"
