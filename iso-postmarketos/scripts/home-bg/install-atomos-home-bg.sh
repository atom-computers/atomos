#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIRECT_ROOTFS_DIR="${ROOTFS_DIR:-}"

PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi

BIN_PATH="$ROOT_DIR/rust/atomos-home-bg/target/aarch64-unknown-linux-musl/release/atomos-home-bg"
if [ ! -x "$BIN_PATH" ]; then
    echo "ERROR: atomos-home-bg binary missing; run build-atomos-home-bg.sh first." >&2
    echo "  expected: $BIN_PATH" >&2
    exit 1
fi

install_direct() {
    local root="$1"
    install -d "$root/usr/local/bin" "$root/usr/libexec" "$root/usr/share/atomos-home-bg"
    install -m 0755 "$BIN_PATH" "$root/usr/local/bin/atomos-home-bg"
    ln -sf /usr/local/bin/atomos-home-bg "$root/usr/bin/atomos-home-bg"
    cat > "$root/usr/libexec/atomos-home-bg" <<'EOF'
#!/bin/sh
set -eu
exec /usr/local/bin/atomos-home-bg "$@"
EOF
    chmod 0755 "$root/usr/libexec/atomos-home-bg"
    cat > "$root/usr/share/atomos-home-bg/index.html" <<'EOF'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>AtomOS Home BG</title></head>
<body style="margin:0;background:#000;color:#fff;font-family:sans-serif;">
  <main style="padding:2rem;">AtomOS Home Background</main>
</body>
</html>
EOF
}

if [ -n "$DIRECT_ROOTFS_DIR" ]; then
    install_direct "$DIRECT_ROOTFS_DIR"
    test -x "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-home-bg"
    test -x "$DIRECT_ROOTFS_DIR/usr/bin/atomos-home-bg"
    test -x "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-home-bg"
    test -f "$DIRECT_ROOTFS_DIR/usr/share/atomos-home-bg/index.html"
    echo "Installed atomos-home-bg into direct rootfs: $DIRECT_ROOTFS_DIR"
    exit 0
fi

PMB="$ROOT_DIR/scripts/pmb/pmb.sh"
INSTALL_DIRS='install -d /usr/local/bin /usr/libexec /usr/share/atomos-home-bg'
INSTALL_BIN_CMD='cat > /usr/local/bin/atomos-home-bg && chmod 755 /usr/local/bin/atomos-home-bg && ln -sf /usr/local/bin/atomos-home-bg /usr/bin/atomos-home-bg'
INSTALL_LAUNCHER_CMD='cat > /usr/libexec/atomos-home-bg && chmod 755 /usr/libexec/atomos-home-bg'
INSTALL_HTML_CMD='cat > /usr/share/atomos-home-bg/index.html && chmod 644 /usr/share/atomos-home-bg/index.html'
VERIFY_CMD='test -x /usr/local/bin/atomos-home-bg && test -x /usr/bin/atomos-home-bg && test -x /usr/libexec/atomos-home-bg && test -f /usr/share/atomos-home-bg/index.html'

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
cat > "$tmpdir/launcher.sh" <<'EOF'
#!/bin/sh
set -eu
exec /usr/local/bin/atomos-home-bg "$@"
EOF
cat > "$tmpdir/index.html" <<'EOF'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>AtomOS Home BG</title></head>
<body style="margin:0;background:#000;color:#fff;font-family:sans-serif;">
  <main style="padding:2rem;">AtomOS Home Background</main>
</body>
</html>
EOF

bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_DIRS"
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_BIN_CMD" < "$BIN_PATH"
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_LAUNCHER_CMD" < "$tmpdir/launcher.sh"
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_HTML_CMD" < "$tmpdir/index.html"
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"

echo "Installed atomos-home-bg into pmbootstrap rootfs."
#!/bin/bash
# Install atomos-home-bg into the pmOS rootfs chroot:
#   /usr/local/bin/atomos-home-bg         (the binary)
#   /usr/libexec/atomos-home-bg           (launcher; --show/--hide lifecycle)
#   /usr/share/atomos-home-bg/index.html  (placeholder React mount point)
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
HOME_BG_RUNTIME_DEFAULT="${ATOMOS_HOME_BG_ENABLE_RUNTIME_DEFAULT:-0}"

sed_inplace() {
    if sed --version >/dev/null 2>&1; then
        sed -i "$1" "$2"
    else
        sed -i '' "$1" "$2"
    fi
}

PMB="$ROOT_DIR/scripts/pmb/pmb.sh"
BIN_PATH="$ROOT_DIR/rust/atomos-home-bg/target/aarch64-unknown-linux-musl/release/atomos-home-bg"
CONTENT_SRC="$ROOT_DIR/data/atomos-home-bg/index.html"
EVENT_HORIZON_SRC="$ROOT_DIR/data/atomos-home-bg/event-horizon.js"
REQUIRE_BINARY="${ATOMOS_HOME_BG_REQUIRE_BINARY:-1}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if [ ! -x "$BIN_PATH" ]; then
    if [ "$REQUIRE_BINARY" = "1" ]; then
        echo "ERROR: install-atomos-home-bg: no prebuilt binary found." >&2
        echo "  expected: $BIN_PATH" >&2
        exit 1
    fi
    echo "install-atomos-home-bg: no prebuilt binary; skipping."
    exit 0
fi

cat > "$tmpdir/atomos-home-bg-launcher" <<'EOF'
#!/bin/sh
# /usr/libexec/atomos-home-bg: lifecycle wrapper for the home-screen
# webview background. Mirrors the launcher pattern used by
# atomos-overview-chat-ui (pidfile, log, Wayland env import, runtime gate).
set -eu
BIN="/usr/local/bin/atomos-home-bg"
export ATOMOS_HOME_BG_ENABLE_RUNTIME="${ATOMOS_HOME_BG_ENABLE_RUNTIME:-__HOME_BG_RUNTIME_DEFAULT__}"
export ATOMOS_HOME_BG_LAYER="${ATOMOS_HOME_BG_LAYER:-background}"
# Non-interactive by default; pointer/touch falls through to phosh overview.
export ATOMOS_HOME_BG_INTERACTIVE="${ATOMOS_HOME_BG_INTERACTIVE:-0}"
# WebKit on QEMU GL stacks can crash very early; cairo/software is the safe default.
export GDK_BACKEND="${GDK_BACKEND:-wayland}"
export GSK_RENDERER="${ATOMOS_HOME_BG_GSK_RENDERER:-cairo}"
export LIBGL_ALWAYS_SOFTWARE="${ATOMOS_HOME_BG_LIBGL_ALWAYS_SOFTWARE:-1}"
# webkit2gtk-6.0 sandbox needs a usable /proc/self; bubblewrap is missing on
# minimal pmOS images. Disable sandbox unless explicitly enabled.
export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS="${WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS:-1}"
# DMABUF renderer path can pick up the wrong GBM device on some phones.
export WEBKIT_DISABLE_DMABUF_RENDERER="${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"

PIDFILE=""
LOGFILE=""
DISABLE_FILE=""

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
    PIDFILE="$runtime/atomos-home-bg.pid"
    LOGFILE="$runtime/atomos-home-bg.log"
    DISABLE_FILE="$runtime/atomos-home-bg.disabled"
}

is_running() {
    resolve_runtime_paths
    [ -f "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

bind_phosh_session_env_if_missing() {
    [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && return 0
    if ! command -v pgrep >/dev/null 2>&1; then
        logger -t atomos-home-bg "pgrep unavailable; cannot auto-bind Wayland env"
        return 0
    fi
    phosh_pid="$(pgrep phosh | head -n 1 || true)"
    if [ -z "$phosh_pid" ]; then
        logger -t atomos-home-bg "phosh pid not found; WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
        return 0
    fi
    env_file="/proc/$phosh_pid/environ"
    if [ ! -r "$env_file" ]; then
        logger -t atomos-home-bg "cannot read $env_file"
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
        logger -t atomos-home-bg "binary not installed; no-op start"
        return 0
    fi
    if is_running; then
        return 0
    fi
    if [ -f "$DISABLE_FILE" ]; then
        logger -t atomos-home-bg "runtime disabled by marker: $DISABLE_FILE"
        return 0
    fi
    (
        printf '%s\n' "---- $(date) ----"
        set +e
        "$BIN"
        rc=$?
        if [ "$rc" -eq 127 ]; then
            : > "$DISABLE_FILE"
            logger -t atomos-home-bg "exec rc=127; wrote disable marker $DISABLE_FILE"
        fi
        logger -t atomos-home-bg "process-exit rc=$rc"
        exit "$rc"
    ) >>"$LOGFILE" 2>&1 &
    pid=$!
    echo "$pid" > "$PIDFILE"
    sleep 0.2
    if ! kill -0 "$pid" 2>/dev/null; then
        logger -t atomos-home-bg "exited immediately; log: $LOGFILE"
        rm -f "$PIDFILE"
    fi
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
        if [ "${ATOMOS_HOME_BG_ENABLE_RUNTIME:-0}" != "1" ]; then
            logger -t atomos-home-bg "runtime disabled; skipping show"
            exit 0
        fi
        bind_phosh_session_env_if_missing
        logger -t atomos-home-bg "action=show wayland=${WAYLAND_DISPLAY:-<unset>}"
        start_ui
        ;;
    --hide)
        logger -t atomos-home-bg "action=hide"
        stop_ui
        ;;
    *)
        if [ -x "$BIN" ]; then
            exec "$BIN" "$@"
        fi
        logger -t atomos-home-bg "binary not installed; no-op"
        ;;
esac
EOF
sed_inplace "s/__HOME_BG_RUNTIME_DEFAULT__/${HOME_BG_RUNTIME_DEFAULT}/g" "$tmpdir/atomos-home-bg-launcher"

INSTALL_DIRS='install -d /usr/local/bin /usr/libexec /usr/share/atomos-home-bg'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_DIRS"

INSTALL_BIN_CMD='cat > /usr/local/bin/atomos-home-bg && chmod 755 /usr/local/bin/atomos-home-bg && ln -sf /usr/local/bin/atomos-home-bg /usr/bin/atomos-home-bg'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_BIN_CMD" < "$BIN_PATH"

INSTALL_LAUNCHER_CMD='cat > /usr/libexec/atomos-home-bg && chmod 755 /usr/libexec/atomos-home-bg'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_LAUNCHER_CMD" < "$tmpdir/atomos-home-bg-launcher"

if [ -f "$CONTENT_SRC" ]; then
    INSTALL_INDEX_CMD='cat > /usr/share/atomos-home-bg/index.html && chmod 644 /usr/share/atomos-home-bg/index.html'
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_INDEX_CMD" < "$CONTENT_SRC"
fi

# index.html includes the animation via <script src="event-horizon.js">, so
# the companion file must be shipped alongside it or the webview will load a
# blank white page with just the preview-test HUD.
if [ -f "$EVENT_HORIZON_SRC" ]; then
    INSTALL_EH_CMD='cat > /usr/share/atomos-home-bg/event-horizon.js && chmod 644 /usr/share/atomos-home-bg/event-horizon.js'
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_EH_CMD" < "$EVENT_HORIZON_SRC"
fi

VERIFY_CMD='test -x /usr/local/bin/atomos-home-bg && test -x /usr/bin/atomos-home-bg && test -x /usr/libexec/atomos-home-bg && test -d /usr/share/atomos-home-bg'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"

echo "Installed atomos-home-bg binary, launcher, and placeholder content."
