#!/bin/bash
# Install AtomOS default wallpaper via dbus + gsettings inside the pmbootstrap rootfs chroot.
# Writes the Phosh session user's dconf (postmarketOS uid 10000 or "user"), not only system
# local.d — Phosh reads per-user gsettings; system keyfiles can lose to site DB ordering.
# Run after the JPEG exists (see Makefile: stream into the chroot first).
#
# Image packages: config/*.env PMOS_EXTRA_PACKAGES should include dbus; Phosh normally pulls glib and
# gsettings-desktop-schemas. The inner script runs apk add if gsettings/dbus-run-session are missing.
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
if [ ! -f "$PROFILE_ENV_SOURCE" ]; then
    echo "Profile env not found: $PROFILE_ENV" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$PROFILE_ENV_SOURCE"

SCREENLOCK_IDLE_SECONDS="${ATOMOS_SCREENLOCK_IDLE_SECONDS:-${PMOS_SCREENLOCK_IDLE_SECONDS:-300}}"
SCREENLOCK_LOCK_DELAY_SECONDS="${ATOMOS_SCREENLOCK_LOCK_DELAY_SECONDS:-${PMOS_SCREENLOCK_LOCK_DELAY_SECONDS:-0}}"

if ! [[ "$SCREENLOCK_IDLE_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "Invalid screen lock idle delay (seconds): $SCREENLOCK_IDLE_SECONDS" >&2
    exit 1
fi
if ! [[ "$SCREENLOCK_LOCK_DELAY_SECONDS" =~ ^[0-9]+$ ]]; then
    echo "Invalid screen lock post-blank delay (seconds): $SCREENLOCK_LOCK_DELAY_SECONDS" >&2
    exit 1
fi

# Inner script runs under /bin/sh in the chroot (POSIX).
INNER_SCRIPT=$(cat <<'INNER'
set -e
WALL="/usr/share/backgrounds/gnome/gargantua-black.jpg"
if [ ! -f "$WALL" ] && [ -f /usr/share/backgrounds/gargantua-black.jpg ]; then
    WALL="/usr/share/backgrounds/gargantua-black.jpg"
fi
if [ ! -f "$WALL" ] && [ -f /usr/share/backgrounds/atomos/gargantua-black.jpg ]; then
    WALL="/usr/share/backgrounds/atomos/gargantua-black.jpg"
fi
if [ ! -f "$WALL" ]; then
    echo "atomos-wallpaper-dconf: skip (missing wallpaper JPEG under /usr/share/backgrounds/)"
    exit 0
fi

# Ensure CLI + schemas (glib=gsettings, gsettings-desktop-schemas=org.gnome.desktop.*).
if command -v apk >/dev/null 2>&1; then
    if ! command -v gsettings >/dev/null 2>&1 || ! command -v dbus-run-session >/dev/null 2>&1; then
        echo "atomos-wallpaper-dconf: apk add dbus glib gsettings-desktop-schemas" >&2
        apk add --no-interactive --quiet dbus glib gsettings-desktop-schemas 2>/dev/null || \
        apk add --no-interactive dbus glib gsettings-desktop-schemas || true
    fi
fi

if ! command -v gsettings >/dev/null 2>&1; then
    echo "WARN: gsettings not in chroot after apk (need glib); skipping wallpaper dconf apply" >&2
    exit 0
fi
if ! command -v dbus-run-session >/dev/null 2>&1; then
    echo "WARN: dbus-run-session not in chroot after apk (need dbus); skipping wallpaper dconf apply" >&2
    exit 0
fi

URI="file://$WALL"
IDLE_DELAY="__SCREENLOCK_IDLE_SECONDS__"
LOCK_DELAY="__SCREENLOCK_LOCK_DELAY_SECONDS__"
write_gs_script() {
    _out="$1"
    mkdir -p "$(dirname "$_out")"
    cat > "$_out" << EOS
#!/bin/sh
set -e
export HOME="$HOME"
URI="$URI"
IDLE_DELAY="$IDLE_DELAY"
LOCK_DELAY="$LOCK_DELAY"
export URI
dbus-run-session -- gsettings set org.gnome.desktop.background picture-uri "\$URI"
dbus-run-session -- gsettings set org.gnome.desktop.background picture-uri-dark "\$URI"
dbus-run-session -- gsettings set org.gnome.desktop.background picture-options zoom
dbus-run-session -- gsettings set org.gnome.desktop.screensaver picture-uri "\$URI"
dbus-run-session -- gsettings set org.gnome.desktop.screensaver picture-options zoom
dbus-run-session -- gsettings set org.gnome.desktop.session idle-delay "uint32 \$IDLE_DELAY"
dbus-run-session -- gsettings set org.gnome.desktop.screensaver lock-enabled true
dbus-run-session -- gsettings set org.gnome.desktop.screensaver lock-delay "uint32 \$LOCK_DELAY"
EOS
chmod +x "$_out"
}

run_as_user() {
    _u="$1"
    _h="$2"
    _t="$3"
    mkdir -p "$_h"
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "$_u" -- "$_t"
    else
        su "$_u" -c "export HOME=\"$_h\"; /bin/sh \"$_t\""
    fi
}

ok=0
tmpbase="/tmp/atomos-wallpaper-gsettings.$$"

# 1) postmarketOS default login user (uid 10000)
line=$(getent passwd 10000 2>/dev/null || true)
if [ -n "$line" ]; then
    u=$(printf '%s\n' "$line" | cut -d: -f1)
    h=$(printf '%s\n' "$line" | cut -d: -f6)
    if [ -n "$u" ] && [ -n "$h" ]; then
        t="$tmpbase.$u.sh"
        HOME="$h" write_gs_script "$t"
        if run_as_user "$u" "$h" "$t"; then
            echo "atomos-wallpaper-dconf: gsettings for uid 10000 ($u) HOME=$h"
            ok=1
        fi
        rm -f "$t"
    fi
fi

# 2) common name "user"
if [ "$ok" -eq 0 ] && id user >/dev/null 2>&1; then
    h="/home/user"
    t="$tmpbase.user.sh"
    HOME="$h" write_gs_script "$t"
    if run_as_user user "$h" "$t"; then
        echo "atomos-wallpaper-dconf: gsettings for user (HOME=$h)"
        ok=1
    fi
    rm -f "$t"
fi

# 3) seed /etc/skel so new accounts inherit wallpaper (also fallback if no login user yet)
if [ "${ATOMOS_WALLPAPER_DCONF_SKEL:-1}" = "1" ]; then
    sk="/etc/skel"
    t="$tmpbase.skel.sh"
    HOME="$sk" write_gs_script "$t"
    if sh "$t"; then
        echo "atomos-wallpaper-dconf: gsettings for HOME=$sk (skel)"
        ok=1
    fi
    rm -f "$t"
fi

if [ "$ok" -eq 0 ]; then
    echo "WARN: could not apply wallpaper gsettings (no uid 10000, no user, skel failed?)" >&2
    exit 0
fi
INNER
)

INNER_SCRIPT="${INNER_SCRIPT//__SCREENLOCK_IDLE_SECONDS__/$SCREENLOCK_IDLE_SECONDS}"
INNER_SCRIPT="${INNER_SCRIPT//__SCREENLOCK_LOCK_DELAY_SECONDS__/$SCREENLOCK_LOCK_DELAY_SECONDS}"

if [ "${ATOMOS_WALLPAPER_DCONF_DUMP_ONLY:-0}" = "1" ]; then
    printf '%s\n' "$INNER_SCRIPT"
    exit 0
fi

echo "Applying AtomOS wallpaper + lock timeout (idle=${SCREENLOCK_IDLE_SECONDS}s, lock-delay=${SCREENLOCK_LOCK_DELAY_SECONDS}s) in chroot (${PROFILE_NAME})..."
if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INNER_SCRIPT"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INNER_SCRIPT"
fi
