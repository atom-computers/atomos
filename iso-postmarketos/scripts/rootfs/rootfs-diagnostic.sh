#!/bin/bash
# Print Phosh / overlay hints from inside the pmbootstrap rootfs chroot (not the build host).
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env>" >&2
    exit 1
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"

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

PMB="$PMB_HOST"
PROFILE_ENV_ARG="$PROFILE_ENV"
PMB_CONTAINER_ROOT=0
if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
    PMB="$PMB_CONTAINER"
    PMB_CONTAINER_ROOT=1
    if [[ "$PROFILE_ENV_SOURCE" == "$ROOT_DIR/"* ]]; then
        PROFILE_ENV_ARG="${PROFILE_ENV_SOURCE#"$ROOT_DIR"/}"
    else
        PROFILE_ENV_ARG="$PROFILE_ENV_SOURCE"
    fi
fi

echo "=== PRE-EXPORT ROOTFS DIAGNOSTIC (inside chroot: ${PROFILE_NAME}) ==="

# Do not use set -e inside chroot so we print all sections.
INNER_SCRIPT='
set +e
echo "--- phosh ---"
if command -v phosh >/dev/null 2>&1; then
    command -v phosh
    ls -la "$(command -v phosh)" 2>&1
elif [ -x /usr/bin/phosh ]; then
    echo "FOUND /usr/bin/phosh but not on PATH (PATH=${PATH:-})"
    ls -la /usr/bin/phosh 2>&1
else
    echo "NOT FOUND (PATH=${PATH:-})"
    for p in /usr/bin/phosh /usr/libexec/phosh; do
        if [ -e "$p" ]; then
            ls -la "$p" 2>&1
        fi
    done
fi
echo "--- /etc/atomos/phosh-profile.env ---"
if [ -f /etc/atomos/phosh-profile.env ]; then
    cat /etc/atomos/phosh-profile.env
else
    echo "(missing)"
fi
echo "--- wallpaper ---"
if [ -f /usr/share/backgrounds/gnome/gargantua-black.jpg ]; then
    ls -la /usr/share/backgrounds/gnome/gargantua-black.jpg
elif [ -f /usr/share/backgrounds/gargantua-black.jpg ]; then
    ls -la /usr/share/backgrounds/gargantua-black.jpg
elif [ -f /usr/share/backgrounds/atomos/gargantua-black.jpg ]; then
    ls -la /usr/share/backgrounds/atomos/gargantua-black.jpg
else
    echo "MISSING"
    ls -la /usr/share/backgrounds/ 2>&1 || true
    ls -la /usr/share/backgrounds/atomos/ 2>&1 || true
fi
echo "--- dconf wallpaper local.d legacy (if present) ---"
if [ -f /etc/dconf/db/local.d/50-atomos-wallpaper.conf ]; then
    cat /etc/dconf/db/local.d/50-atomos-wallpaper.conf
else
    echo "(missing — wallpaper may be in user gsettings only)"
fi
echo "--- uid 10000 home dconf (wallpaper lives here after apply-atomos-wallpaper-dconf.sh) ---"
line=$(getent passwd 10000 2>/dev/null || true)
if [ -n "$line" ]; then
    h=$(printf '%s\n' "$line" | cut -d: -f6)
    if [ -n "$h" ] && [ -d "$h/.config/dconf" ]; then
        ls -la "$h/.config/dconf" 2>&1 || true
    else
        echo "(no $h/.config/dconf yet)"
    fi
else
    echo "(no uid 10000 in passwd)"
fi
echo "--- dconf Phosh favorites (if present) ---"
if [ -f /etc/dconf/db/local.d/51-atomos-phosh-favorites.conf ]; then
    cat /etc/dconf/db/local.d/51-atomos-phosh-favorites.conf
else
    echo "(missing)"
fi
echo "--- dconf locks (if present) ---"
if [ -f /etc/dconf/db/local.d/locks/50-atomos-wallpaper ]; then
    cat /etc/dconf/db/local.d/locks/50-atomos-wallpaper
else
    echo "(missing)"
fi
echo "--- dconf profile user ---"
if [ -f /etc/dconf/profile/user ]; then
    cat /etc/dconf/profile/user
else
    echo "(missing)"
fi
echo "--- dconf compiled db ---"
if [ -f /etc/dconf/db/local ]; then
    ls -la /etc/dconf/db/local
else
    echo "(missing)"
fi
echo "--- gsettings effective wallpaper (if available) ---"
# Root in an empty HOME sees schema defaults; prefer uid 10000 / user when present.
if command -v gsettings >/dev/null 2>&1; then
    line=$(getent passwd 10000 2>/dev/null || true)
    if [ -n "$line" ]; then
        u=$(printf '%s\n' "$line" | cut -d: -f1)
        h=$(printf '%s\n' "$line" | cut -d: -f6)
        if [ -n "$u" ] && [ -n "$h" ] && [ -d "$h" ]; then
            echo "(as uid 10000: $u HOME=$h)"
            if command -v runuser >/dev/null 2>&1; then
                runuser -u "$u" -- env HOME="$h" dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri 2>&1 || true
                runuser -u "$u" -- env HOME="$h" dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri-dark 2>&1 || true
            else
                su "$u" -c "export HOME=\"$h\"; dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri" 2>&1 || true
                su "$u" -c "export HOME=\"$h\"; dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri-dark" 2>&1 || true
            fi
        else
            echo "(root session — may not match login user)"
            dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri 2>&1 || true
            dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri-dark 2>&1 || true
        fi
    elif id user >/dev/null 2>&1; then
        echo "(as user, HOME=/home/user)"
        if command -v runuser >/dev/null 2>&1; then
            runuser -u user -- env HOME=/home/user dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri 2>&1 || true
            runuser -u user -- env HOME=/home/user dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri-dark 2>&1 || true
        else
            su user -c "export HOME=/home/user; dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri" 2>&1 || true
            su user -c "export HOME=/home/user; dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri-dark" 2>&1 || true
        fi
    else
        echo "(root session — may not match login user)"
        dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri 2>&1 || true
        dbus-run-session -- gsettings get org.gnome.desktop.background picture-uri-dark 2>&1 || true
    fi
else
    echo "(gsettings missing)"
fi
'

if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INNER_SCRIPT"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INNER_SCRIPT"
fi
