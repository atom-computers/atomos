#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <profile-env> <ssh-target>" >&2
    exit 1
fi

PROFILE_ENV="$1"
SSH_TARGET="$2"
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

if ! command -v ssh >/dev/null 2>&1; then
    echo "ssh is required." >&2
    exit 1
fi
if ! command -v scp >/dev/null 2>&1; then
    echo "scp is required." >&2
    exit 1
fi

SSH_CMD=(ssh)
SCP_CMD=(scp)
SSH_PASSWORD="${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-${PMOS_INSTALL_PASSWORD:-147147}}}"
SSH_PORT="${ATOMOS_DEVICE_SSH_PORT:-22}"
if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass is required." >&2
    exit 1
fi
SSH_AUTH_OPTS=(
    -p "$SSH_PORT"
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o NumberOfPasswordPrompts=1
)
SCP_AUTH_OPTS=(
    -P "$SSH_PORT"
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o NumberOfPasswordPrompts=1
)
SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh "${SSH_AUTH_OPTS[@]}")
SCP_CMD=(sshpass -p "$SSH_PASSWORD" scp "${SCP_AUTH_OPTS[@]}")

BIN_PATH=""
SKIP_BIN_INSTALL="${ATOMOS_OVERVIEW_CHAT_UI_SKIP_BIN_INSTALL:-0}"
FALLBACK_LAUNCHER_ONLY_ON_BUILD_FAIL="${ATOMOS_OVERVIEW_CHAT_UI_FALLBACK_LAUNCHER_ONLY_ON_BUILD_FAIL:-1}"
resolve_bin_path() {
    if [ -n "${ATOMOS_OVERVIEW_CHAT_UI_BIN:-}" ] && [ -x "${ATOMOS_OVERVIEW_CHAT_UI_BIN}" ]; then
        BIN_PATH="${ATOMOS_OVERVIEW_CHAT_UI_BIN}"
    elif [ -x "$ROOT_DIR/rust/atomos-overview-chat-ui/target/aarch64-unknown-linux-musl/release/atomos-overview-chat-ui" ]; then
        BIN_PATH="$ROOT_DIR/rust/atomos-overview-chat-ui/target/aarch64-unknown-linux-musl/release/atomos-overview-chat-ui"
    elif [ -x "$ROOT_DIR/rust/atomos-overview-chat-ui/target/release/atomos-overview-chat-ui" ]; then
        BIN_PATH="$ROOT_DIR/rust/atomos-overview-chat-ui/target/release/atomos-overview-chat-ui"
    else
        BIN_PATH=""
    fi
}

# pmOS rootfs is musl-only: there is no /lib/ld-linux-aarch64.so.1. A glibc-linked
# AArch64 binary exec-fails with ENOENT; BusyBox ash reports "not found".
reject_glibc_linked_binary() {
    [ "${ATOMOS_OVERVIEW_CHAT_UI_SKIP_MUSL_CHECK:-0}" = "1" ] && return 0
    local bin="$1"
    if command -v readelf >/dev/null 2>&1; then
        local interp
        interp="$(readelf -l "$bin" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p' | head -n 1 || true)"
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
    desc="$(file -b "$bin" 2>/dev/null || true)"
    if echo "$desc" | grep -qE 'interpreter.*/lib/ld-linux|ld-linux-aarch64'; then
        echo "ERROR: binary is glibc-linked (see: file $bin)." >&2
        echo "  Device has musl only — /lib/ld-linux-aarch64.so.1 is missing; exec shows as 'not found'." >&2
        echo "  Build the musl artifact: bash $ROOT_DIR/scripts/overview-chat-ui/build-overview-chat-ui.sh $PROFILE_ENV_SOURCE" >&2
        echo "  Expected path: .../target/aarch64-unknown-linux-musl/release/atomos-overview-chat-ui" >&2
        echo "  Override (not for pmOS): ATOMOS_OVERVIEW_CHAT_UI_SKIP_MUSL_CHECK=1" >&2
        exit 1
    fi
}

echo "Building overview chat UI for hotfix..."
resolve_bin_path
if [ "$SKIP_BIN_INSTALL" = "1" ]; then
    echo "Skipping binary upload/install (ATOMOS_OVERVIEW_CHAT_UI_SKIP_BIN_INSTALL=1); launcher/scripts only."
else
    if [ "${ATOMOS_OVERVIEW_CHAT_UI_SKIP_BUILD:-0}" = "1" ]; then
        if [ -z "$BIN_PATH" ]; then
            echo "ERROR: skip-build enabled but no binary found." >&2
            echo "  Set ATOMOS_OVERVIEW_CHAT_UI_BIN=<path> or build once first." >&2
            exit 1
        fi
        echo "Skipping build (ATOMOS_OVERVIEW_CHAT_UI_SKIP_BUILD=1); using: $BIN_PATH"
    else
        if bash "$ROOT_DIR/scripts/overview-chat-ui/build-overview-chat-ui.sh" "$PROFILE_ENV_SOURCE"; then
            resolve_bin_path
            if [ -z "$BIN_PATH" ]; then
                echo "ERROR: built binary not found; set ATOMOS_OVERVIEW_CHAT_UI_BIN if needed." >&2
                exit 1
            fi
        else
            if [ "$FALLBACK_LAUNCHER_ONLY_ON_BUILD_FAIL" = "1" ]; then
                echo "WARN: build failed; falling back to launcher-only hotfix." >&2
                echo "  Set ATOMOS_OVERVIEW_CHAT_UI_FALLBACK_LAUNCHER_ONLY_ON_BUILD_FAIL=0 to disable this fallback." >&2
                SKIP_BIN_INSTALL=1
            else
                exit 1
            fi
        fi
    fi
    if [ "$SKIP_BIN_INSTALL" != "1" ]; then
        reject_glibc_linked_binary "$BIN_PATH"
    fi
fi

REMOTE_TMP_DIR="${ATOMOS_OVERVIEW_CHAT_UI_REMOTE_TMP:-/tmp/atomos-overview-chat-ui-hotfix.$$}"
REMOTE_SUDO="${ATOMOS_OVERVIEW_CHAT_UI_REMOTE_SUDO:-sudo}"
REMOTE_SUDO_PASSWORD="${ATOMOS_OVERVIEW_CHAT_UI_REMOTE_SUDO_PASSWORD:-$SSH_PASSWORD}"
# BusyBox/proc comm name can be truncated, making `pkill -x atomos-overview-chat-ui`
# a no-op. Match by executable path. Use [a] to avoid matching the restart shell's
# own command line, which can terminate the installer with SIGTERM (exit 143).
REMOTE_RESTART_CMD="${ATOMOS_OVERVIEW_CHAT_UI_RESTART_CMD:-pkill -f /usr/local/bin/[a]tomos-overview-chat-ui || true}"

tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

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

if [ "$SKIP_BIN_INSTALL" != "1" ]; then
    cp "$BIN_PATH" "$tmpdir/atomos-overview-chat-ui-bin"
fi
chmod 755 "$tmpdir/atomos-overview-chat-submit" "$tmpdir/atomos-overview-chat-ui-launcher"
if [ "$SKIP_BIN_INSTALL" != "1" ]; then
    chmod 755 "$tmpdir/atomos-overview-chat-ui-bin"
fi

echo "Uploading hotfix payload to $SSH_TARGET:$REMOTE_TMP_DIR ..."
"${SSH_CMD[@]}" "$SSH_TARGET" "mkdir -p '$REMOTE_TMP_DIR'"
if [ "$SKIP_BIN_INSTALL" = "1" ]; then
    "${SCP_CMD[@]}" \
        "$tmpdir/atomos-overview-chat-ui-launcher" \
        "$tmpdir/atomos-overview-chat-submit" \
        "$SSH_TARGET:$REMOTE_TMP_DIR/"
else
    "${SCP_CMD[@]}" \
        "$tmpdir/atomos-overview-chat-ui-bin" \
        "$tmpdir/atomos-overview-chat-ui-launcher" \
        "$tmpdir/atomos-overview-chat-submit" \
        "$SSH_TARGET:$REMOTE_TMP_DIR/"
fi

shell_quote_sq() {
    local s="$1"
    printf "'%s'" "${s//\'/\'\\\'\'}"
}
REMOTE_TMP_DIR_Q="$(shell_quote_sq "$REMOTE_TMP_DIR")"
REMOTE_RESTART_CMD_Q="$(shell_quote_sq "$REMOTE_RESTART_CMD")"
SKIP_BIN_INSTALL_Q="$(shell_quote_sq "$SKIP_BIN_INSTALL")"

REMOTE_INSTALL_SCRIPT="$(cat <<EOF
set -eu
REMOTE_TMP_DIR=${REMOTE_TMP_DIR_Q}
REMOTE_RESTART_CMD=${REMOTE_RESTART_CMD_Q}
SKIP_BIN_INSTALL=${SKIP_BIN_INSTALL_Q}

install -d /usr/local/bin /usr/libexec
install -m 755 "$REMOTE_TMP_DIR/atomos-overview-chat-ui-launcher" /usr/libexec/atomos-overview-chat-ui
install -m 755 "$REMOTE_TMP_DIR/atomos-overview-chat-submit" /usr/libexec/atomos-overview-chat-submit
if [ "$SKIP_BIN_INSTALL" != "1" ]; then
    install -m 755 "$REMOTE_TMP_DIR/atomos-overview-chat-ui-bin" /usr/local/bin/atomos-overview-chat-ui
    ln -sf /usr/local/bin/atomos-overview-chat-ui /usr/bin/atomos-overview-chat-ui
fi

if [ -n "$REMOTE_RESTART_CMD" ]; then
    /bin/sh -eu -c "$REMOTE_RESTART_CMD"
fi

rm -rf "$REMOTE_TMP_DIR"
EOF
)"

REMOTE_INSTALL_BASENAME="atomos-overview-chat-ui-install.sh"
REMOTE_INSTALL_PATH="$tmpdir/$REMOTE_INSTALL_BASENAME"
printf '%s\n' "$REMOTE_INSTALL_SCRIPT" > "$REMOTE_INSTALL_PATH"
chmod 700 "$REMOTE_INSTALL_PATH"

echo "Installing hotfix payload on device..."
install_rc=0
if [ -n "$REMOTE_SUDO" ]; then
    if [ -n "${REMOTE_SUDO_PASSWORD:-}" ]; then
        if [ "$SKIP_BIN_INSTALL" = "1" ]; then
            "${SCP_CMD[@]}" "$REMOTE_INSTALL_PATH" "$SSH_TARGET:$REMOTE_TMP_DIR/$REMOTE_INSTALL_BASENAME"
        else
            "${SCP_CMD[@]}" "$REMOTE_INSTALL_PATH" "$SSH_TARGET:$REMOTE_TMP_DIR/$REMOTE_INSTALL_BASENAME"
        fi
        "${SSH_CMD[@]}" "$SSH_TARGET" "printf '%s\n' $(shell_quote_sq "$REMOTE_SUDO_PASSWORD") | $REMOTE_SUDO -S -p '' -k -- /bin/sh -eu '$REMOTE_TMP_DIR/$REMOTE_INSTALL_BASENAME'" || install_rc=$?
    else
        if [ "$SKIP_BIN_INSTALL" = "1" ]; then
            "${SCP_CMD[@]}" "$REMOTE_INSTALL_PATH" "$SSH_TARGET:$REMOTE_TMP_DIR/$REMOTE_INSTALL_BASENAME"
        else
            "${SCP_CMD[@]}" "$REMOTE_INSTALL_PATH" "$SSH_TARGET:$REMOTE_TMP_DIR/$REMOTE_INSTALL_BASENAME"
        fi
        "${SSH_CMD[@]}" "$SSH_TARGET" "$REMOTE_SUDO" -- /bin/sh -eu "$REMOTE_TMP_DIR/$REMOTE_INSTALL_BASENAME" || install_rc=$?
    fi
else
    if [ "$SKIP_BIN_INSTALL" = "1" ]; then
        "${SCP_CMD[@]}" "$REMOTE_INSTALL_PATH" "$SSH_TARGET:$REMOTE_TMP_DIR/$REMOTE_INSTALL_BASENAME"
    else
        "${SCP_CMD[@]}" "$REMOTE_INSTALL_PATH" "$SSH_TARGET:$REMOTE_TMP_DIR/$REMOTE_INSTALL_BASENAME"
    fi
    "${SSH_CMD[@]}" "$SSH_TARGET" /bin/sh -eu "$REMOTE_TMP_DIR/$REMOTE_INSTALL_BASENAME" || install_rc=$?
fi

if [ "$install_rc" -ne 0 ]; then
    echo "ERROR: remote install failed (exit $install_rc)." >&2
    echo "  Verify remote sudo password. If it differs from SSH password, set:" >&2
    echo "  ATOMOS_OVERVIEW_CHAT_UI_REMOTE_SUDO_PASSWORD='<actual-sudo-password>'" >&2
    exit "$install_rc"
fi

echo "Hotfix applied."
