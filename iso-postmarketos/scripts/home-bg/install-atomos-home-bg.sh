#!/bin/bash
# Install atomos-home-bg into a rootfs.
#
# Two modes, auto-selected by the presence of `ROOTFS_DIR`:
#
#   pmbootstrap mode   (no ROOTFS_DIR set)
#     Uses scripts/pmb/pmb.sh to chroot into the pmbootstrap-managed rootfs
#     and install via stdin pipes. Used by build-image.sh on the FP4 path.
#
#   direct mode        (ROOTFS_DIR=/path/to/rootfs)
#     Writes files straight into the given rootfs tree. Used by
#     build-qemu.sh which builds a rootfs in a podman/docker volume.
#
# Both modes install the SAME files:
#   /usr/local/bin/atomos-home-bg         (binary)
#   /usr/bin/atomos-home-bg               (symlink)
#   /usr/libexec/atomos-home-bg           (lifecycle launcher)
#   /usr/share/atomos-home-bg/index.html  (placeholder content)
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: ROOTFS_DIR=/target $0 <profile-env>            # direct mode" >&2
    echo "       $0 <profile-env>                               # pmbootstrap mode" >&2
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

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"
HOME_BG_RUNTIME_DEFAULT="${ATOMOS_HOME_BG_ENABLE_RUNTIME_DEFAULT:-0}"
SKIP_BINARY_INSTALL="${ATOMOS_HOME_BG_SKIP_BINARY_INSTALL:-0}"
INSTALL_AUTOSTART="${ATOMOS_HOME_BG_INSTALL_AUTOSTART:-1}"

CONTENT_SRC="$ROOT_DIR/data/atomos-home-bg/index.html"
EVENT_HORIZON_SRC="$ROOT_DIR/data/atomos-home-bg/event-horizon.js"

# Binary search order: explicit override → pmbootstrap musl cross-build path
# → workspace native release path (built by build-qemu.sh inside the Alpine
# arm64 container, which is itself musl). First existing path wins.
candidate_bin_paths() {
    if [ -n "${ATOMOS_HOME_BG_BIN_PATH:-}" ]; then
        printf '%s\n' "$ATOMOS_HOME_BG_BIN_PATH"
    fi
    printf '%s\n' "$ROOT_DIR/rust/atomos-home-bg/target/aarch64-unknown-linux-musl/release/atomos-home-bg"
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

sed_inplace() {
    if sed --version >/dev/null 2>&1; then
        sed -i "$1" "$2"
    else
        sed -i '' "$1" "$2"
    fi
}

# Render the lifecycle launcher (with __HOME_BG_RUNTIME_DEFAULT__ replaced)
# into a tmp file, returning its absolute path on stdout. Shared by both
# install modes so the launcher contract stays identical.
render_launcher() {
    local out="$1"
    cat > "$out" <<'EOF'
#!/bin/sh
# /usr/libexec/atomos-home-bg: lifecycle wrapper for the home-screen
# webview background. Mirrors the launcher pattern used by
# atomos-overview-chat-ui (pidfile, log, Wayland env import, runtime gate).
set -eu
BIN="/usr/local/bin/atomos-home-bg"
export ATOMOS_HOME_BG_ENABLE_RUNTIME="${ATOMOS_HOME_BG_ENABLE_RUNTIME:-__HOME_BG_RUNTIME_DEFAULT__}"
# Default `bottom` so the webview sits above the session wallpaper (background
# layer) and below overview-chat-ui (top). Use `background` to share the lowest
# layer with other wallpaper clients (stacking is compositor-dependent).
export ATOMOS_HOME_BG_LAYER="${ATOMOS_HOME_BG_LAYER:-bottom}"
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
    sed_inplace "s/__HOME_BG_RUNTIME_DEFAULT__/${HOME_BG_RUNTIME_DEFAULT}/g" "$out"
}

# Inline fallback HTML used only when data/atomos-home-bg/index.html is
# missing (shouldn't happen in practice; the file is part of the repo).
fallback_html() {
    cat <<'EOF'
<!doctype html>
<html><body style="margin:0;background:#fff;color:#000;font-family:sans-serif;">
<main style="padding:2rem;">AtomOS Home Background (fallback placeholder)</main>
</body></html>
EOF
}

# XDG autostart entry. gnome-session / phosh-session walks
# /etc/xdg/autostart/ at login and Exec= each enabled .desktop. We pin
# OnlyShowIn=Phosh;GNOME so the launcher does not fire under bare X11
# sessions where layer-shell is unavailable.
render_autostart_desktop() {
    local out="$1"
    cat > "$out" <<'EOF'
[Desktop Entry]
Type=Application
Name=AtomOS Home Background
Comment=Non-interactive WebKit on layer-shell (default above session wallpaper, below chat UI)
Exec=/usr/libexec/atomos-home-bg --show
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Phase=Applications
OnlyShowIn=GNOME;Phosh;
EOF
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

LAUNCHER_TMP="$tmpdir/atomos-home-bg-launcher"
render_launcher "$LAUNCHER_TMP"

AUTOSTART_TMP=""
if [ "$INSTALL_AUTOSTART" = "1" ]; then
    AUTOSTART_TMP="$tmpdir/atomos-home-bg.desktop"
    render_autostart_desktop "$AUTOSTART_TMP"
fi

if [ -f "$CONTENT_SRC" ]; then
    HTML_TMP="$CONTENT_SRC"
else
    HTML_TMP="$tmpdir/index.html"
    fallback_html > "$HTML_TMP"
fi

# ---------- direct rootfs mode ----------
if [ -n "$DIRECT_ROOTFS_DIR" ]; then
    if [ ! -d "$DIRECT_ROOTFS_DIR" ]; then
        echo "ERROR: ROOTFS_DIR not a directory: $DIRECT_ROOTFS_DIR" >&2
        exit 1
    fi
    install -d "$DIRECT_ROOTFS_DIR/usr/local/bin" \
               "$DIRECT_ROOTFS_DIR/usr/bin" \
               "$DIRECT_ROOTFS_DIR/usr/libexec" \
               "$DIRECT_ROOTFS_DIR/usr/share/atomos-home-bg"

    if [ "$SKIP_BINARY_INSTALL" = "1" ]; then
        if [ ! -x "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-home-bg" ]; then
            echo "ERROR: ATOMOS_HOME_BG_SKIP_BINARY_INSTALL=1 but no binary at $DIRECT_ROOTFS_DIR/usr/local/bin/atomos-home-bg" >&2
            exit 1
        fi
        echo "install-atomos-home-bg: ATOMOS_HOME_BG_SKIP_BINARY_INSTALL=1; assuming caller pre-installed binary."
    else
        BIN_PATH="$(resolve_bin_path || true)"
        if [ -z "$BIN_PATH" ]; then
            echo "ERROR: atomos-home-bg binary not found in any candidate path:" >&2
            candidate_bin_paths | sed 's/^/  /' >&2
            echo "  Set ATOMOS_HOME_BG_BIN_PATH=... to override, or" >&2
            echo "  ATOMOS_HOME_BG_SKIP_BINARY_INSTALL=1 if the caller already placed the binary." >&2
            exit 1
        fi
        echo "install-atomos-home-bg: installing binary from $BIN_PATH"
        install -m 0755 "$BIN_PATH" "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-home-bg"
    fi
    # Relative symlink so it resolves correctly both at runtime (rootfs at /)
    # and when the rootfs is inspected via a /target mount (e.g. build-qemu's
    # final-verify container). Absolute symlinks dereference to the verify
    # container's own root and appear broken under /target.
    ln -sf ../local/bin/atomos-home-bg "$DIRECT_ROOTFS_DIR/usr/bin/atomos-home-bg"
    install -m 0755 "$LAUNCHER_TMP" "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-home-bg"
    install -m 0644 "$HTML_TMP" "$DIRECT_ROOTFS_DIR/usr/share/atomos-home-bg/index.html"
    if [ -f "$EVENT_HORIZON_SRC" ]; then
        install -m 0644 "$EVENT_HORIZON_SRC" "$DIRECT_ROOTFS_DIR/usr/share/atomos-home-bg/event-horizon.js"
    fi
    if [ -n "$AUTOSTART_TMP" ]; then
        install -d "$DIRECT_ROOTFS_DIR/etc/xdg/autostart"
        install -m 0644 "$AUTOSTART_TMP" "$DIRECT_ROOTFS_DIR/etc/xdg/autostart/atomos-home-bg.desktop"
    fi

    test -x "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-home-bg"
    test -x "$DIRECT_ROOTFS_DIR/usr/bin/atomos-home-bg"
    test -x "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-home-bg"
    test -f "$DIRECT_ROOTFS_DIR/usr/share/atomos-home-bg/index.html"
    if [ "$INSTALL_AUTOSTART" = "1" ]; then
        test -f "$DIRECT_ROOTFS_DIR/etc/xdg/autostart/atomos-home-bg.desktop"
        grep -q "Exec=/usr/libexec/atomos-home-bg --show" \
            "$DIRECT_ROOTFS_DIR/etc/xdg/autostart/atomos-home-bg.desktop"
    fi
    # Launcher contract sanity (matches verify_home_bg_launcher_contract in build-image.sh).
    grep -q "ATOMOS_HOME_BG_ENABLE_RUNTIME" "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-home-bg"
    grep -q "atomos-home-bg.disabled"       "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-home-bg"
    grep -q "ATOMOS_HOME_BG_LAYER"          "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-home-bg"
    grep -q "ATOMOS_HOME_BG_INTERACTIVE"    "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-home-bg"
    # Sanity-check the runtime gate baked at install time. If autostart is on
    # but ATOMOS_HOME_BG_ENABLE_RUNTIME_DEFAULT=0, the launcher will exit at
    # session login without presenting anything; warn (don't fail — caller
    # may opt to flip the gate via a per-user override).
    if [ "$INSTALL_AUTOSTART" = "1" ] && [ "$HOME_BG_RUNTIME_DEFAULT" != "1" ]; then
        echo "WARN: autostart installed but ATOMOS_HOME_BG_ENABLE_RUNTIME_DEFAULT=$HOME_BG_RUNTIME_DEFAULT;" >&2
        echo "  the launcher's --show will be a no-op until ATOMOS_HOME_BG_ENABLE_RUNTIME=1 is set." >&2
    fi
    echo "Installed atomos-home-bg into direct rootfs: $DIRECT_ROOTFS_DIR"
    exit 0
fi

# ---------- pmbootstrap chroot mode ----------
PMB="$ROOT_DIR/scripts/pmb/pmb.sh"
REQUIRE_BINARY="${ATOMOS_HOME_BG_REQUIRE_BINARY:-1}"

BIN_PATH="$(resolve_bin_path || true)"
if [ -z "$BIN_PATH" ]; then
    if [ "$REQUIRE_BINARY" = "1" ]; then
        echo "ERROR: install-atomos-home-bg: no prebuilt binary found." >&2
        candidate_bin_paths | sed 's/^/  expected: /' >&2
        exit 1
    fi
    echo "install-atomos-home-bg: no prebuilt binary; skipping."
    exit 0
fi
echo "install-atomos-home-bg: installing binary from $BIN_PATH"

INSTALL_DIRS='install -d /usr/local/bin /usr/libexec /usr/share/atomos-home-bg'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_DIRS"

INSTALL_BIN_CMD='cat > /usr/local/bin/atomos-home-bg && chmod 755 /usr/local/bin/atomos-home-bg && ln -sf /usr/local/bin/atomos-home-bg /usr/bin/atomos-home-bg'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_BIN_CMD" < "$BIN_PATH"

INSTALL_LAUNCHER_CMD='cat > /usr/libexec/atomos-home-bg && chmod 755 /usr/libexec/atomos-home-bg'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_LAUNCHER_CMD" < "$LAUNCHER_TMP"

INSTALL_INDEX_CMD='cat > /usr/share/atomos-home-bg/index.html && chmod 644 /usr/share/atomos-home-bg/index.html'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_INDEX_CMD" < "$HTML_TMP"

if [ -f "$EVENT_HORIZON_SRC" ]; then
    INSTALL_EH_CMD='cat > /usr/share/atomos-home-bg/event-horizon.js && chmod 644 /usr/share/atomos-home-bg/event-horizon.js'
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_EH_CMD" < "$EVENT_HORIZON_SRC"
fi

if [ -n "$AUTOSTART_TMP" ]; then
    INSTALL_AUTOSTART_DIR='install -d /etc/xdg/autostart'
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_AUTOSTART_DIR"
    INSTALL_AUTOSTART_CMD='cat > /etc/xdg/autostart/atomos-home-bg.desktop && chmod 644 /etc/xdg/autostart/atomos-home-bg.desktop'
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_AUTOSTART_CMD" < "$AUTOSTART_TMP"
fi

VERIFY_CMD='test -x /usr/local/bin/atomos-home-bg && test -x /usr/bin/atomos-home-bg && test -x /usr/libexec/atomos-home-bg && test -f /usr/share/atomos-home-bg/index.html && grep -q "ATOMOS_HOME_BG_ENABLE_RUNTIME" /usr/libexec/atomos-home-bg && grep -q "atomos-home-bg.disabled" /usr/libexec/atomos-home-bg && grep -q "ATOMOS_HOME_BG_LAYER" /usr/libexec/atomos-home-bg && grep -q "ATOMOS_HOME_BG_INTERACTIVE" /usr/libexec/atomos-home-bg'
if [ -n "$AUTOSTART_TMP" ]; then
    VERIFY_CMD="$VERIFY_CMD"' && test -f /etc/xdg/autostart/atomos-home-bg.desktop && grep -q "Exec=/usr/libexec/atomos-home-bg --show" /etc/xdg/autostart/atomos-home-bg.desktop'
fi
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"

echo "Installed atomos-home-bg into pmbootstrap rootfs."
