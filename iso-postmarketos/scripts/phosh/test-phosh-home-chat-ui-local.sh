#!/usr/bin/env bash
# Validate AtomOS chat/app-grid integration in local Phosh fork.
#
# Default mode performs fast source-contract checks only.
# Optional --build mode runs a local meson compile (Linux host with deps).
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: test-phosh-home-chat-ui-local.sh [--build] [--phosh-dir <path>] [--build-dir <path>]

Modes:
  default     Source contract checks in src/home.c (fast, no toolchain needed)
  --build     Also run meson setup/compile for local Phosh tree

Options:
  --phosh-dir PATH   Override phosh checkout (default: iso-postmarketos/rust/phosh/phosh)
  --build-dir PATH   Meson build directory (default: <phosh-dir>/_build-atomos-home-chat)
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PHOSH_DIR="${ATOMOS_PHOSH_SRC:-$ROOT_DIR/rust/phosh/phosh}"
BUILD_MODE=0
BUILD_DIR=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --build)
            BUILD_MODE=1
            ;;
        --phosh-dir)
            shift
            [ "$#" -gt 0 ] || { echo "ERROR: --phosh-dir requires a value" >&2; exit 2; }
            PHOSH_DIR="$1"
            ;;
        --build-dir)
            shift
            [ "$#" -gt 0 ] || { echo "ERROR: --build-dir requires a value" >&2; exit 2; }
            BUILD_DIR="$1"
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

HOME_C="$PHOSH_DIR/src/home.c"
if [ ! -f "$HOME_C" ]; then
    echo "ERROR: missing $HOME_C" >&2
    exit 1
fi
TOP_PANEL_C="$PHOSH_DIR/src/top-panel.c"
if [ ! -f "$TOP_PANEL_C" ]; then
    echo "ERROR: missing $TOP_PANEL_C" >&2
    exit 1
fi

if [ -z "$BUILD_DIR" ]; then
    BUILD_DIR="$PHOSH_DIR/_build-atomos-home-chat"
fi

echo "=== Phosh home chat UI source checks ==="
echo "phosh_dir=$PHOSH_DIR"

require_pattern() {
    local pattern="$1"
    local label="$2"
    if rg -n "$pattern" "$HOME_C" >/dev/null; then
        echo "PASS: $label"
    else
        echo "FAIL: $label (missing pattern: $pattern)" >&2
        exit 1
    fi
}

require_pattern "ATOMOS_CHAT_SUBMIT_PATH" "submit path constant present"
require_pattern "on_chat_entry_activate" "chat entry activate callback present"
require_pattern "on_app_grid_toggle_clicked" "app-grid toggle callback present"
require_pattern "atomos-overview-chat-submit" "chat submit launcher path wired"
require_pattern "gtk_widget_set_visible \\(GTK_WIDGET \\(app_grid\\), FALSE\\);" "app grid starts hidden"
require_pattern "Ask AtomOS" "chat placeholder text present"
require_pattern "last_reference_height" "configure-height fallback state tracked"
require_pattern "reference_height_for_margin \\(PhoshHome \\*self, gint configured_height\\)" "margin reference helper uses home state"
require_pattern "phosh_overview_has_running_activities" "home drag-mode follows vendor running-activities gate"
require_pattern "handle = PHOSH_HOME_BAR_HEIGHT;" "failed coordinate path falls back to home bar handle"
require_pattern "on_chat_dismiss_tap_pressed" "outside-tap dismiss callback present"
require_pattern "gtk_window_set_focus \\(GTK_WINDOW \\(self\\), NULL\\);" "outside-tap dismiss clears focus"
require_pattern "static gboolean enabled = TRUE;" "app-grid toggle defaults enabled"
require_pattern "enabled = g_strcmp0 \\(env, \"0\"\\) != 0;" "app-grid toggle supports explicit env opt-out"
require_pattern "phosh_home_set_state \\(self, !self->state\\);" "mouse click on home bar toggles fold/unfold (vendor parity)"
require_pattern "switcher: tapping an activity card must dismiss the overview" "fold_cb always folds for switcher (vendor parity)"
require_pattern "\"exclusive-zone\", 0" "home surface overlays app content (no reserved bottom strip)"
require_pattern "\"exclusive\", 0" "home drag-surface exclusive area disabled"
require_pattern "\"drag-mode\", PHOSH_DRAG_SURFACE_DRAG_MODE_HANDLE" "home drag-mode enables phoc swipe-up"
require_pattern "#define PHOSH_HOME_DRAG_THRESHOLD 0.0" "home swipe drag claims immediately (no motion threshold)"
require_pattern "ATOMOS_APP_HANDLER_LAUNCHER_PATH" "home exposes app-handler launcher path"
require_pattern "atomos_phosh_sync_app_handler_lifecycle" "home syncs app-handler lifecycle with home state"
require_pattern "action = \"--hide\"" "home requests app-handler --hide on fold"
require_pattern "Do NOT --show on unfold" "home must not open switcher overlay on unfold"
require_pattern "ATOMOS_HOME_BG_LAUNCHER_PATH" "home-bg launcher path wired"
require_pattern "atomos_phosh_sync_home_bg_layer" "home promotes home-bg layer on overview unfold"
require_pattern 'layer = "top"' "overview unfold uses home-bg top layer"
require_pattern 'layer = "bottom"' "overview fold restores home-bg bottom layer"
require_pattern "atomos_phosh_sync_overview_chat_ui_lifecycle" "home syncs overview-chat-ui layer with home state"
require_pattern "ATOMOS_OVERVIEW_CHAT_UI_LAYER=%s %s --show" "overview chat uses layer-prefixed --show"
require_pattern 'layer = "overlay"' "overview unfold uses chat overlay layer (above phosh-home TOP)"
require_pattern "phosh_shell_get_locked" "overview chat hides while session locked"
require_pattern 'layer = "bottom"' "overview fold demotes chat to bottom layer"

if rg -n "\"drag-mode\", PHOSH_DRAG_SURFACE_DRAG_MODE_HANDLE" "$TOP_PANEL_C" >/dev/null; then
    echo "PASS: top-panel drag-mode enables phoc swipe-down"
else
    echo "FAIL: top-panel drag-mode enables phoc swipe-down (missing pattern)" >&2
    exit 1
fi

echo "PASS: source contract checks complete"

if [ "$BUILD_MODE" != "1" ]; then
    echo "INFO: skipping meson compile (enable with --build)"
    exit 0
fi

echo
echo "=== Phosh meson compile check ==="
if [ "$(uname -s)" != "Linux" ]; then
    echo "ERROR: --build is supported on Linux hosts only." >&2
    exit 2
fi

if ! command -v meson >/dev/null 2>&1; then
    echo "ERROR: meson not found (install meson + ninja + phosh build deps)." >&2
    exit 1
fi

if ! command -v ninja >/dev/null 2>&1; then
    echo "ERROR: ninja not found (install ninja-build)." >&2
    exit 1
fi

if [ ! -d "$BUILD_DIR" ]; then
    meson setup "$BUILD_DIR" "$PHOSH_DIR"
else
    meson setup --reconfigure "$BUILD_DIR" "$PHOSH_DIR"
fi

meson compile -C "$BUILD_DIR"
echo "PASS: meson compile completed"
