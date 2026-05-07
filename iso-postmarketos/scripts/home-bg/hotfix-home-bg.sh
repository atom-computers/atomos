#!/usr/bin/env bash
set -euo pipefail

if [ "${ATOMOS_HOME_BG_HOTFIX_DEBUG:-0}" = "1" ]; then
    set -x
fi

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <profile-env> <ssh-target>" >&2
    exit 1
fi

PROFILE_ENV="$1"
SSH_TARGET_RAW="$2"
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

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: $1 is required." >&2
        exit 1
    }
}

need_cmd ssh
need_cmd scp
need_cmd tar
need_cmd mktemp

# Accept either:
#   <user@host>
#   <user@host:port>
SSH_TARGET="$SSH_TARGET_RAW"
SSH_PORT_FROM_TARGET=""
if [[ "$SSH_TARGET_RAW" == *:* ]]; then
    maybe_host="${SSH_TARGET_RAW%:*}"
    maybe_port="${SSH_TARGET_RAW##*:}"
    if [[ "$maybe_port" =~ ^[0-9]+$ ]] && [[ "$maybe_host" == *@* || "$maybe_host" == *.* || "$maybe_host" == "localhost" ]]; then
        SSH_TARGET="$maybe_host"
        SSH_PORT_FROM_TARGET="$maybe_port"
    fi
fi

SSH_CMD=(ssh)
SCP_CMD=(scp)
SSH_PORT="${ATOMOS_DEVICE_SSH_PORT:-${SSH_PORT_FROM_TARGET:-2222}}"
SSH_CONNECT_TIMEOUT="${ATOMOS_DEVICE_SSH_CONNECT_TIMEOUT:-10}"
SSH_COMMON_OPTS=(
    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2
)
if [ -n "${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-}}" ]; then
    need_cmd sshpass
    SSH_PASSWORD="${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-}}"
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
    SSH_CMD=(sshpass -p "$SSH_PASSWORD" ssh "${SSH_COMMON_OPTS[@]}" "${SSH_AUTH_OPTS[@]}")
    SCP_CMD=(sshpass -p "$SSH_PASSWORD" scp "${SSH_COMMON_OPTS[@]}" "${SCP_AUTH_OPTS[@]}")
else
    SSH_CMD=(ssh "${SSH_COMMON_OPTS[@]}" -p "$SSH_PORT")
    SCP_CMD=(scp "${SSH_COMMON_OPTS[@]}" -P "$SSH_PORT")
fi

TARGET_TRIPLE="${ATOMOS_HOME_BG_TARGET_TRIPLE:-aarch64-unknown-linux-musl}"
CRATE_MANIFEST="$ROOT_DIR/rust/atomos-home-bg/app-gtk/Cargo.toml"
BIN_PATH_OVERRIDE="${ATOMOS_HOME_BG_BIN_PATH:-}"
SKIP_BUILD="${ATOMOS_HOME_BG_SKIP_BUILD:-0}"
CONTENT_ONLY="${ATOMOS_HOME_BG_CONTENT_ONLY:-1}"

REMOTE_TMP_DIR="${ATOMOS_HOME_BG_REMOTE_TMP:-/tmp/atomos-home-bg-hotfix.$$}"
REMOTE_SUDO="${ATOMOS_HOME_BG_REMOTE_SUDO:-sudo}"
REMOTE_SUDO_PASSWORD="${ATOMOS_HOME_BG_REMOTE_SUDO_PASSWORD:-${ATOMOS_DEVICE_SSHPASS:-${SSHPASS:-}}}"
if [ "${ATOMOS_HOME_BG_RESTART_CMD+set}" = "set" ]; then
    REMOTE_RESTART_CMD="$ATOMOS_HOME_BG_RESTART_CMD"
else
    REMOTE_RESTART_CMD="__DEFAULT_RESTART_HOME_BG__"
fi

candidate_bin_paths() {
    if [ -n "$BIN_PATH_OVERRIDE" ]; then
        printf '%s\n' "$BIN_PATH_OVERRIDE"
    fi
    printf '%s\n' "$ROOT_DIR/rust/atomos-home-bg/target/$TARGET_TRIPLE/release/atomos-home-bg"
    printf '%s\n' "$ROOT_DIR/rust/atomos-home-bg/target/release/atomos-home-bg"
}

resolve_bin_path() {
    local p
    while IFS= read -r p; do
        if [ -x "$p" ]; then
            printf '%s\n' "$p"
            return 0
        fi
    done < <(candidate_bin_paths)
    return 1
}

# Auto-pick host vs container build. Host cross-compile only works on
# Linux (gtk-rs / webkit6 sys crates need a working pkg-config that can
# resolve gtk4 / webkit2gtk-6.0 for the target triple, which macOS
# pkg-config can't do without a Linux sysroot). On non-Linux we delegate
# to the Alpine arm64 container helper. Override with
# ATOMOS_HOME_BG_BUILD_MODE=host|container.
resolve_build_mode() {
    if [ -n "${ATOMOS_HOME_BG_BUILD_MODE:-}" ]; then
        echo "$ATOMOS_HOME_BG_BUILD_MODE"
        return
    fi
    if [ "$(uname -s)" = "Linux" ]; then
        echo "host"
    else
        echo "container"
    fi
}

BIN_PATH=""
if [ "$CONTENT_ONLY" != "1" ]; then
    if [ ! -f "$CRATE_MANIFEST" ]; then
        echo "ERROR: missing home-bg manifest: $CRATE_MANIFEST" >&2
        exit 1
    fi

    if [ "$SKIP_BUILD" != "1" ]; then
        BUILD_MODE="$(resolve_build_mode)"
        case "$BUILD_MODE" in
            host)
                need_cmd cargo
                if command -v rustup >/dev/null 2>&1; then
                    rustup target add "$TARGET_TRIPLE" >/dev/null 2>&1 || true
                fi
                echo "Building atomos-home-bg ($TARGET_TRIPLE) on host ..."
                cargo build \
                    --manifest-path "$CRATE_MANIFEST" \
                    --release \
                    --target "$TARGET_TRIPLE" \
                    --bin atomos-home-bg
                ;;
            container)
                # Containerized build sidesteps macOS pkg-config woes.
                # Output lands at target/release/atomos-home-bg, which
                # is the second candidate path resolve_bin_path() checks.
                echo "Building atomos-home-bg via Alpine arm64 container (host=$(uname -s)) ..."
                bash "$ROOT_DIR/scripts/home-bg/build-atomos-home-bg-in-container.sh"
                ;;
            *)
                echo "ERROR: ATOMOS_HOME_BG_BUILD_MODE must be 'host' or 'container' (got '$BUILD_MODE')" >&2
                exit 2
                ;;
        esac
    fi

    BIN_PATH="$(resolve_bin_path || true)"
    if [ -z "$BIN_PATH" ]; then
        echo "ERROR: atomos-home-bg binary not found in candidate paths:" >&2
        candidate_bin_paths | sed 's/^/  /' >&2
        if [ "$SKIP_BUILD" = "1" ]; then
            echo "Hint: disable ATOMOS_HOME_BG_SKIP_BUILD or set ATOMOS_HOME_BG_BIN_PATH." >&2
        fi
        if [ "$(uname -s)" != "Linux" ]; then
            echo "Hint: on non-Linux hosts the build runs inside a container;" >&2
            echo "      ensure docker or podman is installed and reachable." >&2
        fi
        exit 1
    fi
fi

tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

STAGED_ROOTFS="$tmpdir/staged-rootfs"
mkdir -p "$STAGED_ROOTFS"

ARCHIVE_PATH="$tmpdir/atomos-home-bg-payload.tar.gz"
if [ "$CONTENT_ONLY" = "1" ]; then
    echo "Staging content-only payload (no binary build/install) ..."
    echo "  (set ATOMOS_HOME_BG_CONTENT_ONLY=0 to also rebuild + redeploy"
    echo "   the binary — required to pick up WebKit settings changes,"
    echo "   e.g. enable_webgl / hardware_acceleration_policy.)"
    install -d "$STAGED_ROOTFS/usr/share/atomos-home-bg"
    install -m 0644 "$ROOT_DIR/data/atomos-home-bg/index.html" \
        "$STAGED_ROOTFS/usr/share/atomos-home-bg/index.html"
    if [ -f "$ROOT_DIR/data/atomos-home-bg/event-horizon.js" ]; then
        install -m 0644 "$ROOT_DIR/data/atomos-home-bg/event-horizon.js" \
            "$STAGED_ROOTFS/usr/share/atomos-home-bg/event-horizon.js"
    fi

    payload_paths=(
        "usr/share/atomos-home-bg/index.html"
    )
    if [ -f "$STAGED_ROOTFS/usr/share/atomos-home-bg/event-horizon.js" ]; then
        payload_paths+=("usr/share/atomos-home-bg/event-horizon.js")
    fi
    (
        cd "$STAGED_ROOTFS"
        tar -czf "$ARCHIVE_PATH" "${payload_paths[@]}"
    )
else
    echo "Staging full home-bg payload via install-atomos-home-bg.sh ..."
    ROOTFS_DIR="$STAGED_ROOTFS" \
    ATOMOS_HOME_BG_BIN_PATH="$BIN_PATH" \
    ATOMOS_HOME_BG_SKIP_BINARY_INSTALL=0 \
    bash "$ROOT_DIR/scripts/home-bg/install-atomos-home-bg.sh" "$PROFILE_ENV_SOURCE"

    payload_paths=(
        "usr/local/bin/atomos-home-bg"
        "usr/bin/atomos-home-bg"
        "usr/libexec/atomos-home-bg"
        "usr/share/atomos-home-bg/index.html"
    )
    if [ -f "$STAGED_ROOTFS/usr/share/atomos-home-bg/event-horizon.js" ]; then
        payload_paths+=("usr/share/atomos-home-bg/event-horizon.js")
    fi
    if [ -f "$STAGED_ROOTFS/etc/xdg/autostart/atomos-home-bg.desktop" ]; then
        payload_paths+=("etc/xdg/autostart/atomos-home-bg.desktop")
    fi
    (
        cd "$STAGED_ROOTFS"
        tar -czf "$ARCHIVE_PATH" "${payload_paths[@]}"
    )
fi

echo "Uploading home-bg hotfix payload to $SSH_TARGET:$REMOTE_TMP_DIR ..."
"${SSH_CMD[@]}" "$SSH_TARGET" "mkdir -p '$REMOTE_TMP_DIR'"
"${SCP_CMD[@]}" "$ARCHIVE_PATH" "$SSH_TARGET:$REMOTE_TMP_DIR/atomos-home-bg-payload.tar.gz"

shell_quote_sq() {
    local s="$1"
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

REMOTE_TMP_DIR_Q="$(shell_quote_sq "$REMOTE_TMP_DIR")"
REMOTE_RESTART_CMD_Q="$(shell_quote_sq "$REMOTE_RESTART_CMD")"

REMOTE_APPLY_SCRIPT="$(cat <<EOF
set -eu
REMOTE_TMP_DIR=$REMOTE_TMP_DIR_Q
REMOTE_RESTART_CMD=$REMOTE_RESTART_CMD_Q

restart_home_bg_default() {
    pids=\$(pidof atomos-home-bg 2>/dev/null || true)
    if [ -z "\$pids" ]; then
        pids=\$(pgrep -x atomos-home-bg 2>/dev/null || true)
    fi
    if [ -n "\$pids" ]; then
        echo "Stopping atomos-home-bg (pids: \$pids)"
        kill -TERM \$pids 2>/dev/null || true
        sleep 1
        for pid in \$pids; do
            kill -0 "\$pid" 2>/dev/null || continue
            kill -KILL "\$pid" 2>/dev/null || true
        done
    fi

    phosh_pid=\$(pgrep phosh | head -n 1 || true)
    if [ -z "\$phosh_pid" ]; then
        echo "No phosh session detected; skip auto-restart."
        return 0
    fi

    session_user=\$(ps -o user= -p "\$phosh_pid" 2>/dev/null | tr -d ' ' || true)
    if [ -z "\$session_user" ]; then
        echo "Could not resolve phosh session user; skip auto-restart."
        return 0
    fi

    echo "Restarting atomos-home-bg as user \$session_user"
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "\$session_user" -- /usr/libexec/atomos-home-bg --show || true
    elif command -v su >/dev/null 2>&1; then
        su -s /bin/sh "\$session_user" -c "/usr/libexec/atomos-home-bg --show" || true
    else
        echo "No runuser/su available for session-user restart; skipped."
    fi
}

tar -xzf "\$REMOTE_TMP_DIR/atomos-home-bg-payload.tar.gz" -C /

if [ -n "\$REMOTE_RESTART_CMD" ]; then
    echo "Applying restart command..."
    if [ "\$REMOTE_RESTART_CMD" = "__DEFAULT_RESTART_HOME_BG__" ]; then
        restart_home_bg_default
    else
        /bin/sh -eu -c "\$REMOTE_RESTART_CMD"
    fi
fi

rm -rf "\$REMOTE_TMP_DIR"
EOF
)"

REMOTE_APPLY_BASENAME="atomos-home-bg-hotfix-apply.sh"
REMOTE_APPLY_PATH="$tmpdir/$REMOTE_APPLY_BASENAME"
printf '%s\n' "$REMOTE_APPLY_SCRIPT" > "$REMOTE_APPLY_PATH"
chmod 700 "$REMOTE_APPLY_PATH"
"${SCP_CMD[@]}" "$REMOTE_APPLY_PATH" "$SSH_TARGET:$REMOTE_TMP_DIR/$REMOTE_APPLY_BASENAME"

echo "Applying remote home-bg hotfix..."
apply_rc=0
if [ -n "$REMOTE_SUDO" ]; then
    if [ -n "${REMOTE_SUDO_PASSWORD:-}" ]; then
        "${SSH_CMD[@]}" -tt "$SSH_TARGET" "printf '%s\n' $(shell_quote_sq "$REMOTE_SUDO_PASSWORD") | $REMOTE_SUDO -S -p '' -k -- /bin/sh -eu '$REMOTE_TMP_DIR/$REMOTE_APPLY_BASENAME'" || apply_rc=$?
    else
        "${SSH_CMD[@]}" -tt "$SSH_TARGET" "$REMOTE_SUDO" -n -- /bin/sh -eu "$REMOTE_TMP_DIR/$REMOTE_APPLY_BASENAME" || apply_rc=$?
    fi
else
    "${SSH_CMD[@]}" "$SSH_TARGET" /bin/sh -eu "$REMOTE_TMP_DIR/$REMOTE_APPLY_BASENAME" || apply_rc=$?
fi

if [ "$apply_rc" -ne 0 ]; then
    echo "ERROR: remote hotfix apply failed (exit $apply_rc)." >&2
    echo "  If sudo enforces a TTY, this script already uses ssh -tt." >&2
    echo "  If this failed at sudo due non-interactive mode (-n), set:" >&2
    echo "  ATOMOS_HOME_BG_REMOTE_SUDO_PASSWORD='<actual-sudo-password>'" >&2
    exit "$apply_rc"
fi

echo "Home-bg hotfix applied."
