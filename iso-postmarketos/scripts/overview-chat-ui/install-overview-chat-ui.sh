#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE_ENV_SOURCE="$PROFILE_ENV"
DIRECT_ROOTFS_DIR="${ROOTFS_DIR:-}"

if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"
OVERVIEW_RUNTIME_DEFAULT="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT:-0}"
OVERVIEW_LAYER_SHELL_DEFAULT="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL_DEFAULT:-0}"

sed_inplace() {
    # GNU sed supports `-i`; BSD/macOS sed requires `-i ''`.
    if sed --version >/dev/null 2>&1; then
        sed -i "$1" "$2"
    else
        sed -i '' "$1" "$2"
    fi
}

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
# Default to toplevel fallback for hardware stability.
# Set ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL=1 to opt into layer-shell.
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL:-__OVERVIEW_CHAT_UI_LAYER_SHELL_DEFAULT__}"
# Touch-dismiss can trigger compositor/input-stack instability on some phones.
# Keep disabled by default; set to 1 to opt in.
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS:-0}"
# Keep visible by default while diagnosing fold/unfold lifecycle issues.
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
export ATOMOS_OVERVIEW_CHAT_UI_FORCE_TRANSPARENT_ROOT="${ATOMOS_OVERVIEW_CHAT_UI_FORCE_TRANSPARENT_ROOT:-1}"
# Lifecycle mode controls app visibility; default layer should remain visible on home.
export ATOMOS_OVERVIEW_CHAT_UI_LAYER="${ATOMOS_OVERVIEW_CHAT_UI_LAYER:-top}"
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS:-1}"
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-__OVERVIEW_CHAT_UI_RUNTIME_DEFAULT__}"
# Phosh runs this as the logged-in user; prefer session runtime dir.
PIDFILE=""
LOGFILE=""
DISABLE_FILE=""

is_running() {
    resolve_runtime_paths
    [ -f "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

resolve_runtime_paths() {
    runtime="${XDG_RUNTIME_DIR:-}"
    if [ -z "$runtime" ] || [ ! -d "$runtime" ]; then
        uid="$(id -u 2>/dev/null || true)"
        candidate="/run/user/$uid"
        if [ -n "$uid" ] && [ -d "$candidate" ]; then
            runtime="$candidate"
            export XDG_RUNTIME_DIR="$runtime"
        else
            runtime="/tmp"
            export XDG_RUNTIME_DIR="$runtime"
        fi
    fi
    PIDFILE="$runtime/atomos-overview-chat-ui.pid"
    LOGFILE="$runtime/atomos-overview-chat-ui.log"
    DISABLE_FILE="$runtime/atomos-overview-chat-ui.disabled"
}

bind_phosh_session_env_if_missing() {
    [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && return 0
    if ! command -v pgrep >/dev/null 2>&1; then
        logger -t atomos-overview-chat-ui "pgrep unavailable; cannot auto-bind Wayland env"
        return 0
    fi
    phosh_pid="$(pgrep phosh | head -n 1 || true)"
    if [ -z "$phosh_pid" ]; then
        logger -t atomos-overview-chat-ui "phosh pid not found; WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
        return 0
    fi
    env_file="/proc/$phosh_pid/environ"
    if [ ! -r "$env_file" ]; then
        logger -t atomos-overview-chat-ui "cannot read $env_file to import session env"
        return 0
    fi
    for var in WAYLAND_DISPLAY XDG_RUNTIME_DIR DISPLAY DBUS_SESSION_BUS_ADDRESS; do
        cur=""
        case "$var" in
            WAYLAND_DISPLAY) cur="${WAYLAND_DISPLAY:-}" ;;
            XDG_RUNTIME_DIR) cur="${XDG_RUNTIME_DIR:-}" ;;
            DISPLAY) cur="${DISPLAY:-}" ;;
            DBUS_SESSION_BUS_ADDRESS) cur="${DBUS_SESSION_BUS_ADDRESS:-}" ;;
        esac
        if [ -z "$cur" ]; then
            line="$(tr '\0' '\n' < "$env_file" | awk -F= -v k="$var" '$1 == k { print; exit }' || true)"
            [ -n "$line" ] && export "$line"
        fi
    done
}

start_ui() {
    resolve_runtime_paths
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
        bind_phosh_session_env_if_missing
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
sed_inplace "s/__OVERVIEW_CHAT_UI_RUNTIME_DEFAULT__/${OVERVIEW_RUNTIME_DEFAULT}/g" "$tmpdir/atomos-overview-chat-ui-launcher"
sed_inplace "s/__OVERVIEW_CHAT_UI_LAYER_SHELL_DEFAULT__/${OVERVIEW_LAYER_SHELL_DEFAULT}/g" "$tmpdir/atomos-overview-chat-ui-launcher"

INSTALL_DIRS='install -d /usr/local/bin /usr/libexec'
INSTALL_BIN_CMD='cat > /usr/local/bin/atomos-overview-chat-ui && chmod 755 /usr/local/bin/atomos-overview-chat-ui && ln -sf /usr/local/bin/atomos-overview-chat-ui /usr/bin/atomos-overview-chat-ui'
INSTALL_LAUNCHER_CMD='cat > /usr/libexec/atomos-overview-chat-ui && chmod 755 /usr/libexec/atomos-overview-chat-ui'
INSTALL_SUBMIT_CMD='cat > /usr/libexec/atomos-overview-chat-submit && chmod 755 /usr/libexec/atomos-overview-chat-submit'
VERIFY_CMD='test -x /usr/local/bin/atomos-overview-chat-ui && test -x /usr/bin/atomos-overview-chat-ui && test -x /usr/libexec/atomos-overview-chat-ui && test -x /usr/libexec/atomos-overview-chat-submit'

if [ -n "$DIRECT_ROOTFS_DIR" ]; then
    install -d "$DIRECT_ROOTFS_DIR/usr/local/bin" "$DIRECT_ROOTFS_DIR/usr/libexec"
    install -m 0755 "$BIN_PATH" "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-overview-chat-ui"
    ln -sf /usr/local/bin/atomos-overview-chat-ui "$DIRECT_ROOTFS_DIR/usr/bin/atomos-overview-chat-ui"
    install -m 0755 "$tmpdir/atomos-overview-chat-ui-launcher" "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-overview-chat-ui"
    install -m 0755 "$tmpdir/atomos-overview-chat-submit" "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-overview-chat-submit"
    test -x "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-overview-chat-ui"
    test -x "$DIRECT_ROOTFS_DIR/usr/bin/atomos-overview-chat-ui"
    test -x "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-overview-chat-ui"
    test -x "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-overview-chat-submit"
else
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_DIRS"
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_BIN_CMD" < "$BIN_PATH"
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_LAUNCHER_CMD" < "$tmpdir/atomos-overview-chat-ui-launcher"
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_SUBMIT_CMD" < "$tmpdir/atomos-overview-chat-submit"
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"
fi

echo "Installed overview chat UI binary and launch helpers."
