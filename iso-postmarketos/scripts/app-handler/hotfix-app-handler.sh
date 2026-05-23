#!/bin/bash
# Hotfix the atomos-app-handler binary + launcher onto a running device
# over SSH. Mirrors scripts/swipe-bridge/hotfix-swipe-bridge.sh in shape.
#
# Usage:
#   bash scripts/app-handler/hotfix-app-handler.sh <profile-env> <ssh-target>
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
APP_HANDLER_RUNTIME_DEFAULT="${ATOMOS_APP_HANDLER_ENABLE_RUNTIME_DEFAULT:-1}"

if ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1 || ! command -v sshpass >/dev/null 2>&1; then
    echo "ssh, scp and sshpass are required." >&2
    exit 1
fi

SSH_PORT="${ATOMOS_DEVICE_SSH_PORT:-22}"
SSH_PASSWORD="${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-${PMOS_INSTALL_PASSWORD:-147147}}}"
SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh -p "$SSH_PORT" -o PreferredAuthentications=password -o PubkeyAuthentication=no -o KbdInteractiveAuthentication=no -o NumberOfPasswordPrompts=1)
SCP_CMD=(sshpass -p "$SSH_PASSWORD" scp -P "$SSH_PORT" -o PreferredAuthentications=password -o PubkeyAuthentication=no -o KbdInteractiveAuthentication=no -o NumberOfPasswordPrompts=1)

if [ "${ATOMOS_APP_HANDLER_SKIP_BUILD:-0}" != "1" ]; then
    bash "$ROOT_DIR/scripts/app-handler/build-app-handler.sh" "$PROFILE_ENV_SOURCE"
fi

CRATE_DIR="$ROOT_DIR/rust/atomos-app-handler"
TARGET_TRIPLE="${ATOMOS_APP_HANDLER_TARGET_TRIPLE:-aarch64-unknown-linux-musl}"
HOST_BIN="$CRATE_DIR/target/$TARGET_TRIPLE/release/atomos-app-handler"
CONTAINER_BIN="$CRATE_DIR/target/release/atomos-app-handler"
BIN_PATH="${ATOMOS_APP_HANDLER_BIN:-}"
if [ -z "$BIN_PATH" ]; then
    if [ -x "$HOST_BIN" ]; then
        BIN_PATH="$HOST_BIN"
    elif [ -x "$CONTAINER_BIN" ]; then
        BIN_PATH="$CONTAINER_BIN"
    fi
fi
if [ -z "$BIN_PATH" ] || [ ! -x "$BIN_PATH" ]; then
    echo "ERROR: binary not found. Checked:" >&2
    echo "  $HOST_BIN" >&2
    echo "  $CONTAINER_BIN" >&2
    exit 1
fi

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

cat > "$tmpdir/atomos-app-handler-launcher" <<'EOF'
#!/bin/sh
set -eu
BIN="/usr/local/bin/atomos-app-handler"
export ATOMOS_APP_HANDLER_ENABLE_RUNTIME="${ATOMOS_APP_HANDLER_ENABLE_RUNTIME:-__APP_HANDLER_RUNTIME_DEFAULT__}"
runtime="${XDG_RUNTIME_DIR:-/tmp}"
PIDFILE="$runtime/atomos-app-handler.pid"
LOGFILE="$runtime/atomos-app-handler.log"

bind_phosh_session_env_if_missing() {
    [ -n "${WAYLAND_DISPLAY:-}" ] && return 0
    phosh_pid="$(pgrep phosh | head -n 1 || true)"
    [ -n "$phosh_pid" ] || return 0
    env_file="/proc/$phosh_pid/environ"
    [ -r "$env_file" ] || return 0
    for var in WAYLAND_DISPLAY XDG_RUNTIME_DIR DISPLAY DBUS_SESSION_BUS_ADDRESS; do
        line="$(tr '\0' '\n' < "$env_file" | awk -F= -v k="$var" '$1 == k { print; exit }' || true)"
        [ -n "$line" ] && export "$line"
    done
}

is_running() {
    [ -f "$PIDFILE" ] || return 1
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

start_ui() {
    if [ "${ATOMOS_APP_HANDLER_ENABLE_RUNTIME:-0}" != "1" ]; then
        logger -t atomos-app-handler "runtime disabled; skipping start"
        return 0
    fi
    if is_running; then
        return 0
    fi
    (
        printf '%s\n' "---- $(date) ----"
        exec "$BIN"
    ) >>"$LOGFILE" 2>&1 &
    echo "$!" > "$PIDFILE"
}

stop_ui() {
    if ! is_running; then
        rm -f "$PIDFILE"
        return 0
    fi
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    kill "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
}

case "${1:-}" in
    --start|--show) bind_phosh_session_env_if_missing; start_ui ;;
    --stop|--hide) stop_ui ;;
    --restart) stop_ui; bind_phosh_session_env_if_missing; start_ui ;;
    *) exec "$BIN" "$@" ;;
esac
EOF

if sed --version >/dev/null 2>&1; then
    sed -i "s/__APP_HANDLER_RUNTIME_DEFAULT__/${APP_HANDLER_RUNTIME_DEFAULT}/g" "$tmpdir/atomos-app-handler-launcher"
else
    sed -i '' "s/__APP_HANDLER_RUNTIME_DEFAULT__/${APP_HANDLER_RUNTIME_DEFAULT}/g" "$tmpdir/atomos-app-handler-launcher"
fi

REMOTE_TMP="/tmp/atomos-app-handler-hotfix.$$"
REMOTE_SUDO="${ATOMOS_APP_HANDLER_REMOTE_SUDO:-sudo}"
REMOTE_SUDO_PASSWORD="${ATOMOS_APP_HANDLER_REMOTE_SUDO_PASSWORD:-$SSH_PASSWORD}"

echo "Uploading app-switcher hotfix to $SSH_TARGET ..."
"${SSH_CMD[@]}" "$SSH_TARGET" "mkdir -p '$REMOTE_TMP'"
"${SCP_CMD[@]}" "$BIN_PATH" "$tmpdir/atomos-app-handler-launcher" "$SSH_TARGET:$REMOTE_TMP/"

REMOTE_SCRIPT=$(cat <<'EOF'
set -eu
install -d /usr/local/bin /usr/libexec
install -m 755 "__REMOTE_TMP__/atomos-app-handler" /usr/local/bin/atomos-app-handler
install -m 755 "__REMOTE_TMP__/atomos-app-handler-launcher" /usr/libexec/atomos-app-handler
/usr/libexec/atomos-app-handler --restart || true
rm -rf "__REMOTE_TMP__"
EOF
)
REMOTE_SCRIPT="${REMOTE_SCRIPT//__REMOTE_TMP__/$REMOTE_TMP}"

if [ -n "$REMOTE_SUDO" ]; then
    "${SSH_CMD[@]}" "$SSH_TARGET" "printf '%s\n' '$REMOTE_SUDO_PASSWORD' | $REMOTE_SUDO -S -p '' -k -- /bin/sh -eu" <<<"$REMOTE_SCRIPT"
else
    "${SSH_CMD[@]}" "$SSH_TARGET" "/bin/sh -eu" <<<"$REMOTE_SCRIPT"
fi

echo "App-switcher hotfix applied."
