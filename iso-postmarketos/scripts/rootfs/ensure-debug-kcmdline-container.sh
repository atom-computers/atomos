#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <profile-env> <boot-debug-level>" >&2
    exit 1
fi

PROFILE_ENV="$1"
BOOT_DEBUG="$2"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"

PMB="$PMB_HOST"
PROFILE_ENV_ARG="$PROFILE_ENV"
USE_CONTAINER=0
if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
    USE_CONTAINER=1
    PMB="$PMB_CONTAINER"
    if [[ "$PROFILE_ENV" == "$ROOT_DIR/"* ]]; then
        PROFILE_ENV_ARG="${PROFILE_ENV#"$ROOT_DIR"/}"
    fi
fi

if [ "$USE_CONTAINER" = "1" ]; then
    PMB_CONTAINER_AS_ROOT=1 bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "
mkdir -p /etc/kernel-cmdline.d
if [ \"$BOOT_DEBUG\" = \"1\" ]; then
    cat > /etc/kernel-cmdline.d/90-atomos-debug.conf << 'EOF'
rd.info pmos.nosplash pmos.root=/dev/disk/by-label/pmOS_root modprobe.blacklist=ath10k_snoc,ath10k_core
EOF
elif [ \"$BOOT_DEBUG\" = \"2\" ]; then
    cat > /etc/kernel-cmdline.d/90-atomos-debug.conf << 'EOF'
ignore_loglevel loglevel=7 rd.info pmos.nosplash pmos.debug-shell pmos.root=/dev/disk/by-label/pmOS_root modprobe.blacklist=ath10k_snoc,ath10k_core
EOF
else
    rm -f /etc/kernel-cmdline.d/90-atomos-debug.conf
fi
"
else
    bash "$PMB" "$PROFILE_ENV_ARG" chroot -r -- /bin/sh -eu -c "
mkdir -p /etc/kernel-cmdline.d
if [ \"$BOOT_DEBUG\" = \"1\" ]; then
    cat > /etc/kernel-cmdline.d/90-atomos-debug.conf << 'EOF'
rd.info pmos.nosplash pmos.root=/dev/disk/by-label/pmOS_root modprobe.blacklist=ath10k_snoc,ath10k_core
EOF
elif [ \"$BOOT_DEBUG\" = \"2\" ]; then
    cat > /etc/kernel-cmdline.d/90-atomos-debug.conf << 'EOF'
ignore_loglevel loglevel=7 rd.info pmos.nosplash pmos.debug-shell pmos.root=/dev/disk/by-label/pmOS_root modprobe.blacklist=ath10k_snoc,ath10k_core
EOF
else
    rm -f /etc/kernel-cmdline.d/90-atomos-debug.conf
fi
"
fi
