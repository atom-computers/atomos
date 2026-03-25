#!/bin/bash
# Phosh defaults in /etc/dconf/db/local.d (see docs/PHOSH.md §2).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"

write_phosh_favorites_conf() {
    local dconf_dir="$1"
    mkdir -p "$dconf_dir"
    cat > "$dconf_dir/51-atomos-phosh-favorites.conf" << 'EOF'
[sm/puri/phosh]
favorites=@as []

[mobi/phosh/shell]
favorites=@as []
EOF
}

if [ "${1:-}" = "--rootfs" ]; then
    if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
        echo "Usage: $0 --rootfs <rootfs-dir> [<profile-env>]" >&2
        exit 1
    fi
    ROOTFS="${2%/}"
    if [ ! -d "$ROOTFS" ]; then
        echo "ERROR: rootfs directory not found: $ROOTFS" >&2
        exit 1
    fi
    if [ -n "${3:-}" ]; then
        PE="$3"
        if [ ! -f "$PE" ] && [ -f "$ROOT_DIR/$PE" ]; then
            PE="$ROOT_DIR/$PE"
        fi
        if [ ! -f "$PE" ]; then
            echo "ERROR: profile env not found: $3" >&2
            exit 1
        fi
        # shellcheck source=/dev/null
        source "$PE"
    fi
    CLEAR="${PMOS_CLEAR_PHOSH_FAVOURITES:-1}"
    if [ "$CLEAR" = "0" ]; then
        echo "atomos-phosh-dconf: skip (PMOS_CLEAR_PHOSH_FAVOURITES=0)"
        exit 0
    fi
    write_phosh_favorites_conf "$ROOTFS/etc/dconf/db/local.d"
    echo "atomos-phosh-dconf: wrote 51-atomos-phosh-favorites.conf under $ROOTFS"
    exit 0
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <profile-env> | $0 --rootfs <rootfs-dir> [<profile-env>]" >&2
    exit 1
fi

PROFILE_ENV="$1"
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

CLEAR="${PMOS_CLEAR_PHOSH_FAVOURITES:-1}"
if [ "$CLEAR" = "0" ]; then
    echo "atomos-phosh-dconf: skip (PMOS_CLEAR_PHOSH_FAVOURITES=0)"
    exit 0
fi

INNER_SCRIPT='
set -e
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/51-atomos-phosh-favorites.conf << "EOF"
[sm/puri/phosh]
favorites=@as []

[mobi/phosh/shell]
favorites=@as []
EOF
if command -v dconf >/dev/null 2>&1; then
    dconf update || true
fi
echo "atomos-phosh-dconf: wrote 51-atomos-phosh-favorites.conf"
'

if [ "${ATOMOS_PHOSH_DCONF_DUMP_ONLY:-0}" = "1" ]; then
    printf '%s\n' "$INNER_SCRIPT"
    exit 0
fi

echo "Applying AtomOS Phosh dconf in chroot (${PROFILE_NAME})..."
if [ "$PMB_CONTAINER_ROOT" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INNER_SCRIPT"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "$INNER_SCRIPT"
fi
