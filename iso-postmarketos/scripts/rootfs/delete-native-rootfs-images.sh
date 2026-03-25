#!/bin/bash
# Remove combined/split install disk images under /home/pmos/rootfs/ in the pmbootstrap
# *native* chroot so the next `pmbootstrap install` recreates them from the current rootfs
# instead of reusing stale .img files from an earlier build.
#
# Usage: delete-native-rootfs-images.sh <profile-env>
# Env: ATOMOS_FRESH_ROOTFS_IMAGES=1 must be intended by caller; this script is a no-op if unset.
#      PMB_USE_CONTAINER=1 uses scripts/pmb/pmb-container.sh (same as resync-rootfs-to-disk-image.sh).

set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "Usage: $0 <profile-env>" >&2
	exit 1
fi

if [ "${ATOMOS_FRESH_ROOTFS_IMAGES:-0}" != "1" ]; then
	exit 0
fi

PROFILE_ENV="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PMB_HOST="$ROOT_DIR/scripts/pmb/pmb.sh"
PMB_CONTAINER="$ROOT_DIR/scripts/pmb/pmb-container.sh"

PMB="$PMB_HOST"
PROFILE_ENV_ARG="$PROFILE_ENV"
if [ "${PMB_USE_CONTAINER:-0}" = "1" ] || ! command -v pmbootstrap >/dev/null 2>&1; then
	PMB="$PMB_CONTAINER"
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

PROFILE_NAME="${PROFILE_NAME:?PROFILE_NAME must be set in profile env}"

echo "=== ATOMOS: deleting native install disk images (fresh install images on next pmbootstrap install) ==="
echo "    /home/pmos/rootfs/${PROFILE_NAME}.img (+ split variants if present)"

pmb_exec() {
	local -a env_args=(env "PATH=$PATH")
	if [ -n "${PMB_WORK_OVERRIDE:-}" ]; then
		env_args+=("PMB_WORK_OVERRIDE=$PMB_WORK_OVERRIDE")
	fi
	if [ "$PMB" = "$PMB_CONTAINER" ]; then
		env_args+=("PMB_CONTAINER_AS_ROOT=1")
	fi
	if [ "$(id -u)" -eq 0 ]; then
		if [ -z "${SUDO_USER:-}" ]; then
			echo "ERROR: pmbootstrap must not run as root." >&2
			exit 1
		fi
		local su_home
		su_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
		env_args=(env "PATH=${su_home}/.local/bin:${PATH}")
		if [ -n "${PMB_WORK_OVERRIDE:-}" ]; then
			env_args+=("PMB_WORK_OVERRIDE=$PMB_WORK_OVERRIDE")
		fi
		if [ "$PMB" = "$PMB_CONTAINER" ]; then
			env_args+=("PMB_CONTAINER_AS_ROOT=1")
		fi
		sudo -u "$SUDO_USER" -H "${env_args[@]}" bash "$PMB" "$PROFILE_ENV_ARG" "$@"
	else
		"${env_args[@]}" bash "$PMB" "$PROFILE_ENV_ARG" "$@"
	fi
}

# Pipe script on stdin (native chroot mangles long sh -c strings; same pattern as resync).
_ATOMOS_DEL_IMGS=$(cat <<ATOMOS_DELETE_IMGS_SCRIPT
set -eu
rm -f "/home/pmos/rootfs/${PROFILE_NAME}.img" \
	"/home/pmos/rootfs/${PROFILE_NAME}-boot.img" \
	"/home/pmos/rootfs/${PROFILE_NAME}-root.img" 2>/dev/null || true
echo "atomos: native rootfs disk image cleanup done."
ATOMOS_DELETE_IMGS_SCRIPT
)

printf '%s' "$_ATOMOS_DEL_IMGS" | pmb_exec chroot --output log -- /bin/sh -eu -s
