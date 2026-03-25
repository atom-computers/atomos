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

LOCK_PARITY="${ATOMOS_LOCK_PARITY:-${PMOS_LOCK_PARITY:-1}}"
if [ "$LOCK_PARITY" != "0" ]; then
    LOCK_PARITY=1
fi

CLEAR_PHOSH_FAV="${PMOS_CLEAR_PHOSH_FAVOURITES:-1}"
PHOSH_DCONF_CHECK=""
if [ "$CLEAR_PHOSH_FAV" != "0" ] && [ "${PMOS_UI:-}" = "phosh" ]; then
    PHOSH_DCONF_CHECK="check_file /etc/dconf/db/local.d/51-atomos-phosh-favorites.conf"
fi

echo "Validating Phosh overlay artifacts for ${PROFILE_NAME} (lock parity=${LOCK_PARITY})"

CHECK_SCRIPT='
set -eu
missing=0

check_file() {
    if [ ! -e "$1" ]; then
        echo "missing: $1"
        missing=1
    fi
}

check_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing command: $1"
        missing=1
    fi
}

if [ -f "${ROOTFS_MP}/usr/share/backgrounds/gnome/gargantua-black.jpg" ]; then
    check_file /usr/share/backgrounds/gnome/gargantua-black.jpg
elif [ -f "${ROOTFS_MP}/usr/share/backgrounds/gargantua-black.jpg" ]; then
    check_file /usr/share/backgrounds/gargantua-black.jpg
else
    check_file /usr/share/backgrounds/atomos/gargantua-black.jpg
fi
check_cmd phosh
__PHOSH_DCONF_CHECK__

if [ "__LOCK_PARITY__" = "1" ]; then
    check_file /etc/atomos/phosh-profile.env
fi

if [ "$missing" -ne 0 ]; then
    exit 1
fi
'

CHECK_SCRIPT="${CHECK_SCRIPT//__LOCK_PARITY__/$LOCK_PARITY}"
CHECK_SCRIPT="${CHECK_SCRIPT//__PHOSH_DCONF_CHECK__/$PHOSH_DCONF_CHECK}"

if [ "${ATOMOS_VALIDATE_DUMP_ONLY:-0}" = "1" ]; then
    printf '%s\n' "$CHECK_SCRIPT"
    exit 0
fi

if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$CHECK_SCRIPT"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$CHECK_SCRIPT"
fi

echo "Lock parity validation passed for ${PROFILE_NAME}."
