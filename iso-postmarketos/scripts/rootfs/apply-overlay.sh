#!/bin/bash
set -euo pipefail

# Two modes:
#   1) Default: $0 <profile-env>
#      Runs the overlay against pmbootstrap's rootfs chroot via pmb chroot -r.
#      Used by build-image.sh (the pmbootstrap path).
#
#   2) Direct rootfs: $0 --rootfs <rootfs-dir> [<profile-env>]
#      Runs the overlay against an arbitrary rootfs directory via
#      `chroot $ROOTFS /bin/sh`. Used by build-fairphone4.sh which builds
#      the rootfs in a docker volume (no pmbootstrap, /target instead of
#      pmbootstrap chroot path). Mirrors the --rootfs mode that
#      apply-atomos-phosh-dconf.sh already supports.
#
# Both modes apply the same OVERLAY_SCRIPT (Atom OS branding, sshd
# hardening, production atomos-overview-chat-ui launcher with the safety
# env defaults that prevent GTK4 GL crashes on FP4 hardware, etc.).
DIRECT_ROOTFS_DIR=""
if [ "${1:-}" = "--rootfs" ]; then
    if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
        echo "Usage: $0 --rootfs <rootfs-dir> [<profile-env>]" >&2
        echo "       $0 <profile-env>" >&2
        exit 1
    fi
    DIRECT_ROOTFS_DIR="${2%/}"
    if [ ! -d "$DIRECT_ROOTFS_DIR" ]; then
        echo "ERROR: rootfs directory not found: $DIRECT_ROOTFS_DIR" >&2
        exit 1
    fi
    if [ ! -x "$DIRECT_ROOTFS_DIR/bin/sh" ] && [ ! -x "$DIRECT_ROOTFS_DIR/bin/busybox" ]; then
        echo "ERROR: rootfs $DIRECT_ROOTFS_DIR has no /bin/sh or /bin/busybox; cannot chroot." >&2
        exit 1
    fi
    PROFILE_ENV="${3:-}"
    if [ -z "$PROFILE_ENV" ]; then
        # Fall back to the FP4 profile so the script keeps working when
        # callers don't pass a profile env (build-fairphone4.sh always does).
        PROFILE_ENV="config/fairphone-fp4.env"
    fi
elif [ "$#" -eq 1 ]; then
    PROFILE_ENV="$1"
else
    echo "Usage: $0 <profile-env>" >&2
    echo "       $0 --rootfs <rootfs-dir> [<profile-env>]" >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"

PMB="$PMB_HOST"
PROFILE_ENV_ARG="$PROFILE_ENV"
PMB_CONTAINER_ROOT=0
if [ -z "$DIRECT_ROOTFS_DIR" ] && { [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; }; then
    PMB="$PMB_CONTAINER"
    PMB_CONTAINER_ROOT=1
    if [[ "$PROFILE_ENV" == "$ROOT_DIR/"* ]]; then
        PROFILE_ENV_ARG="${PROFILE_ENV#"$ROOT_DIR"/}"
    fi
fi

PROFILE_ENV_SOURCE="$PROFILE_ENV"
if [ ! -f "$PROFILE_ENV_SOURCE" ] && [ -f "$ROOT_DIR/$PROFILE_ENV" ]; then
    PROFILE_ENV_SOURCE="$ROOT_DIR/$PROFILE_ENV"
fi
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "ERROR: profile env not found: $PROFILE_ENV" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"
LOCK_PARITY="${ATOMOS_LOCK_PARITY:-${PMOS_LOCK_PARITY:-1}}"
if [ "$LOCK_PARITY" != "0" ]; then
    LOCK_PARITY=1
fi
# Greetd auto-login skips Phrog and starts phosh-session directly under the
# build's PMOS_USER (uid PMOS_USER_UID). Default OFF; only the integration
# test profiles set PMOS_AUTOLOGIN=1 (override via ATOMOS_AUTOLOGIN at the
# script boundary). Production images keep Phrog as the greeter, matching
# upstream postmarketos-ui-phosh-openrc.
AUTOLOGIN="${ATOMOS_AUTOLOGIN:-${PMOS_AUTOLOGIN:-0}}"
if [ "$AUTOLOGIN" != "1" ]; then
    AUTOLOGIN=0
fi
AUTOLOGIN_USER="${PMOS_USER:-user}"
OVERVIEW_RUNTIME_DEFAULT="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT:-0}"
OVERVIEW_DISABLE_CUSTOM_CSS_DEFAULT="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS_DEFAULT:-0}"
OVERVIEW_DISABLE_THEME_CLASS_DEFAULT="${ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS_DEFAULT:-0}"
# v6 restores the XDG autostart .desktop for the chat UI. v5 (commit
# d6405345 "fix: home screen") deleted both the autostart .desktop AND
# the vendor phosh patches that spawned the layer-shell binary on home
# unfold (0003-atomos-overview-chat-ui-lifecycle.patch,
# 0004-atomos-overview-chat-ui-show-on-unfold.patch), so nothing left
# was actually launching atomos-overview-chat-ui on the home screen.
# v6 adds the autostart back; phosh-side spawn is handled in
# rust/phosh/phosh/src/home.c (atomos_phosh_sync_overview_chat_ui_lifecycle).
# Skip writing the autostart by setting ATOMOS_OVERVIEW_CHAT_UI_AUTOSTART=0.
OVERVIEW_AUTOSTART="${ATOMOS_OVERVIEW_CHAT_UI_AUTOSTART:-1}"
if [ "$OVERVIEW_AUTOSTART" != "0" ]; then
    OVERVIEW_AUTOSTART=1
fi
OVERVIEW_OVERLAY_CONTRACT_VERSION="overview-chat-ui-overlay-v6-autostart-restored"
HOME_BG_LIBGL_ALWAYS_SOFTWARE="${ATOMOS_HOME_BG_LIBGL_ALWAYS_SOFTWARE:-1}"
HOME_BG_GSK_RENDERER="${ATOMOS_HOME_BG_GSK_RENDERER:-cairo}"

echo "Applying mobile Phosh overlay via chroot..."
echo "  lock parity layer: $LOCK_PARITY"
echo "  greetd autologin: $AUTOLOGIN (user=$AUTOLOGIN_USER)"

# Read OVERLAY_SCRIPT from a here-doc rather than a single-quoted string so the
# script body may freely contain apostrophes (e.g. "Alpine's OpenDoas" in
# comments, the awk script in the lock-parity teardown branch) without each
# one closing the outer quote. The here-doc delimiter is quoted so $vars are
# left literal; placeholders like __LOCK_PARITY__ are filled in via the
# parameter-substitution chain below. `IFS= read -r -d '' VAR <<EOF` is used
# (instead of $(cat <<EOF)EOF\n)) because the launcher body contains a
# `case … ;;` block and bash mis-parses `;;` inside `$()` command
# substitution heredocs (it still tokenises the body when locating the
# matching `)`). `read -r -d ''` keeps the body opaque and exits with rc=1
# on EOF, hence the `|| true` tail.
IFS= read -r -d '' OVERLAY_SCRIPT << 'ATOMOS_OVERLAY_SCRIPT_EOF' || true
mkdir -p /etc/xdg/autostart
mkdir -p /etc/systemd/system
mkdir -p /etc/dconf/db/local.d

# Brand the OS as Atom OS while preserving postmarketOS internals for package
# and tooling compatibility.
if [ -f /etc/os-release ]; then
    sed -i "s|^PRETTY_NAME=.*|PRETTY_NAME=\"Atom OS\"|" /etc/os-release
    sed -i "s|^NAME=.*|NAME=\"Atom OS\"|" /etc/os-release
    sed -i "s|^LOGO=.*|LOGO=\"atomos-logo\"|" /etc/os-release
fi
if [ -f /usr/lib/os-release ]; then
    sed -i "s|^PRETTY_NAME=.*|PRETTY_NAME=\"Atom OS\"|" /usr/lib/os-release
    sed -i "s|^NAME=.*|NAME=\"Atom OS\"|" /usr/lib/os-release
    sed -i "s|^LOGO=.*|LOGO=\"atomos-logo\"|" /usr/lib/os-release
fi

# Replace default postmarketOS boot splash logo with Atom OS branding.
mkdir -p /usr/share/pbsplash
cat > /usr/share/pbsplash/pmos-logo-text.svg << "EOF"
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg xmlns="http://www.w3.org/2000/svg" width="640" height="160" viewBox="0 0 640 160">
  <rect width="640" height="160" fill="#0b0f17"/>
  <g transform="translate(44,30)">
    <polygon points="40,0 80,23 80,69 40,92 0,69 0,23" fill="#52d273"/>
    <polygon points="40,14 66,29 66,61 40,76 14,61 14,29" fill="#0b0f17"/>
  </g>
  <text x="160" y="78" fill="#ffffff" font-family="DejaVu Sans, sans-serif" font-size="56" font-weight="700">Atom OS</text>
  <text x="162" y="108" fill="#7ec8ff" font-family="DejaVu Sans, sans-serif" font-size="18">mobile Phosh</text>
</svg>
EOF

cat > /usr/share/pbsplash/pmos-logo-text-epaper.svg << "EOF"
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg xmlns="http://www.w3.org/2000/svg" width="640" height="160" viewBox="0 0 640 160">
  <rect width="640" height="160" fill="#ffffff"/>
  <g transform="translate(44,30)">
    <polygon points="40,0 80,23 80,69 40,92 0,69 0,23" fill="#000000"/>
    <polygon points="40,14 66,29 66,61 40,76 14,61 14,29" fill="#ffffff"/>
  </g>
  <text x="160" y="78" fill="#000000" font-family="DejaVu Sans, sans-serif" font-size="56" font-weight="700">Atom OS</text>
  <text x="162" y="108" fill="#000000" font-family="DejaVu Sans, sans-serif" font-size="18">mobile Phosh</text>
</svg>
EOF

# Wallpaper file + gsettings (dbus): scripts/rootfs/apply-atomos-wallpaper-dconf.sh (runs from Makefile even if MOBILE_PROFILE=0).

if [ "__LOCK_PARITY__" = "1" ]; then
    mkdir -p /etc/atomos
    # Gate (3): must match atomos-app-handler install contract version.
    echo "app-handler-v1-launch-switcher-dbus-home" > /etc/atomos/phosh-integration-contract
    chmod 0644 /etc/atomos/phosh-integration-contract
    cat > /etc/atomos/phosh-profile.env << "EOF"
ATOMOS_UI_PROFILE=phosh
ATOMOS_WALLPAPER=/usr/share/backgrounds/gnome/gargantua-black.jpg
# Phosh-side toggles for the AtomOS-fork phosh-overview integration. The
# legacy ATOMOS_PHOSH_ENABLE_SWIPE_BRIDGE knob has been retired now that the
# rust atomos-app-handler folded in the swipe-bridge socket and the bottom
# edge gesture. ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1 yields the bottom
# edge to the rust layer-shell handle, and ATOMOS_APP_HANDLER_TAKES_OVER=1
# hides PhoshOverview so the rust overlay owns the surface.
ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1
ATOMOS_APP_HANDLER_TAKES_OVER=1
ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1

# Hardware acceleration and renderer defaults for the background accretion disk wallpaper
ATOMOS_HOME_BG_LIBGL_ALWAYS_SOFTWARE=__HOME_BG_LIBGL_ALWAYS_SOFTWARE__
ATOMOS_HOME_BG_GSK_RENDERER=__HOME_BG_GSK_RENDERER__
EOF
    chmod 0644 /etc/atomos/phosh-profile.env
    # QEMU/dev SSH hotfixes: OpenDoas has no -S; allow wheel to run doas -n
    # without a TTY. Alpine's OpenDoas does NOT auto-include /etc/doas.d/, so
    # the rule must live in /etc/doas.conf directly (or be `include`d from it).
    # We append idempotently with a sentinel comment so re-running the overlay
    # is safe and doesn't duplicate the rule.
    if [ ! -f /etc/doas.conf ]; then
        : > /etc/doas.conf
        chmod 0400 /etc/doas.conf
    fi
    if ! grep -qF "# atomos-lock-parity-nopass-wheel" /etc/doas.conf; then
        {
            echo ""
            echo "# atomos-lock-parity-nopass-wheel: SSH hotfix/bisect scripts run doas -n"
            echo "# from non-TTY shells; OpenDoas has no -S so we grant nopass for :wheel."
            echo "permit nopass keepenv :wheel"
        } >> /etc/doas.conf
        chmod 0400 /etc/doas.conf
    fi
    # Old broken location (kept for cleanup of pre-fix images).
    rm -f /etc/doas.d/99-atomos-dev.conf
else
    mkdir -p /etc/atomos
    cat > /etc/atomos/phosh-profile.env << "EOF"
ATOMOS_UI_PROFILE=phosh
ATOMOS_PHOSH_DISABLE_BOTTOM_EDGE_DRAG=1
ATOMOS_APP_HANDLER_TAKES_OVER=1
ATOMOS_APP_HANDLER_ENABLE_RUNTIME=1
EOF
    chmod 0644 /etc/atomos/phosh-profile.env
    rm -f /etc/doas.d/99-atomos-dev.conf
    # Remove the sentinel block from /etc/doas.conf if present.
    if [ -f /etc/doas.conf ] && grep -qF "# atomos-lock-parity-nopass-wheel" /etc/doas.conf; then
        # Strip the 3-line block we appended (sentinel comment + continuation
        # comment + permit rule). The bare blank line that precedes the
        # sentinel is left in place; harmless even if accumulating.
        awk '
            BEGIN { skip = 0 }
            /^# atomos-lock-parity-nopass-wheel:/ { skip = 2; next }
            skip > 0                              { skip--;   next }
            { print }
        ' /etc/doas.conf > /etc/doas.conf.tmp \
            && mv /etc/doas.conf.tmp /etc/doas.conf \
            && chmod 0400 /etc/doas.conf
    fi
fi

# Greetd auto-login: gated, dev/test images only. Skips Phrog and starts
# phosh-session directly so integration tests can drive past the lock screen
# without typing into the QEMU display. The marker file is consumed by
# tests/test_lock_parity_scripts.py and tests/integration/test_qemu_phosh_login_lifetime.py.
if [ "__ATOMOS_AUTOLOGIN__" = "1" ]; then
    mkdir -p /etc/greetd /etc/atomos
    cat > /etc/greetd/config.toml << "GREETDEOF"
# AtomOS test image: skip the Phrog greeter and start phosh-session for the
# build user automatically. Re-enable Phrog by rebuilding with ATOMOS_AUTOLOGIN=0.
[terminal]
vt = 7

[default_session]
command = "/usr/libexec/phrog-greetd-session"
user = "greetd"

[initial_session]
command = "/usr/bin/phosh-session"
user = "__ATOMOS_AUTOLOGIN_USER__"
GREETDEOF
    chmod 0644 /etc/greetd/config.toml
    printf "%s\n" "__ATOMOS_AUTOLOGIN_USER__" > /etc/atomos/autologin-user
    chmod 0644 /etc/atomos/autologin-user
else
    rm -f /etc/atomos/autologin-user
fi

# ── SSH and USB gadget networking (developer USB Ethernet + sshd) ──

if command -v systemctl >/dev/null 2>&1; then
    # Phosh/systemd images may name the unit sshd.service or ssh.service.
    systemctl enable sshd.service 2>/dev/null || systemctl enable ssh.service 2>/dev/null || true
elif command -v rc-update >/dev/null 2>&1; then
    rc-update add sshd default 2>/dev/null || true
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl enable usb-moded.service 2>/dev/null || systemctl enable usb-moded 2>/dev/null || true
elif command -v rc-update >/dev/null 2>&1; then
    rc-update add usb-moded default 2>/dev/null || true
fi

if [ -f /etc/ssh/sshd_config ]; then
    sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
    sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
fi

# AtomOS: patched Phosh overview calls this when the user presses Enter in Message…
mkdir -p /usr/libexec
cat > /usr/libexec/atomos-overview-chat-submit << "EOF"
#!/bin/sh
set -eu
text=${1-}
logger -t atomos-overview-chat "len=${#text}"
EOF
chmod 755 /usr/libexec/atomos-overview-chat-submit

# Starter launcher for future Rust overview chat UI integration.
cat > /usr/libexec/atomos-overview-chat-ui << "EOF"
#!/bin/sh
set -eu
BIN="/usr/local/bin/atomos-overview-chat-ui"
# Default to toplevel fallback for hardware stability.
# Set ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL=1 to opt into layer-shell.
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL:-0}"
# Touch-dismiss can trigger compositor/input-stack instability on some phones.
# Keep disabled by default; set to 1 to opt in.
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS:-0}"
# Keep visible by default while diagnosing fold/unfold lifecycle issues.
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
# Keep layer defaults aligned with installer/hotfix launchers.
export ATOMOS_OVERVIEW_CHAT_UI_LAYER="${ATOMOS_OVERVIEW_CHAT_UI_LAYER:-bottom}"
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

bind_phosh_session_env() {
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
        # /proc/<pid>/environ is NUL-separated. BusyBox tr can mis-handle
        # \0 and corrupt values (e.g. wayland-0 -> wayland-n), so use
        # xargs -0 to split safely.
        line="$(xargs -0 -n1 < "$env_file" 2>/dev/null | awk -v k="$var" "index(\$0, k \"=\") == 1 { print; exit }" || true)"
        [ -n "$line" ] && export "$line"
    done

    # If imported display does not exist, clamp to a known-safe default.
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ] && [ ! -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
        if [ -S "${XDG_RUNTIME_DIR}/wayland-0" ]; then
            WAYLAND_DISPLAY="wayland-0"
            export WAYLAND_DISPLAY
            logger -t atomos-overview-chat-ui "corrected invalid WAYLAND_DISPLAY to wayland-0"
        fi
    fi
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
        printf "%s\n" "---- $(date) ----"
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
        bind_phosh_session_env
        logger -t atomos-overview-chat-ui "action=show wayland=${WAYLAND_DISPLAY:-<unset>} layer=${ATOMOS_OVERVIEW_CHAT_UI_LAYER:-bottom}"
        stop_ui
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
chmod 755 /usr/libexec/atomos-overview-chat-ui

mkdir -p /etc/atomos
rm -f /etc/atomos/overview-chat-ui-always-on
printf "%s\n" "__OVERVIEW_OVERLAY_CONTRACT_VERSION__" > /etc/atomos/overview-chat-ui-overlay-contract

rm -f /usr/libexec/atomos-overview-chat-ui-boot
rm -f /usr/lib/systemd/user/atomos-overview-chat-ui.service
rm -f /etc/systemd/user/default.target.wants/atomos-overview-chat-ui.service

# Restore XDG autostart for atomos-overview-chat-ui (commit d6405345 deleted
# this together with the vendor phosh patches that spawned the layer-shell
# binary on home unfold, leaving the chat UI with nothing to start it).
# The runtime gate ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME still applies, so
# this only takes effect when the profile sets RUNTIME_DEFAULT=1 (or the
# user-level env exports it explicitly).
if [ "__OVERVIEW_AUTOSTART__" = "1" ]; then
    cat > /etc/xdg/autostart/atomos-overview-chat-ui.desktop << "EOF"
[Desktop Entry]
Type=Application
Name=AtomOS Overview Chat UI
Comment=Layer-shell chat overlay that follows the Phosh home screen.
Exec=/usr/libexec/atomos-overview-chat-ui --start
OnlyShowIn=GNOME;Phosh;
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
    chmod 0644 /etc/xdg/autostart/atomos-overview-chat-ui.desktop
else
    rm -f /etc/xdg/autostart/atomos-overview-chat-ui.desktop
fi
ATOMOS_OVERLAY_SCRIPT_EOF

OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__LOCK_PARITY__/$LOCK_PARITY}"
OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__OVERVIEW_CHAT_UI_RUNTIME_DEFAULT__/$OVERVIEW_RUNTIME_DEFAULT}"
OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS_DEFAULT__/$OVERVIEW_DISABLE_CUSTOM_CSS_DEFAULT}"
OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS_DEFAULT__/$OVERVIEW_DISABLE_THEME_CLASS_DEFAULT}"
OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__OVERVIEW_OVERLAY_CONTRACT_VERSION__/$OVERVIEW_OVERLAY_CONTRACT_VERSION}"
OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__OVERVIEW_AUTOSTART__/$OVERVIEW_AUTOSTART}"
OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__ATOMOS_AUTOLOGIN__/$AUTOLOGIN}"
OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__ATOMOS_AUTOLOGIN_USER__/$AUTOLOGIN_USER}"
OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__HOME_BG_LIBGL_ALWAYS_SOFTWARE__/$HOME_BG_LIBGL_ALWAYS_SOFTWARE}"
OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__HOME_BG_GSK_RENDERER__/$HOME_BG_GSK_RENDERER}"

if [ "${ATOMOS_OVERLAY_DUMP_ONLY:-0}" = "1" ]; then
    printf '%s\n' "$OVERLAY_SCRIPT"
    exit 0
fi

if [ -n "$DIRECT_ROOTFS_DIR" ]; then
    # --rootfs mode: run OVERLAY_SCRIPT inside the rootfs via host chroot.
    # Caller must already be root (build-fairphone4.sh runs us inside a
    # privileged docker container that's effectively root). We rely on the
    # rootfs having /bin/sh available (Alpine ships busybox), which the
    # arg-parse block above already verified.
    #
    # Why chroot and not "bash $script with paths prefixed by $ROOTFS"?
    # The script does `systemctl enable sshd.service` / `rc-update add sshd
    # default` / `chroot ... ssh-keygen` -- all of which need to resolve
    # paths INSIDE the rootfs's view of the world, not the container's.
    # chroot fixes that uniformly without per-line rewrites.
    echo "Applying mobile Phosh overlay in --rootfs $DIRECT_ROOTFS_DIR ..."
    chroot "$DIRECT_ROOTFS_DIR" /bin/sh -eu -c "$OVERLAY_SCRIPT"
elif [ "$PMB_CONTAINER_ROOT" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$OVERLAY_SCRIPT"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$OVERLAY_SCRIPT"
fi

echo "Overlay applied."
