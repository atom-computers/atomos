#!/bin/bash
# Install atomos-app-handler into a rootfs.
#
# Mirrors scripts/home-bg/install-atomos-home-bg.sh in shape; two modes,
# auto-picked by the presence of `ROOTFS_DIR`:
#
#   pmbootstrap mode   (no ROOTFS_DIR set)
#     Uses scripts/pmb/pmb.sh to chroot into the pmbootstrap-managed rootfs.
#     Used by build-image.sh on the FP4 path.
#
#   direct mode        (ROOTFS_DIR=/path/to/rootfs)
#     Writes files straight into the given rootfs tree. Used by
#     build-qemu.sh / build-fairphone4*.sh container overlay steps.
#
# Both modes install:
#   /usr/local/bin/atomos-app-handler              (binary)
#   /usr/bin/atomos-app-handler                    (symlink)
#   /usr/libexec/atomos-app-handler                (lifecycle launcher)
#   /etc/atomos/app-handler-contract       (lifecycle marker)
#   /etc/xdg/autostart/atomos-app-handler.desktop  (handle-bar autostart)
#
# Architecture (lifecycle-controlled overlay on top of an autostarted
# handle bar):
#   - The binary autostarts at session login to render the 24 px bottom-edge
#     handle bar (matches the egui preview's swipe-up affordance).
#   - Phosh's home state transitions drive `--show` / `--hide`; the launcher
#     signals the running handle process (SIGUSR1=show, SIGUSR2=hide) so the
#     switcher *overlay surface* maps/unmaps without restarting the bar.
#   - The contract marker asserts the lifecycle wiring at final-verify time.
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

APP_HANDLER_RUNTIME_DEFAULT="${ATOMOS_APP_HANDLER_ENABLE_RUNTIME_DEFAULT:-1}"
SKIP_BINARY_INSTALL="${ATOMOS_APP_HANDLER_SKIP_BINARY_INSTALL:-0}"
INSTALL_AUTOSTART="${ATOMOS_APP_HANDLER_INSTALL_AUTOSTART:-1}"
TARGET_TRIPLE="${ATOMOS_APP_HANDLER_TARGET_TRIPLE:-aarch64-unknown-linux-musl}"
APP_HANDLER_CONTRACT_VERSION="${ATOMOS_APP_HANDLER_OVERLAY_CONTRACT_VERSION:-${ATOMOS_STACK_INTEGRATION_VERSION:-app-handler-v1-launch-switcher-dbus-home}}"
CRATE_DIR="$ROOT_DIR/rust/atomos-app-handler"
PMB="$ROOT_DIR/scripts/pmb/pmb.sh"

candidate_bin_paths() {
    if [ -n "${ATOMOS_APP_HANDLER_BIN_PATH:-}" ]; then
        printf '%s\n' "$ATOMOS_APP_HANDLER_BIN_PATH"
    fi
    printf '%s\n' "$CRATE_DIR/target/$TARGET_TRIPLE/release/atomos-app-handler"
    printf '%s\n' "$CRATE_DIR/target/release/atomos-app-handler"
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

# Lifecycle launcher — same pattern as scripts/home-bg/install-atomos-home-bg.sh:
# pidfile + log under XDG_RUNTIME_DIR, optional disable marker, Wayland env
# auto-bind from phosh's /proc/<pid>/environ if launched outside the session.
render_launcher() {
    local out="$1"
    cat > "$out" <<'EOF'
#!/bin/sh
# /usr/libexec/atomos-app-handler: lifecycle wrapper for the app-switcher
# overlay surface. Mirrors the launcher pattern used by atomos-home-bg.
set -eu
BIN="/usr/local/bin/atomos-app-handler"
export ATOMOS_APP_HANDLER_ENABLE_RUNTIME="${ATOMOS_APP_HANDLER_ENABLE_RUNTIME:-__APP_HANDLER_RUNTIME_DEFAULT__}"
export GDK_BACKEND="${GDK_BACKEND:-wayland}"

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
    PIDFILE="$runtime/atomos-app-handler.pid"
    LOGFILE="$runtime/atomos-app-handler.log"
    DISABLE_FILE="$runtime/atomos-app-handler.disabled"
}

bind_phosh_session_env_if_missing() {
    [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && return 0
    if ! command -v pgrep >/dev/null 2>&1; then
        logger -t atomos-app-handler "pgrep unavailable; cannot auto-bind Wayland env"
        return 0
    fi
    phosh_pid="$(pgrep phosh | head -n 1 || true)"
    if [ -z "$phosh_pid" ]; then
        logger -t atomos-app-handler "phosh pid not found; WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
        return 0
    fi
    env_file="/proc/$phosh_pid/environ"
    [ -r "$env_file" ] || return 0
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

running_pid() {
    resolve_runtime_paths
    [ -f "$PIDFILE" ] || return 1
    pid="$(cat "$PIDFILE" 2>/dev/null || true)"
    [ -n "$pid" ] || return 1
    if kill -0 "$pid" 2>/dev/null; then
        printf '%s' "$pid"
        return 0
    fi
    return 1
}

is_running() {
    running_pid >/dev/null
}

# Start the handle-bar process. Idempotent: returns early if the binary
# is already running. The handle window is opaque only over a 24 px strip
# at the bottom edge; the rest of the layer-shell surface is hidden.
start_handle() {
    resolve_runtime_paths
    if [ "${ATOMOS_APP_HANDLER_ENABLE_RUNTIME:-0}" != "1" ]; then
        logger -t atomos-app-handler "runtime disabled; skipping start"
        return 0
    fi
    [ -x "$BIN" ] || { logger -t atomos-app-handler "binary not installed; no-op start"; return 0; }
    if is_running; then
        return 0
    fi
    if [ -f "$DISABLE_FILE" ]; then
        logger -t atomos-app-handler "runtime disabled by marker: $DISABLE_FILE"
        return 0
    fi
    (
        printf '%s\n' "---- $(date) ----"
        set +e
        "$BIN" --start
        rc=$?
        if [ "$rc" -eq 127 ]; then
            : > "$DISABLE_FILE"
            logger -t atomos-app-handler "exec rc=127; wrote disable marker $DISABLE_FILE"
        fi
        logger -t atomos-app-handler "process-exit rc=$rc"
        exit "$rc"
    ) >>"$LOGFILE" 2>&1 &
    pid=$!
    echo "$pid" > "$PIDFILE"
    sleep 0.2
    if ! kill -0 "$pid" 2>/dev/null; then
        logger -t atomos-app-handler "exited immediately; log: $LOGFILE"
        rm -f "$PIDFILE"
    fi
}

# Signal the running handle process to (un)map the switcher overlay
# surface. The binary installs glib unix-signal handlers for SIGUSR1 /
# SIGUSR2 -- see rust/atomos-app-handler/app-gtk/src/linux.rs.
# Falls back to (re)starting the handle process so even a cold session
# converges: if `--show` arrives before the autostart fired we still end
# up with a visible bar and the overlay open.
signal_show() {
    pid="$(running_pid || true)"
    if [ -n "$pid" ]; then
        kill -USR1 "$pid" 2>/dev/null || true
        logger -t atomos-app-handler "show-signal pid=$pid"
        return 0
    fi
    logger -t atomos-app-handler "show-signal: handle not running; starting now"
    start_handle
}

signal_hide() {
    pid="$(running_pid || true)"
    if [ -n "$pid" ]; then
        kill -USR2 "$pid" 2>/dev/null || true
        logger -t atomos-app-handler "hide-signal pid=$pid"
    fi
}

stop_handle() {
    pid="$(running_pid || true)"
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE"
}

case "${1:-}" in
    --start)
        bind_phosh_session_env_if_missing
        logger -t atomos-app-handler "action=start wayland=${WAYLAND_DISPLAY:-<unset>}"
        start_handle
        ;;
    --show)
        bind_phosh_session_env_if_missing
        logger -t atomos-app-handler "action=show wayland=${WAYLAND_DISPLAY:-<unset>}"
        signal_show
        ;;
    --hide)
        logger -t atomos-app-handler "action=hide"
        signal_hide
        ;;
    --stop)
        logger -t atomos-app-handler "action=stop"
        stop_handle
        ;;
    --restart)
        stop_handle
        bind_phosh_session_env_if_missing
        start_handle
        ;;
    launch)
        bind_phosh_session_env_if_missing
        logger -t atomos-app-handler "action=launch app=${2:-<unset>}"
        exec "$BIN" launch "${2:-}"
        ;;
    *)
        if [ -x "$BIN" ]; then
            exec "$BIN" "$@"
        fi
        logger -t atomos-app-handler "binary not installed; no-op"
        ;;
esac
EOF
    sed_inplace "s/__APP_HANDLER_RUNTIME_DEFAULT__/${APP_HANDLER_RUNTIME_DEFAULT}/g" "$out"
}

# XDG autostart entry. phosh-session walks /etc/xdg/autostart at login and
# Execs each enabled .desktop. OnlyShowIn=Phosh;GNOME so non-phosh sessions
# (bare X11, kiosk Cage, etc.) don't try to launch a layer-shell binary
# against a compositor that doesn't speak the protocol.
render_autostart_desktop() {
    local out="$1"
    cat > "$out" <<'EOF'
[Desktop Entry]
Type=Application
Name=AtomOS App Handler
Comment=Bottom-edge swipe-up app switcher overlay (replaces PhoshOverview)
Exec=/usr/libexec/atomos-app-handler --start
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Phase=Applications
OnlyShowIn=GNOME;Phosh;
EOF
}

# Lifecycle-only contract marker. build-image/build-qemu/build-fairphone
# verify this file so regressions fail the build instead of silently
# reintroducing autostart ownership.
ensure_stack_integration_contracts_in_root() {
    local root="$1"
    install -d "$root/etc/atomos"
    printf '%s\n' "$APP_HANDLER_CONTRACT_VERSION" > "$root/etc/atomos/app-handler-contract"
    printf '%s\n' "$APP_HANDLER_CONTRACT_VERSION" > "$root/etc/atomos/phosh-integration-contract"
    chmod 0644 "$root/etc/atomos/app-handler-contract" "$root/etc/atomos/phosh-integration-contract"
}

ensure_app_handler_contract_in_root() {
    ensure_stack_integration_contracts_in_root "$1"
}

# phosh-session.in sources this before starting phoc + gnome-session --session=phosh.
# Must exist on the rootfs whenever the handler is installed (not only lock-parity overlay).
ensure_phosh_profile_env_in_root() {
    local root="$1"
    install -d "$root/etc/atomos"
    cat > "$root/etc/atomos/phosh-profile.env" <<'EOF'
ATOMOS_UI_PROFILE=phosh
ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1
ATOMOS_APP_HANDLER_TAKES_OVER=1
ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1
EOF
    chmod 0644 "$root/etc/atomos/phosh-profile.env"
}

sync_autostart_state_in_root() {
    local root="$1"
    local autostart_tmp="${2:-}"
    local autostart_path="$root/etc/xdg/autostart/atomos-app-handler.desktop"
    if [ -n "$autostart_tmp" ]; then
        install -d "$root/etc/xdg/autostart"
        install -m 0644 "$autostart_tmp" "$autostart_path"
        return 0
    fi
    rm -f "$autostart_path"
}

install_into_root() {
    local root="$1"
    local bin_path="$2"
    local launcher_tmp="$3"
    local autostart_tmp="${4:-}"

    install -d "$root/usr/local/bin" "$root/usr/bin" "$root/usr/libexec"
    if [ "$SKIP_BINARY_INSTALL" = "1" ]; then
        if [ ! -x "$root/usr/local/bin/atomos-app-handler" ]; then
            echo "ERROR: ATOMOS_APP_HANDLER_SKIP_BINARY_INSTALL=1 but no binary at $root/usr/local/bin/atomos-app-handler" >&2
            exit 1
        fi
        echo "install-app-handler: ATOMOS_APP_HANDLER_SKIP_BINARY_INSTALL=1; assuming caller pre-installed binary."
    else
        install -m 0755 "$bin_path" "$root/usr/local/bin/atomos-app-handler"
    fi
    # Relative symlink so the rootfs verify container can dereference it
    # under /target without falling back to the host root.
    ln -sf ../local/bin/atomos-app-handler "$root/usr/bin/atomos-app-handler"
    install -m 0755 "$launcher_tmp" "$root/usr/libexec/atomos-app-handler"
    sync_autostart_state_in_root "$root" "$autostart_tmp"
    ensure_app_handler_contract_in_root "$root"
    ensure_phosh_profile_env_in_root "$root"

    test -x "$root/usr/local/bin/atomos-app-handler"
    test -x "$root/usr/bin/atomos-app-handler"
    test -x "$root/usr/libexec/atomos-app-handler"
    grep -q "ATOMOS_APP_HANDLER_ENABLE_RUNTIME" "$root/usr/libexec/atomos-app-handler"
    grep -q "atomos-app-handler.disabled"       "$root/usr/libexec/atomos-app-handler"
    # Hybrid contract: the launcher must signal the autostarted handle
    # process when phosh fires --show / --hide instead of spawning a
    # second binary, otherwise the always-visible swipe bar dies the
    # moment the overlay is dismissed.
    grep -q "signal_show"  "$root/usr/libexec/atomos-app-handler"
    grep -q "signal_hide"  "$root/usr/libexec/atomos-app-handler"
    grep -q "kill -USR1"   "$root/usr/libexec/atomos-app-handler"
    grep -q "kill -USR2"   "$root/usr/libexec/atomos-app-handler"
    test -f "$root/etc/atomos/app-handler-contract"
    test -f "$root/etc/atomos/phosh-integration-contract"
    grep -q "^$APP_HANDLER_CONTRACT_VERSION$" \
        "$root/etc/atomos/app-handler-contract"
    grep -q "^$APP_HANDLER_CONTRACT_VERSION$" \
        "$root/etc/atomos/phosh-integration-contract"
    test -f "$root/etc/atomos/phosh-profile.env"
    grep -q '^ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1' "$root/etc/atomos/phosh-profile.env"
    grep -q '^ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1' "$root/etc/atomos/phosh-profile.env"
    if [ -n "$autostart_tmp" ]; then
        test -f "$root/etc/xdg/autostart/atomos-app-handler.desktop"
        grep -q "Exec=/usr/libexec/atomos-app-handler --start" "$root/etc/xdg/autostart/atomos-app-handler.desktop"
    else
        test ! -e "$root/etc/xdg/autostart/atomos-app-handler.desktop"
    fi
    if [ -n "$autostart_tmp" ] && [ "$APP_HANDLER_RUNTIME_DEFAULT" != "1" ]; then
        echo "WARN: autostart installed but ATOMOS_APP_HANDLER_ENABLE_RUNTIME_DEFAULT=$APP_HANDLER_RUNTIME_DEFAULT;" >&2
        echo "  the launcher's --start will be a no-op until ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1 is set." >&2
    fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

LAUNCHER_TMP="$tmpdir/atomos-app-handler-launcher"
render_launcher "$LAUNCHER_TMP"

AUTOSTART_TMP=""
if [ "$INSTALL_AUTOSTART" = "1" ]; then
    AUTOSTART_TMP="$tmpdir/atomos-app-handler.desktop"
    render_autostart_desktop "$AUTOSTART_TMP"
fi

# ---------- direct rootfs mode ----------
if [ -n "$DIRECT_ROOTFS_DIR" ]; then
    if [ ! -d "$DIRECT_ROOTFS_DIR" ]; then
        echo "ERROR: ROOTFS_DIR not a directory: $DIRECT_ROOTFS_DIR" >&2
        exit 1
    fi
    BIN_PATH=""
    if [ "$SKIP_BINARY_INSTALL" != "1" ]; then
        BIN_PATH="$(resolve_bin_path || true)"
        if [ -z "$BIN_PATH" ]; then
            echo "ERROR: atomos-app-handler binary not found in any candidate path:" >&2
            candidate_bin_paths | sed 's/^/  /' >&2
            echo "  Set ATOMOS_APP_HANDLER_BIN_PATH=... to override, or" >&2
            echo "  ATOMOS_APP_HANDLER_SKIP_BINARY_INSTALL=1 if the caller already placed the binary." >&2
            exit 1
        fi
        echo "install-app-handler: installing binary from $BIN_PATH"
    fi
    install_into_root "$DIRECT_ROOTFS_DIR" "$BIN_PATH" "$LAUNCHER_TMP" "$AUTOSTART_TMP"
    echo "Installed atomos-app-handler into direct rootfs: $DIRECT_ROOTFS_DIR"
    exit 0
fi

# ---------- pmbootstrap chroot mode ----------
BIN_PATH="$(resolve_bin_path || true)"
if [ -z "$BIN_PATH" ]; then
    echo "ERROR: install-app-handler: no prebuilt binary found." >&2
    candidate_bin_paths | sed 's/^/  expected: /' >&2
    exit 1
fi
echo "install-app-handler: installing binary from $BIN_PATH"

# Ensure GTK4 + gtk4-layer-shell runtime libs are present. atomos-app-handler
# links against:
#   libgtk-4.so / libgio / libglib (from gtk4.0)
#   libgtk4-layer-shell.so          (from gtk4-layer-shell)
#   libwayland-client.so            (from wayland-libs)
# wayland-libs is part of the base; gtk4-layer-shell is *not* pulled by
# the standard phosh stack, so we apk-add it defensively here. Idempotent.
ENSURE_RUNTIME_DEPS_CMD='set -eu;
have_pkg() { apk info -e "$1" >/dev/null 2>&1; }
need=""
for p in gtk4.0 gtk4-layer-shell; do
    if ! have_pkg "$p"; then
        need="$need $p"
    fi
done
if [ -n "$need" ]; then
    echo "install-app-handler: installing runtime libs in rootfs:$need"
    apk update >/dev/null 2>&1 || true
    apk add --no-interactive $need
fi'
if ! bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$ENSURE_RUNTIME_DEPS_CMD"; then
    echo "WARN: install-app-handler: failed to apk-install runtime libs in rootfs." >&2
fi

bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c 'install -d /usr/local/bin /usr/bin /usr/libexec /etc/xdg/autostart'

INSTALL_BIN_CMD='cat > /usr/local/bin/atomos-app-handler && chmod 755 /usr/local/bin/atomos-app-handler && ln -sf /usr/local/bin/atomos-app-handler /usr/bin/atomos-app-handler'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_BIN_CMD" < "$BIN_PATH"

INSTALL_LAUNCHER_CMD='cat > /usr/libexec/atomos-app-handler && chmod 755 /usr/libexec/atomos-app-handler'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_LAUNCHER_CMD" < "$LAUNCHER_TMP"

ENSURE_LIFECYCLE_CONTRACT_CMD='set -eu
install -d /etc/atomos
printf "%s\n" "'"$APP_HANDLER_CONTRACT_VERSION"'" > /etc/atomos/app-handler-contract
printf "%s\n" "'"$APP_HANDLER_CONTRACT_VERSION"'" > /etc/atomos/phosh-integration-contract
chmod 0644 /etc/atomos/app-handler-contract /etc/atomos/phosh-integration-contract'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$ENSURE_LIFECYCLE_CONTRACT_CMD"

ENSURE_PHOSH_PROFILE_CMD='set -eu
install -d /etc/atomos
cat > /etc/atomos/phosh-profile.env <<EOF
ATOMOS_UI_PROFILE=phosh
ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1
ATOMOS_APP_HANDLER_TAKES_OVER=1
ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1
EOF
chmod 0644 /etc/atomos/phosh-profile.env'
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$ENSURE_PHOSH_PROFILE_CMD"

if [ -n "$AUTOSTART_TMP" ]; then
    INSTALL_AUTOSTART_CMD='cat > /etc/xdg/autostart/atomos-app-handler.desktop && chmod 644 /etc/xdg/autostart/atomos-app-handler.desktop'
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$INSTALL_AUTOSTART_CMD" < "$AUTOSTART_TMP"
else
    REMOVE_AUTOSTART_CMD='rm -f /etc/xdg/autostart/atomos-app-handler.desktop'
    bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$REMOVE_AUTOSTART_CMD"
fi

VERIFY_CMD='test -x /usr/local/bin/atomos-app-handler && test -x /usr/bin/atomos-app-handler && test -x /usr/libexec/atomos-app-handler && grep -q "ATOMOS_APP_HANDLER_ENABLE_RUNTIME" /usr/libexec/atomos-app-handler && grep -q "atomos-app-handler.disabled" /usr/libexec/atomos-app-handler && grep -q "signal_show" /usr/libexec/atomos-app-handler && grep -q "signal_hide" /usr/libexec/atomos-app-handler && grep -q "kill -USR1" /usr/libexec/atomos-app-handler && grep -q "kill -USR2" /usr/libexec/atomos-app-handler && test -f /etc/atomos/app-handler-contract && test -f /etc/atomos/phosh-integration-contract && grep -q "^'"$APP_HANDLER_CONTRACT_VERSION"'$" /etc/atomos/app-handler-contract && grep -q "^'"$APP_HANDLER_CONTRACT_VERSION"'$" /etc/atomos/phosh-integration-contract && test -f /etc/atomos/phosh-profile.env && grep -q "^ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1$" /etc/atomos/phosh-profile.env'
if [ -n "$AUTOSTART_TMP" ]; then
    VERIFY_CMD="$VERIFY_CMD"' && test -f /etc/xdg/autostart/atomos-app-handler.desktop && grep -q "Exec=/usr/libexec/atomos-app-handler --start" /etc/xdg/autostart/atomos-app-handler.desktop'
else
    VERIFY_CMD="$VERIFY_CMD"' && test ! -e /etc/xdg/autostart/atomos-app-handler.desktop'
fi
bash "$PMB" "$PROFILE_ENV_SOURCE" chroot -r -- /bin/sh -eu -c "$VERIFY_CMD"

echo "Installed atomos-app-handler into pmbootstrap rootfs."
