#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"

PMB="$PMB_HOST"
PROFILE_ENV_ARG="$PROFILE_ENV"
PMB_CONTAINER_ROOT=0
if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
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
# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"
LOCK_PARITY="${ATOMOS_LOCK_PARITY:-${PMOS_LOCK_PARITY:-1}}"
if [ "$LOCK_PARITY" != "0" ]; then
    LOCK_PARITY=1
fi
OVERVIEW_RUNTIME_DEFAULT="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME_DEFAULT:-1}"
case "${PMOS_DEVICE:-}" in
    qemu-*|qemu_*)
        OVERVIEW_RUNTIME_DEFAULT=0
        ;;
esac

echo "Applying mobile Phosh overlay via chroot..."
echo "  lock parity layer: $LOCK_PARITY"

OVERLAY_SCRIPT='
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
    cat > /etc/atomos/phosh-profile.env << "EOF"
ATOMOS_UI_PROFILE=phosh
ATOMOS_WALLPAPER=/usr/share/backgrounds/gnome/gargantua-black.jpg
EOF
else
    rm -f /etc/atomos/phosh-profile.env
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
# Default to non-layer mode for QEMU/older compositor stability.
# Set ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL=1 to opt into layer-shell.
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL:-0}"
# Touch-dismiss can trigger compositor/input-stack instability on some phones.
# Keep disabled by default; set to 1 to opt in.
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS:-0}"
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
export ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME="${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME:-__OVERVIEW_CHAT_UI_RUNTIME_DEFAULT__}"
# Phosh runs this as the logged-in user; /run/ is root-only. Use the session dir.
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.pid"
LOGFILE="${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.log"
DISABLE_FILE="${XDG_RUNTIME_DIR:-/tmp}/atomos-overview-chat-ui.disabled"

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
chmod 755 /usr/libexec/atomos-overview-chat-ui
'

OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__LOCK_PARITY__/$LOCK_PARITY}"
OVERLAY_SCRIPT="${OVERLAY_SCRIPT//__OVERVIEW_CHAT_UI_RUNTIME_DEFAULT__/$OVERVIEW_RUNTIME_DEFAULT}"

if [ "${ATOMOS_OVERLAY_DUMP_ONLY:-0}" = "1" ]; then
    printf '%s\n' "$OVERLAY_SCRIPT"
    exit 0
fi

if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$OVERLAY_SCRIPT"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$OVERLAY_SCRIPT"
fi

echo "Overlay applied."
