#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_ENV_SOURCE="$PROFILE_ENV"

if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

PMB="$ROOT_DIR/scripts/pmb/pmb.sh"
BIN_PATH="$ROOT_DIR/rust/atomos-overview-chat-ui/target/aarch64-unknown-linux-musl/release/atomos-overview-chat-ui"
tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

if [ ! -x "$BIN_PATH" ]; then
    echo "install-overview-chat-ui: no prebuilt binary found; skip install"
    echo "  expected: $BIN_PATH"
    exit 0
fi

echo "Installing overview chat UI binary from: $BIN_PATH"
cat > "$tmpdir/atomos-overview-chat-submit" <<'EOF'
#!/bin/sh
set -eu
text=${1-}
logger -t atomos-overview-chat "len=${#text}"
EOF

cat > "$tmpdir/atomos-overview-chat-ui-launcher" <<'EOF'
#!/bin/sh
set -eu
BIN="/usr/local/bin/atomos-overview-chat-ui"
# Default to non-layer mode for QEMU/older compositor stability.
# Set ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL=1 to opt into layer-shell.
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL:-0}"
# Default to touch-dismiss enabled in packaged runtime; set to 0 to disable.
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS:-1}"
export ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE="${ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE:-1}"
# Phosh runs this as the logged-in user; /run/ is root-only. Use the session dir.
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.pid"
LOGFILE="${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.log"

is_running() {
    [ -f "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

start_ui() {
    if [ ! -x "$BIN" ]; then
        logger -t atomos-overview-chat-ui "binary not installed; no-op start"
        return 0
    fi
    if is_running; then
        return 0
    fi
    (
        printf '%s\n' "---- $(date) ----"
        set +e
        "$BIN"
        rc=$?
        logger -t atomos-overview-chat-ui "process-exit rc=$rc"
        exit "$rc"
    ) >>"$LOGFILE" 2>&1 &
    pid=$!
    echo "$pid" > "$PIDFILE"
    sleep 0.2
    if ! kill -0 "$pid" 2>/dev/null; then
        logger -t atomos-overview-chat-ui "exited immediately (no Wayland? from SSH: match phosh user WAYLAND_DISPLAY); log: $LOGFILE"
        rm -f "$PIDFILE"
    fi
}

stop_ui() {
    if [ "${ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE:-0}" = "1" ]; then
        logger -t atomos-overview-chat-ui "hide ignored (ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE=1)"
        return 0
    fi
    if ! is_running; then
        rm -f "$PIDFILE"
        return 0
    fi
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    kill "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
}

case "${1:-}" in
    --show)
        logger -t atomos-overview-chat-ui "action=show wayland=${WAYLAND_DISPLAY:-<unset>} runtime=${XDG_RUNTIME_DIR:-<unset>}"
        start_ui
        ;;
    --hide)
        logger -t atomos-overview-chat-ui "action=hide"
        stop_ui
        ;;
    *)
        if [ -x "$BIN" ]; then
            exec "$BIN" "$@"
        fi
        logger -t atomos-overview-chat-ui "binary not installed; no-op"
        ;;
esac
EOF

INSTALL_DIRS='install -d /usr/local/bin /usr/libexec'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_DIRS"

INSTALL_BIN_CMD='cat > /usr/local/bin/atomos-overview-chat-ui && chmod 755 /usr/local/bin/atomos-overview-chat-ui && ln -sf /usr/local/bin/atomos-overview-chat-ui /usr/bin/atomos-overview-chat-ui'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_BIN_CMD" < "$BIN_PATH"

INSTALL_LAUNCHER_CMD='cat > /usr/libexec/atomos-overview-chat-ui && chmod 755 /usr/libexec/atomos-overview-chat-ui'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_LAUNCHER_CMD" < "$tmpdir/atomos-overview-chat-ui-launcher"

INSTALL_SUBMIT_CMD='cat > /usr/libexec/atomos-overview-chat-submit && chmod 755 /usr/libexec/atomos-overview-chat-submit'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_SUBMIT_CMD" < "$tmpdir/atomos-overview-chat-submit"

VERIFY_CMD='test -x /usr/local/bin/atomos-overview-chat-ui && test -x /usr/bin/atomos-overview-chat-ui && test -x /usr/libexec/atomos-overview-chat-ui && test -x /usr/libexec/atomos-overview-chat-submit'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"

echo "Installed overview chat UI binary and launch helpers."
