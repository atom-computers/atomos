#!/bin/bash
# Install atomos-overview-chat-ui into a rootfs.
#
# Two modes, auto-selected by the presence of `ROOTFS_DIR`:
#
#   pmbootstrap mode   (no ROOTFS_DIR set)
#     Uses scripts/pmb/pmb.sh to chroot into the pmbootstrap-managed rootfs.
#
#   direct mode        (ROOTFS_DIR=/path/to/rootfs)
#     Writes files straight into the given rootfs tree. Used by build-qemu.sh
#     and build-fairphone4-v2.sh which build a rootfs in a podman/docker volume.
#
# Both modes install the SAME files:
#   /usr/local/bin/atomos-overview-chat-ui         (binary)
#   /usr/bin/atomos-overview-chat-ui               (symlink)
#   /usr/libexec/atomos-overview-chat-ui           (lifecycle launcher)
#   /usr/libexec/atomos-overview-chat-submit       (chat submit helper)
#   /etc/xdg/autostart/atomos-overview-chat-ui.desktop  (optional; default ON)
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: ROOTFS_DIR=/target $0 <profile-env>            # direct mode" >&2
    echo "       $0 <profile-env>                               # pmbootstrap mode" >&2
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
OVERVIEW_DISABLE_CUSTOM_CSS_DEFAULT="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS_DEFAULT:-0}"
OVERVIEW_DISABLE_THEME_CLASS_DEFAULT="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS_DEFAULT:-0}"
INSTALL_AUTOSTART="${ATOMOS_OVERVIEW_CHAT_UI_INSTALL_AUTOSTART:-1}"

sed_inplace() {
    # GNU sed supports `-i`; BSD/macOS sed requires `-i ''`.
    if sed --version >/dev/null 2>&1; then
        sed -i "$1" "$2"
    else
        sed -i '' "$1" "$2"
    fi
}

PMB="$ROOT_DIR/scripts/pmb/pmb.sh"
SKIP_BINARY_INSTALL="${ATOMOS_OVERVIEW_CHAT_UI_SKIP_BINARY_INSTALL:-0}"
REQUIRE_BINARY="${ATOMOS_OVERVIEW_CHAT_UI_REQUIRE_BINARY:-1}"

candidate_bin_paths() {
    if [ -n "${ATOMOS_OVERVIEW_CHAT_UI_BIN:-}" ]; then
        printf '%s\n' "$ATOMOS_OVERVIEW_CHAT_UI_BIN"
    fi
    printf '%s\n' "/cache/cargo-target/aarch64-unknown-linux-musl/release/atomos-overview-chat-ui"
    printf '%s\n' "/cache/cargo-target/release/atomos-overview-chat-ui"
    printf '%s\n' "$ROOT_DIR/rust/atomos-overview-chat-ui/target/aarch64-unknown-linux-musl/release/atomos-overview-chat-ui"
    printf '%s\n' "$ROOT_DIR/rust/atomos-overview-chat-ui/target/release/atomos-overview-chat-ui"
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

tmpdir="$(mktemp -d)"
cleanup() {
    rm -rf "$tmpdir"
}
trap cleanup EXIT

BIN_PATH="$(resolve_bin_path || true)"
if [ -z "$BIN_PATH" ]; then
    if [ "$REQUIRE_BINARY" = "1" ]; then
        echo "ERROR: install-overview-chat-ui: no prebuilt binary found; fail install" >&2
        candidate_bin_paths | sed 's/^/  expected: /' >&2
        echo "  Set ATOMOS_OVERVIEW_CHAT_UI_BIN=... to override, or" >&2
        echo "  ATOMOS_OVERVIEW_CHAT_UI_SKIP_BINARY_INSTALL=1 if the caller already placed the binary." >&2
        echo "  If you want launcher-only behavior, set ATOMOS_OVERVIEW_CHAT_UI_REQUIRE_BINARY=0." >&2
        exit 1
    fi
    echo "install-overview-chat-ui: no prebuilt binary found; skip install (ATOMOS_OVERVIEW_CHAT_UI_REQUIRE_BINARY=0)"
    candidate_bin_paths | sed 's/^/  expected: /'
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
# Phosh drives layer via ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay|bottom on --show.
export ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE="${ATOMOS_OVERVIEW_CHAT_UI_IGNORE_HIDE:-0}"
# Safety fallback: some target GTK stacks crash while parsing advanced CSS.
# Set to 0 to re-enable themed CSS after confirming target stability.
export ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS:-__OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS_DEFAULT__}"
# QEMU/virt stacks can crash GTK4 GL renderers very early; prefer software cairo.
export GDK_BACKEND="${GDK_BACKEND:-wayland}"
export GSK_RENDERER="${ATOMOS_OVERVIEW_CHAT_UI_GSK_RENDERER:-cairo}"
export LIBGL_ALWAYS_SOFTWARE="${ATOMOS_OVERVIEW_CHAT_UI_LIBGL_ALWAYS_SOFTWARE:-1}"
# Additional safety defaults for unstable target stacks.
export ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE="${ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE:-1}"
export ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS:-__OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS_DEFAULT__}"
export ATOMOS_OVERVIEW_CHAT_UI_FORCE_TRANSPARENT_ROOT="${ATOMOS_OVERVIEW_CHAT_UI_FORCE_TRANSPARENT_ROOT:-1}"
# Default bottom until Phosh unfolds (then layer=overlay). Folded apps stay above us.
export ATOMOS_OVERVIEW_CHAT_UI_LAYER="${ATOMOS_OVERVIEW_CHAT_UI_LAYER:-bottom}"
# Icon metadata probes extra GLib desktop fields; keep off by default on device.
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS:-1}"
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-__OVERVIEW_CHAT_UI_RUNTIME_DEFAULT__}"
# Phosh runs this as the logged-in user; prefer session runtime dir.
PIDFILE=""
LOGFILE=""
DISABLE_FILE=""
LAYERFILE=""

# True only when the GTK binary (not the /bin/sh --show wrapper) is alive.
# The pidfile must reference /usr/local/bin/atomos-overview-chat-ui: if it
# still points at the launcher subshell, Phosh's `LAYER=top --show` stop_ui
# kills the shell while the old binary keeps running on layer=bottom and the
# home screen looks empty on later boots (the "3rd reboot" symptom).
is_running() {
    resolve_runtime_paths
    [ -f "$PIDFILE" ] || return 1
    pid=$(cat "$PIDFILE" 2>/dev/null || true)
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$cmdline" in
        */usr/local/bin/atomos-overview-chat-ui*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

kill_chat_ui_binary() {
    pids=""
    for pid in $(pgrep -f '/usr/local/bin/atomos-overview-chat-ui' 2>/dev/null || true); do
        [ -n "$pid" ] && pids="$pids $pid"
    done
    
    [ -n "$pids" ] || return 0
    
    for pid in $pids; do
        kill -15 "$pid" 2>/dev/null || true
    done
    
    tries=0
    while [ "$tries" -lt 5 ]; do
        alive=0
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                alive=1
                break
            fi
        done
        [ "$alive" -eq 0 ] && break
        sleep 0.1
        tries=$((tries + 1))
    done
    
    for pid in $pids; do
        if kill -0 "$pid" 2>/dev/null; then
            logger -t atomos-overview-chat-ui "pid $pid still alive after SIGTERM, sending SIGKILL"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
    
    tries=0
    while [ "$tries" -lt 3 ]; do
        alive=0
        for pid in $pids; do
            if kill -0 "$pid" 2>/dev/null; then
                alive=1
                break
            fi
        done
        [ "$alive" -eq 0 ] && break
        sleep 0.05
        tries=$((tries + 1))
    done
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
    LAYERFILE="$runtime/atomos-overview-chat-ui.layer"
}

bind_phosh_session_env_if_missing() {
    [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && return 0
    uid="$(id -u 2>/dev/null || true)"
    if [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
        export XDG_RUNTIME_DIR="/run/user/$uid"
    fi
    if ! command -v pgrep >/dev/null 2>&1; then
        logger -t atomos-overview-chat-ui "pgrep unavailable; cannot auto-bind Wayland env"
    else
        for phosh_pid in $(pgrep -u "$uid" -x phosh 2>/dev/null || true) \
                         $(pgrep -u "$uid" phosh 2>/dev/null || true); do
            [ -n "$phosh_pid" ] || continue
            env_file="/proc/$phosh_pid/environ"
            [ -r "$env_file" ] || continue
            for var in WAYLAND_DISPLAY XDG_RUNTIME_DIR DISPLAY DBUS_SESSION_BUS_ADDRESS; do
                cur=""
                case "$var" in
                    WAYLAND_DISPLAY) cur="${WAYLAND_DISPLAY:-}" ;;
                    XDG_RUNTIME_DIR) cur="${XDG_RUNTIME_DIR:-}" ;;
                    DISPLAY) cur="${DISPLAY:-}" ;;
                    DBUS_SESSION_BUS_ADDRESS) cur="${DBUS_SESSION_BUS_ADDRESS:-}" ;;
                esac
                if [ -z "$cur" ]; then
                    line="$(tr '\0' '\n' < "$env_file" 2>/dev/null | awk -F= -v k="$var" '$1 == k { print; exit }' || true)"
                    [ -n "$line" ] && export "$line"
                fi
            done
            [ -n "${WAYLAND_DISPLAY:-}" ] && break
        done
    fi
    if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        for wl in wayland-1 wayland-0; do
            if [ -S "${XDG_RUNTIME_DIR}/${wl}" ]; then
                export WAYLAND_DISPLAY="$wl"
                break
            fi
        done
    fi
    if [ -z "${WAYLAND_DISPLAY:-}" ]; then
        logger -t atomos-overview-chat-ui "phosh Wayland env not bound; WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>} runtime=${XDG_RUNTIME_DIR:-<unset>}"
    fi
}

wait_for_phosh_wayland_env() {
    tries=0
    while [ "$tries" -lt 50 ]; do
        bind_phosh_session_env_if_missing
        [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && return 0
        tries=$((tries + 1))
        sleep 0.1
    done
    logger -t atomos-overview-chat-ui "WARN: Wayland env still unset after ${tries} retries (autostart may have beaten phosh)"
    return 1
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
        exec 9>&-
        printf '%s\n' "---- $(date) ----"
        set +e
        # exec replaces the subshell with the GTK binary so $! / the pidfile
        # track the real process Phosh must kill on layer --show restarts.
        if ! exec "$BIN"; then
            rc=$?
            if [ "$rc" -eq 127 ]; then
                : > "$DISABLE_FILE"
                logger -t atomos-overview-chat-ui "binary exec failed rc=127; wrote disable marker $DISABLE_FILE"
            fi
            logger -t atomos-overview-chat-ui "process-exit rc=$rc"
            exit "$rc"
        fi
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
    resolve_runtime_paths
    if is_running; then
        pid=$(cat "$PIDFILE" 2>/dev/null || true)
        kill "$pid" 2>/dev/null || true
    fi
    # Belt-and-suspenders: older images wrote the launcher shell pid into the
    # pidfile; killing it left the GTK binary alive on the wrong layer.
    kill_chat_ui_binary
    rm -f "$PIDFILE"
}

log_action() {
    resolve_runtime_paths
    msg="$1"
    logger -t atomos-overview-chat-ui "$msg"
    if [ -n "${LOGFILE:-}" ]; then
        printf "%s\n" "$msg" >>"$LOGFILE"
    fi
}

case "${1:-}" in
    --start)
        if [ "${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-1}" != "1" ]; then
            log_action "runtime disabled (ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME=${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-0}); skipping start"
            exit 0
        fi
        if [ "${ATOMOS_OVERVIEW_CHAT_UI_AUTOSTART_SPAWN:-1}" != "1" ]; then
            log_action "action=start autostart spawn suppressed; phosh drives overlay --show"
            exit 0
        fi
        wait_for_phosh_wayland_env || true
        log_action "action=start wayland=${WAYLAND_DISPLAY:-<unset>} layer=${ATOMOS_OVERVIEW_CHAT_UI_LAYER:-bottom}"
        resolve_runtime_paths
        exec 9> "${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.lock"
        flock 9
        # Session autostart must not call stop_ui: a late autostart --show used to
        # downgrade overlay back to bottom after the user had already unfolded home.
        if is_running; then
            exit 0
        fi
        start_ui
        ;;
    --show)
        if [ "${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-1}" != "1" ]; then
            log_action "runtime disabled (ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME=${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-0}); skipping show"
            exit 0
        fi
        wait_for_phosh_wayland_env || true
        desired_layer="${ATOMOS_OVERVIEW_CHAT_UI_LAYER:-bottom}"
        resolve_runtime_paths
        exec 9> "${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.lock"
        flock 9
        if is_running; then
            current_layer="$(cat "$LAYERFILE" 2>/dev/null || true)"
            if [ "$current_layer" = "$desired_layer" ]; then
                log_action "action=show wayland=${WAYLAND_DISPLAY:-<unset>} layer=${desired_layer} (already running)"
                exit 0
            fi
        fi
        log_action "action=show wayland=${WAYLAND_DISPLAY:-<unset>} layer=${desired_layer}"
        # Restart so a new ATOMOS_OVERVIEW_CHAT_UI_LAYER (overlay/bottom) applies.
        stop_ui
        printf '%s\n' "$desired_layer" > "$LAYERFILE"
        start_ui
        ;;
    --hide)
        resolve_runtime_paths
        exec 9> "${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.lock"
        flock 9
        log_action "action=hide"
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
sed_inplace "s/__OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS_DEFAULT__/${OVERVIEW_DISABLE_CUSTOM_CSS_DEFAULT}/g" "$tmpdir/atomos-overview-chat-ui-launcher"
sed_inplace "s/__OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS_DEFAULT__/${OVERVIEW_DISABLE_THEME_CLASS_DEFAULT}/g" "$tmpdir/atomos-overview-chat-ui-launcher"

render_autostart_desktop() {
    local out="$1"
    cat > "$out" <<'EOF'
[Desktop Entry]
Type=Application
Name=AtomOS Overview Chat UI
Comment=Layer-shell chat overlay that follows the Phosh home screen.
Exec=/usr/libexec/atomos-overview-chat-ui --start
Environment=ATOMOS_OVERVIEW_CHAT_UI_AUTOSTART_SPAWN=0
OnlyShowIn=GNOME;Phosh;
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Phase=Applications
EOF
}

AUTOSTART_TMP=""
if [ "$INSTALL_AUTOSTART" = "1" ]; then
    AUTOSTART_TMP="$tmpdir/atomos-overview-chat-ui.desktop"
    render_autostart_desktop "$AUTOSTART_TMP"
fi

INSTALL_DIRS='install -d /usr/local/bin /usr/libexec'
INSTALL_BIN_CMD='cat > /usr/local/bin/atomos-overview-chat-ui && chmod 755 /usr/local/bin/atomos-overview-chat-ui && ln -sf /usr/local/bin/atomos-overview-chat-ui /usr/bin/atomos-overview-chat-ui'
INSTALL_LAUNCHER_CMD='cat > /usr/libexec/atomos-overview-chat-ui && chmod 755 /usr/libexec/atomos-overview-chat-ui'
INSTALL_SUBMIT_CMD='cat > /usr/libexec/atomos-overview-chat-submit && chmod 755 /usr/libexec/atomos-overview-chat-submit'
VERIFY_CMD='test -x /usr/local/bin/atomos-overview-chat-ui && test -x /usr/bin/atomos-overview-chat-ui && test -x /usr/libexec/atomos-overview-chat-ui && test -x /usr/libexec/atomos-overview-chat-submit'

if [ -n "$DIRECT_ROOTFS_DIR" ]; then
    if [ ! -d "$DIRECT_ROOTFS_DIR" ]; then
        echo "ERROR: ROOTFS_DIR not a directory: $DIRECT_ROOTFS_DIR" >&2
        exit 1
    fi
    install -d "$DIRECT_ROOTFS_DIR/usr/local/bin" "$DIRECT_ROOTFS_DIR/usr/libexec" "$DIRECT_ROOTFS_DIR/usr/bin"

    if [ "$SKIP_BINARY_INSTALL" = "1" ]; then
        if [ ! -x "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-overview-chat-ui" ]; then
            echo "ERROR: ATOMOS_OVERVIEW_CHAT_UI_SKIP_BINARY_INSTALL=1 but no binary at $DIRECT_ROOTFS_DIR/usr/local/bin/atomos-overview-chat-ui" >&2
            exit 1
        fi
        echo "install-overview-chat-ui: ATOMOS_OVERVIEW_CHAT_UI_SKIP_BINARY_INSTALL=1; assuming caller pre-installed binary."
    else
        echo "install-overview-chat-ui: installing binary from $BIN_PATH"
        install -m 0755 "$BIN_PATH" "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-overview-chat-ui"
    fi
    # Relative symlink so it resolves correctly both at runtime (rootfs at /)
    # and when the rootfs is inspected under a /target mount (e.g. build-qemu
    # final-verify container). Absolute symlinks fail test -x under /target
    # because they dereference against the verify container's own root.
    ln -sf ../local/bin/atomos-overview-chat-ui "$DIRECT_ROOTFS_DIR/usr/bin/atomos-overview-chat-ui"
    install -m 0755 "$tmpdir/atomos-overview-chat-ui-launcher" "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-overview-chat-ui"
    install -m 0755 "$tmpdir/atomos-overview-chat-submit" "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-overview-chat-submit"
    if [ -n "$AUTOSTART_TMP" ]; then
        install -d "$DIRECT_ROOTFS_DIR/etc/xdg/autostart"
        install -m 0644 "$AUTOSTART_TMP" "$DIRECT_ROOTFS_DIR/etc/xdg/autostart/atomos-overview-chat-ui.desktop"
    fi
    test -x "$DIRECT_ROOTFS_DIR/usr/local/bin/atomos-overview-chat-ui"
    test -x "$DIRECT_ROOTFS_DIR/usr/bin/atomos-overview-chat-ui"
    test -x "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-overview-chat-ui"
    test -x "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-overview-chat-submit"
    if [ -n "$AUTOSTART_TMP" ]; then
        test -f "$DIRECT_ROOTFS_DIR/etc/xdg/autostart/atomos-overview-chat-ui.desktop"
        grep -q "Exec=/usr/libexec/atomos-overview-chat-ui --start" \
            "$DIRECT_ROOTFS_DIR/etc/xdg/autostart/atomos-overview-chat-ui.desktop"
        grep -q "ATOMOS_OVERVIEW_CHAT_UI_AUTOSTART_SPAWN=0" \
            "$DIRECT_ROOTFS_DIR/etc/xdg/autostart/atomos-overview-chat-ui.desktop"
        grep -q "OnlyShowIn=GNOME;Phosh;" \
            "$DIRECT_ROOTFS_DIR/etc/xdg/autostart/atomos-overview-chat-ui.desktop"
    fi
    grep -q "ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME" "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-overview-chat-ui"
    grep -q "atomos-overview-chat-ui.disabled" "$DIRECT_ROOTFS_DIR/usr/libexec/atomos-overview-chat-ui"
    if [ -n "$AUTOSTART_TMP" ] && [ "$OVERVIEW_RUNTIME_DEFAULT" != "1" ]; then
        echo "WARN: autostart installed but ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT=$OVERVIEW_RUNTIME_DEFAULT;" >&2
        echo "  the launcher's --show will be a no-op until ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME=1 is set." >&2
    fi
    echo "Installed overview chat UI into direct rootfs: $DIRECT_ROOTFS_DIR"
    exit 0
else
    echo "install-overview-chat-ui: installing binary from $BIN_PATH"
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_DIRS"
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_BIN_CMD" < "$BIN_PATH"
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_LAUNCHER_CMD" < "$tmpdir/atomos-overview-chat-ui-launcher"
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_SUBMIT_CMD" < "$tmpdir/atomos-overview-chat-submit"
    if [ -n "$AUTOSTART_TMP" ]; then
        INSTALL_AUTOSTART_DIR='install -d /etc/xdg/autostart'
        bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_AUTOSTART_DIR"
        INSTALL_AUTOSTART_CMD='cat > /etc/xdg/autostart/atomos-overview-chat-ui.desktop && chmod 644 /etc/xdg/autostart/atomos-overview-chat-ui.desktop'
        bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_AUTOSTART_CMD" < "$AUTOSTART_TMP"
    fi
    VERIFY_CMD="$VERIFY_CMD"
    if [ -n "$AUTOSTART_TMP" ]; then
        VERIFY_CMD="$VERIFY_CMD"' && test -f /etc/xdg/autostart/atomos-overview-chat-ui.desktop && grep -q "Exec=/usr/libexec/atomos-overview-chat-ui --start" /etc/xdg/autostart/atomos-overview-chat-ui.desktop'
    fi
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"
fi

echo "Installed overview chat UI binary and launch helpers."
