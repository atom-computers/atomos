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
OVERVIEW_RUNTIME_DEFAULT="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT:-1}"
case "${PMOS_DEVICE:-}" in
    qemu-*|qemu_*)
        OVERVIEW_RUNTIME_DEFAULT=0
        ;;
esac

PMB="$ROOT_DIR/scripts/pmb/pmb.sh"
BIN_PATH="$ROOT_DIR/rust/atomos-overview-chat-ui/target/aarch64-unknown-linux-musl/release/atomos-overview-chat-ui"
REQUIRE_BINARY="${ATOMOS_OVERVIEW_CHAT_UI_REQUIRE_BINARY:-1}"
tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

if [ ! -x "$BIN_PATH" ]; then
    if [ "$REQUIRE_BINARY" = "1" ]; then
        echo "ERROR: install-overview-chat-ui: no prebuilt binary found; fail install" >&2
        echo "  expected: $BIN_PATH" >&2
        echo "  If you want launcher-only behavior, set ATOMOS_OVERVIEW_CHAT_UI_REQUIRE_BINARY=0." >&2
        exit 1
    fi
    echo "install-overview-chat-ui: no prebuilt binary found; skip install (ATOMOS_OVERVIEW_CHAT_UI_REQUIRE_BINARY=0)"
    echo "  expected: $BIN_PATH"
    exit 0
fi

reject_glibc_linked_binary() {
    [ "${ATOMOS_OVERVIEW_CHAT_UI_SKIP_MUSL_CHECK:-0}" = "1" ] && return 0
    if command -v readelf >/dev/null 2>&1; then
        local interp
        interp="$(readelf -l "$BIN_PATH" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p' | head -n 1 || true)"
        if [ -n "$interp" ] && [ "$interp" != "/lib/ld-musl-aarch64.so.1" ]; then
            echo "ERROR: binary interpreter is not musl: $interp" >&2
            echo "  Expected: /lib/ld-musl-aarch64.so.1" >&2
            echo "  Build the musl artifact: bash $ROOT_DIR/scripts/overview-chat-ui/build-overview-chat-ui.sh $PROFILE_ENV_SOURCE" >&2
            echo "  Override (not for pmOS): ATOMOS_OVERVIEW_CHAT_UI_SKIP_MUSL_CHECK=1" >&2
            exit 1
        fi
    fi
    if ! command -v file >/dev/null 2>&1; then
        echo "WARN: 'file' not installed; cannot verify binary is musl-safe for pmOS." >&2
        return 0
    fi
    local desc
    desc="$(file -b "$BIN_PATH" 2>/dev/null || true)"
    if echo "$desc" | grep -qE 'interpreter.*/lib/ld-linux|ld-linux-aarch64'; then
        echo "ERROR: binary is glibc-linked (see: file $BIN_PATH)." >&2
        echo "  Device has musl only — /lib/ld-linux-aarch64.so.1 is missing; exec shows as 'not found'." >&2
        echo "  Build the musl artifact: bash $ROOT_DIR/scripts/overview-chat-ui/build-overview-chat-ui.sh $PROFILE_ENV_SOURCE" >&2
        echo "  Expected path: .../target/aarch64-unknown-linux-musl/release/atomos-overview-chat-ui" >&2
        echo "  Override (not for pmOS): ATOMOS_OVERVIEW_CHAT_UI_SKIP_MUSL_CHECK=1" >&2
        exit 1
    fi
}

reject_glibc_linked_binary

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
# Touch-dismiss can trigger compositor/input-stack instability on some phones.
# Keep disabled by default; set to 1 to opt in.
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS:-0}"
export ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE="${ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE:-1}"
# Safety fallback: some target GTK stacks crash while parsing advanced CSS.
# Set to 0 to re-enable themed CSS after confirming target stability.
export ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS:-1}"
# QEMU/virt stacks can crash GTK4 GL renderers very early; prefer software cairo.
export GDK_BACKEND="${GDK_BACKEND:-wayland}"
export GSK_RENDERER="${ATOMOS_OVERVIEW_CHAT_UI_GSK_RENDERER:-cairo}"
export LIBGL_ALWAYS_SOFTWARE="${ATOMOS_OVERVIEW_CHAT_UI_LIBGL_ALWAYS_SOFTWARE:-1}"
# Additional safety defaults for unstable target stacks.
export ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE="${ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE:-1}"
export ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS:-1}"
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-__OVERVIEW_CHAT_UI_RUNTIME_DEFAULT__}"
# Phosh runs this as the logged-in user; /run/ is root-only. Use the session dir.
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.pid"
LOGFILE="${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.log"
DISABLE_FILE="${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.disabled"

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
    if [ -f "$DISABLE_FILE" ]; then
        logger -t atomos-overview-chat-ui "runtime disabled by marker file: $DISABLE_FILE"
        return 0
    fi
    (
        printf '%s\n' "---- $(date) ----"
        set +e
        "$BIN"
        rc=$?
        if [ "$rc" -eq 127 ]; then
            # "command not found"/loader failure class; avoid restart loops.
            : > "$DISABLE_FILE"
            logger -t atomos-overview-chat-ui "binary exec failed rc=127; wrote disable marker $DISABLE_FILE"
        fi
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
        if [ "${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-1}" != "1" ]; then
            logger -t atomos-overview-chat-ui "runtime disabled (ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME=${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-0}); skipping show"
            exit 0
        fi
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
sed -i "s/__OVERVIEW_CHAT_UI_RUNTIME_DEFAULT__/${OVERVIEW_RUNTIME_DEFAULT}/g" "$tmpdir/atomos-overview-chat-ui-launcher"

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
