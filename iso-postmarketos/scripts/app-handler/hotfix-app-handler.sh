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
# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/app-handler/_lib-remote-elevate.sh"
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

SSH_PORT="${ATOMOS_DEVICE_SSH_PORT:-2222}"
SSH_PASSWORD="${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-${PMOS_INSTALL_PASSWORD:-147147}}}"
SSH_OPTS=(
    -p "$SSH_PORT"
    -o PreferredAuthentications=password
    -o PubkeyAuthentication=no
    -o KbdInteractiveAuthentication=no
    -o NumberOfPasswordPrompts=1
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
)
SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh "${SSH_OPTS[@]}")
SCP_CMD=(sshpass -p "$SSH_PASSWORD" scp -P "$SSH_PORT" \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR)

bin_has_console_launch_fix() {
    local bin="$1"
    local blob
    command -v strings >/dev/null 2>&1 || return 1
    blob="$(strings "$bin" 2>/dev/null || true)"
    [[ "$blob" == *"syncing session env to dbus activation"* ]] \
        && [[ "$blob" == *"spawning dbus service exec"* ]]
}

if [ "${ATOMOS_APP_HANDLER_SKIP_BUILD:-0}" != "1" ]; then
    bash "$ROOT_DIR/scripts/app-handler/build-app-handler.sh" "$PROFILE_ENV_SOURCE"
fi

CRATE_DIR="$ROOT_DIR/rust/atomos-app-handler"
TARGET_TRIPLE="${ATOMOS_APP_HANDLER_TARGET_TRIPLE:-aarch64-unknown-linux-musl}"
HOST_BIN="$CRATE_DIR/target/$TARGET_TRIPLE/release/atomos-app-handler"
CONTAINER_BIN="$CRATE_DIR/target/release/atomos-app-handler"
BIN_PATH="${ATOMOS_APP_HANDLER_BIN:-}"
if [ -z "$BIN_PATH" ]; then
    # Prefer the artifact that actually contains the Console launch fix. On macOS
    # the container build (target/release/) is authoritative; a stale cross
    # target/$TARGET_TRIPLE/ binary must not win.
    for candidate in "$CONTAINER_BIN" "$HOST_BIN"; do
        [ -x "$candidate" ] || continue
        if bin_has_console_launch_fix "$candidate"; then
            BIN_PATH="$candidate"
            break
        fi
    done
    if [ -z "$BIN_PATH" ]; then
        if [ "$(uname -s)" = "Darwin" ] && [ -x "$CONTAINER_BIN" ]; then
            BIN_PATH="$CONTAINER_BIN"
        elif [ -x "$HOST_BIN" ]; then
            BIN_PATH="$HOST_BIN"
        elif [ -x "$CONTAINER_BIN" ]; then
            BIN_PATH="$CONTAINER_BIN"
        fi
    fi
fi
if [ -z "$BIN_PATH" ] || [ ! -x "$BIN_PATH" ]; then
    echo "ERROR: binary not found. Checked:" >&2
    echo "  $HOST_BIN" >&2
    echo "  $CONTAINER_BIN" >&2
    exit 1
fi
if ! bin_has_console_launch_fix "$BIN_PATH"; then
    echo "ERROR: selected binary lacks Console launch fix strings:" >&2
    echo "  $BIN_PATH" >&2
    echo "  Re-run without ATOMOS_APP_HANDLER_SKIP_BUILD=1, or set ATOMOS_APP_HANDLER_BIN to a fresh build." >&2
    exit 1
fi
echo "Using app-handler binary: $BIN_PATH"

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
REMOTE_SUDO_PASSWORD="${ATOMOS_APP_HANDLER_REMOTE_SUDO_PASSWORD:-$SSH_PASSWORD}"

echo "Uploading app-switcher hotfix to $SSH_TARGET (port $SSH_PORT) ..."
if ! "${SSH_CMD[@]}" "$SSH_TARGET" "mkdir -p '$REMOTE_TMP'"; then
    echo "ERROR: SSH to $SSH_TARGET:$SSH_PORT failed (is QEMU running?)" >&2
    exit 1
fi
if ! "${SCP_CMD[@]}" "$BIN_PATH" "$tmpdir/atomos-app-handler-launcher" "$SSH_TARGET:$REMOTE_TMP/"; then
    echo "ERROR: SCP upload to $SSH_TARGET:$SSH_PORT failed" >&2
    exit 1
fi

cat > "$tmpdir/remote-install.sh" <<'REMOTE_EOF'
set -eu
install -d /usr/local/bin /usr/libexec
install -m 755 "__REMOTE_TMP__/atomos-app-handler" /usr/local/bin/atomos-app-handler
install -m 755 "__REMOTE_TMP__/atomos-app-handler-launcher" /usr/libexec/atomos-app-handler

# Stop every running instance. The pidfile can be stale after a crash, and
# --restart alone leaves the old GTK main loop alive (you keep seeing
# handle_strip / surface_height_px=224 in the log even though /usr/local/bin
# was updated).
/usr/libexec/atomos-app-handler --stop 2>/dev/null || true
for pid in $(pgrep -f '/usr/local/bin/atomos-app-handler' 2>/dev/null || true); do
    kill "$pid" 2>/dev/null || true
done
sleep 1
for pid in $(pgrep -f '/usr/local/bin/atomos-app-handler' 2>/dev/null || true); do
    kill -9 "$pid" 2>/dev/null || true
done
rm -f /run/user/*/atomos-app-handler.pid 2>/dev/null || true

/usr/libexec/atomos-app-handler --start
sleep 1
if ! pgrep -f '/usr/local/bin/atomos-app-handler' >/dev/null 2>&1; then
    echo "ERROR: atomos-app-handler failed to start after hotfix" >&2
    exit 1
fi

if command -v strings >/dev/null 2>&1; then
    if strings /usr/local/bin/atomos-app-handler 2>/dev/null | grep -F 'syncing session env to dbus activation' >/dev/null 2>&1; then
        echo "OK: installed binary contains dbus activation env sync (Console fix)"
    else
        echo "ERROR: installed binary missing dbus activation env sync trace" >&2
        exit 1
    fi
    if strings /usr/local/bin/atomos-app-handler 2>/dev/null | grep -F 'dbus activatable spawning desktop Exec' >/dev/null 2>&1 \
        || strings /usr/local/bin/atomos-app-handler 2>/dev/null | grep -F 'dbus activatable via launch_uris_as_manager' >/dev/null 2>&1 \
        || strings /usr/local/bin/atomos-app-handler 2>/dev/null | grep -F 'spawning dbus service exec' >/dev/null 2>&1; then
        echo "OK: installed binary contains dbus launch path (desktop Exec, launch_uris_as_manager, or service exec fallback)"
    else
        echo "ERROR: installed binary missing dbus service exec spawn trace" >&2
        exit 1
    fi
else
    echo "WARN: strings(1) not installed; skipping binary fingerprint check"
fi

rm -rf "__REMOTE_TMP__"
REMOTE_EOF
REMOTE_SCRIPT=$(cat "$tmpdir/remote-install.sh")
REMOTE_SCRIPT="${REMOTE_SCRIPT//__REMOTE_TMP__/$REMOTE_TMP}"

if ! atomos_remote_run_elevated "$SSH_TARGET" "$REMOTE_SCRIPT"; then
    echo "ERROR: remote hotfix install/restart failed (check sudo / doas / SSH)." >&2
    exit 1
fi

echo "App-switcher hotfix applied and restarted."
echo "  Verify: ATOMOS_DEVICE_SSH_PORT=$SSH_PORT ATOMOS_DIAGNOSE_LAUNCH_TEST_APP_ID=org.gnome.Console.desktop bash scripts/app-handler/diagnose-app-launch.sh <profile-env> $SSH_TARGET"
