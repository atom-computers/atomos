#!/usr/bin/env bash
# All-encompassing hotfix script for Phosh and custom AtomOS Rust packages.
#
# Intelligently detects changes in:
#  - Phosh C/Meson codebase (rust/phosh/phosh)
#  - Overview Chat UI (rust/atomos-overview-chat-ui)
#  - Home Background (rust/atomos-home-bg)
#  - App Switcher / App Handler (rust/atomos-app-handler)
#
# Only rebuilds and redeploys the components that have actually changed,
# or those explicitly requested via CLI arguments.
#
# Usage:
#   bash scripts/phosh/hotfix-all.sh [options] <profile-env> <ssh-target>

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_DIR="$ROOT_DIR/build/.hotfix-cache"
mkdir -p "$CACHE_DIR"

show_help() {
    echo "Usage: $0 [options] <profile-env> <ssh-target>"
    echo ""
    echo "Intelligently builds and hotfixes changed AtomOS components on a running device over SSH."
    echo "By default, it scans for modified files in each component's directory and only rebuilds"
    echo "and hotfixes those that have changed."
    echo ""
    echo "Options:"
    echo "  -h, --help        Show this help message"
    echo "  -f, --force       Force rebuild and hotfix of all components, regardless of cached status"
    echo "  --phosh           Explicitly hotfix Phosh C/Meson codebase"
    echo "  --chat-ui         Explicitly hotfix atomos-overview-chat-ui"
    echo "  --home-bg         Explicitly hotfix atomos-home-bg"
    echo "  --app-handler     Explicitly hotfix atomos-app-handler"
    echo "  --all             Explicitly hotfix all components"
    echo ""
    echo "Examples:"
    echo "  $0 config/arm64-virt.env user@127.0.0.1"
    echo "  $0 --chat-ui config/arm64-virt.env user@127.0.0.1"
}

# Returns 0 if changed or if reference file doesn't exist. Returns 1 if no files changed.
has_changes() {
    local dir="$1"
    local ref_file="$2"

    if [ ! -d "$dir" ]; then
        return 1
    fi

    if [ ! -f "$ref_file" ]; then
        return 0
    fi

    # Find if any non-ignored file is newer than ref_file
    local found
    found=$(find "$dir" \( -name target -o -name _build -o -name .git -o -name .pytest_cache -o -name __pycache__ \) -prune -o -type f -newer "$ref_file" -print | head -n 1)
    if [ -n "$found" ]; then
        return 0
    fi

    return 1
}

verify_script() {
    local name="$1"
    local path="$2"
    if [ ! -f "$path" ]; then
        echo "ERROR: Required script not found: $path" >&2
        exit 1
    fi
    if [ ! -x "$path" ]; then
        chmod +x "$path"
    fi
}

FORCE=0
RUN_PHOSH=0
RUN_CHAT_UI=0
RUN_HOME_BG=0
RUN_APP_HANDLER=0
EXPLICIT_FLAGS=0

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -f|--force)
            FORCE=1
            shift
            ;;
        --phosh)
            RUN_PHOSH=1
            EXPLICIT_FLAGS=1
            shift
            ;;
        --chat-ui)
            RUN_CHAT_UI=1
            EXPLICIT_FLAGS=1
            shift
            ;;
        --home-bg)
            RUN_HOME_BG=1
            EXPLICIT_FLAGS=1
            shift
            ;;
        --app-handler)
            RUN_APP_HANDLER=1
            EXPLICIT_FLAGS=1
            shift
            ;;
        --all)
            RUN_PHOSH=1
            RUN_CHAT_UI=1
            RUN_HOME_BG=1
            RUN_APP_HANDLER=1
            EXPLICIT_FLAGS=1
            shift
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            show_help >&2
            exit 1
            ;;
        *)
            # Stop parsing options, remaining are positional args
            break
            ;;
    esac
done

if [ "$#" -ne 2 ]; then
    echo "ERROR: Missing required positional arguments <profile-env> <ssh-target>" >&2
    show_help >&2
    exit 1
fi

PROFILE_ENV="$1"
SSH_TARGET="$2"

# Sourced profile environment to dynamically obtain PROFILE_NAME if possible
PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ -f "$PROFILE_ENV_SOURCE" ]; then
    set +e
    source "$PROFILE_ENV_SOURCE" >/dev/null 2>&1 || true
    set -e
fi

# Support extracting the port if specified in SSH_TARGET (e.g. user@host:2222)
if [[ "$SSH_TARGET" == *:* ]]; then
    HOST_PART="${SSH_TARGET%:*}"
    PORT_PART="${SSH_TARGET##*:}"
    if [[ "$PORT_PART" =~ ^[0-9]+$ ]]; then
        export ATOMOS_DEVICE_SSH_PORT="$PORT_PART"
        SSH_TARGET="$HOST_PART"
        echo "Parsed port $PORT_PART from SSH_TARGET. Setting ATOMOS_DEVICE_SSH_PORT=$PORT_PART"
    fi
fi

# Default to 22 (physical) or 2222 (virtual/QEMU forwards) if not already defined
if [ -z "${ATOMOS_DEVICE_SSH_PORT:-}" ]; then
    if [ "${PROFILE_NAME:-}" = "fairphone-fp4" ] || [ "${SSH_TARGET:-}" = "172.16.42.1" ] || [[ "${SSH_TARGET:-}" == *172.16.42.1* ]]; then
        export ATOMOS_DEVICE_SSH_PORT="22"
    else
        export ATOMOS_DEVICE_SSH_PORT="2222"
    fi
fi

# Default the SSH and sudo password to 147147 (standard pmOS install password) if not set,
# so that sshpass works seamlessly and sudo elevation succeeds on target.
export ATOMOS_DEVICE_SSHPASS="${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-147147}}"

verify_script "Phosh Hotfix" "$ROOT_DIR/scripts/phosh/hotfix-phosh.sh"
verify_script "Chat UI Hotfix" "$ROOT_DIR/scripts/overview-chat-ui/hotfix-overview-chat-ui.sh"
verify_script "Home BG Hotfix" "$ROOT_DIR/scripts/home-bg/hotfix-home-bg.sh"
verify_script "App Handler Hotfix" "$ROOT_DIR/scripts/app-handler/hotfix-app-handler.sh"



# If no explicit components specified, auto-detect changes
if [ "$EXPLICIT_FLAGS" -eq 0 ]; then
    echo "Scanning source directories for modifications..."
    
    if [ "$FORCE" -eq 1 ] || has_changes "$ROOT_DIR/rust/phosh/phosh" "$CACHE_DIR/.hotfix-phosh.time"; then
        RUN_PHOSH=1
    fi
    if [ "$FORCE" -eq 1 ] || has_changes "$ROOT_DIR/rust/atomos-overview-chat-ui" "$CACHE_DIR/.hotfix-chat-ui.time"; then
        RUN_CHAT_UI=1
    fi
    if [ "$FORCE" -eq 1 ] || has_changes "$ROOT_DIR/rust/atomos-home-bg" "$CACHE_DIR/.hotfix-home-bg.time"; then
        RUN_HOME_BG=1
    fi
    if [ "$FORCE" -eq 1 ] || has_changes "$ROOT_DIR/rust/atomos-app-handler" "$CACHE_DIR/.hotfix-app-handler.time"; then
        RUN_APP_HANDLER=1
    fi
fi

any_executed=0

run_hotfix() {
    local component_name="$1"
    local script_path="$2"
    local time_file="$3"
    
    echo ""
    echo "================================================================================"
    echo ">>> Running hotfix for: $component_name"
    echo ">>> Executing: bash $script_path $PROFILE_ENV $SSH_TARGET"
    echo "================================================================================"
    
    # Touch reference timestamp prior to build to avoid racing subsequent changes
    local tmp_ref
    tmp_ref=$(mktemp)
    
    if bash "$script_path" "$PROFILE_ENV" "$SSH_TARGET"; then
        mv "$tmp_ref" "$time_file"
        echo ">>> SUCCESS: $component_name hotfix applied successfully."
        any_executed=1
    else
        rm -f "$tmp_ref"
        echo ">>> ERROR: $component_name hotfix execution failed!" >&2
        exit 1
    fi
}

# Run updates sequentially
if [ "$RUN_PHOSH" -eq 1 ]; then
    run_hotfix "Phosh" "$ROOT_DIR/scripts/phosh/hotfix-phosh.sh" "$CACHE_DIR/.hotfix-phosh.time"
else
    echo "  Phosh is up-to-date (skipped)"
fi

if [ "$RUN_CHAT_UI" -eq 1 ]; then
    run_hotfix "Overview Chat UI" "$ROOT_DIR/scripts/overview-chat-ui/hotfix-overview-chat-ui.sh" "$CACHE_DIR/.hotfix-chat-ui.time"
else
    echo "  Overview Chat UI is up-to-date (skipped)"
fi

if [ "$RUN_HOME_BG" -eq 1 ]; then
    run_hotfix "Home Background" "$ROOT_DIR/scripts/home-bg/hotfix-home-bg.sh" "$CACHE_DIR/.hotfix-home-bg.time"
else
    echo "  Home Background is up-to-date (skipped)"
fi

if [ "$RUN_APP_HANDLER" -eq 1 ]; then
    run_hotfix "App Handler" "$ROOT_DIR/scripts/app-handler/hotfix-app-handler.sh" "$CACHE_DIR/.hotfix-app-handler.time"
else
    echo "  App Handler is up-to-date (skipped)"
fi

echo ""
echo "================================================================================"
if [ "$any_executed" -eq 1 ]; then
    echo "Hotfix run completed successfully!"
else
    echo "All components are already up-to-date. Nothing to do."
fi
echo "================================================================================"
