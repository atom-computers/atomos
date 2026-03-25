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

if ! command -v ssh >/dev/null 2>&1; then
    echo "ssh is required." >&2
    exit 1
fi
if ! command -v scp >/dev/null 2>&1; then
    echo "scp is required." >&2
    exit 1
fi

BIN_PATH=""
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
bash "$ROOT_DIR/scripts/overview-chat-ui/build-overview-chat-ui.sh" "$PROFILE_ENV_SOURCE"
resolve_bin_path
if [ -z "$BIN_PATH" ]; then
    echo "ERROR: built binary not found; set ATOMOS_OVERVIEW_CHAT_UI_BIN if needed." >&2
    exit 1
fi
reject_glibc_linked_binary "$BIN_PATH"

REMOTE_TMP_DIR="${ATOMOS_OVERVIEW_CHAT_UI_REMOTE_TMP:-/tmp/atomos-overview-chat-ui-hotfix.$$}"
REMOTE_SUDO="${ATOMOS_OVERVIEW_CHAT_UI_REMOTE_SUDO:-sudo}"
REMOTE_RESTART_CMD="${ATOMOS_OVERVIEW_CHAT_UI_RESTART_CMD:-pkill -x atomos-overview-chat-ui || true}"

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
PIDFILE="/run/atomos-overview-chat-ui.pid"

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
    "$BIN" >/dev/null 2>&1 &
    echo "$!" > "$PIDFILE"
}

stop_ui() {
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
        start_ui
        ;;
    --hide)
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

cp "$BIN_PATH" "$tmpdir/atomos-overview-chat-ui-bin"
chmod 755 "$tmpdir/atomos-overview-chat-submit" "$tmpdir/atomos-overview-chat-ui-launcher" "$tmpdir/atomos-overview-chat-ui-bin"

echo "Uploading hotfix payload to $SSH_TARGET:$REMOTE_TMP_DIR ..."
ssh "$SSH_TARGET" "mkdir -p '$REMOTE_TMP_DIR'"
scp \
    "$tmpdir/atomos-overview-chat-ui-bin" \
    "$tmpdir/atomos-overview-chat-ui-launcher" \
    "$tmpdir/atomos-overview-chat-submit" \
    "$SSH_TARGET:$REMOTE_TMP_DIR/"

REMOTE_INSTALL_SCRIPT="$(cat <<'EOF'
set -eu
REMOTE_TMP_DIR="$1"
REMOTE_RESTART_CMD="$2"

install -d /usr/local/bin /usr/libexec
install -m 755 "$REMOTE_TMP_DIR/atomos-overview-chat-ui-launcher" /usr/libexec/atomos-overview-chat-ui
install -m 755 "$REMOTE_TMP_DIR/atomos-overview-chat-submit" /usr/libexec/atomos-overview-chat-submit
install -m 755 "$REMOTE_TMP_DIR/atomos-overview-chat-ui-bin" /usr/local/bin/atomos-overview-chat-ui
ln -sf /usr/local/bin/atomos-overview-chat-ui /usr/bin/atomos-overview-chat-ui

if [ -n "$REMOTE_RESTART_CMD" ]; then
    /bin/sh -eu -c "$REMOTE_RESTART_CMD"
fi

rm -rf "$REMOTE_TMP_DIR"
EOF
)"

echo "Installing hotfix payload on device..."
if [ -n "$REMOTE_SUDO" ]; then
    ssh -tt "$SSH_TARGET" "$REMOTE_SUDO" /bin/sh -s -- "$REMOTE_TMP_DIR" "$REMOTE_RESTART_CMD" <<<"$REMOTE_INSTALL_SCRIPT"
else
    ssh -tt "$SSH_TARGET" /bin/sh -s -- "$REMOTE_TMP_DIR" "$REMOTE_RESTART_CMD" <<<"$REMOTE_INSTALL_SCRIPT"
fi

echo "Hotfix applied."
