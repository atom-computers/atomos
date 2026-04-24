#!/bin/bash
# Re-sync the device rootfs chroot into the install disk image(s) under
# /home/pmos/rootfs/ inside the pmbootstrap *native* chroot.
#
# pmbootstrap install runs copy_files_from_chroot() once, at install time.
# Our Makefile mutates the rootfs *after* that (lockscreen, wallpaper, overlay,
# optional mkinitfs). Without this step, `chroot -r` reflects those changes but
# /home/pmos/rootfs/<device>.img (and thus export) still contains the pre-mutation
# tree — which matches "phone has old greeter, chroot looks new".
#
# Usage: resync-rootfs-to-disk-image.sh <profile-env>
# Env: PMB_USE_CONTAINER=1 uses scripts/pmb/pmb-container.sh (privileged) like apply-overlay.

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
PMOS_DEVICE="${PMOS_DEVICE:?PMOS_DEVICE must be set in profile env}"
ROOTFS_MP="/mnt/rootfs_${PMOS_DEVICE}"

# Run pmbootstrap as non-root host user; it elevates inside the native chroot.
pmb_exec() {
	local -a env_args=(env "PATH=$PATH")
	if [ -n "${PMB_WORK_OVERRIDE:-}" ]; then
		env_args+=("PMB_WORK_OVERRIDE=$PMB_WORK_OVERRIDE")
	fi
	# Loop mounts + losetup need privileged container entry.
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
		# Like export.sh: use bash so pmb.sh doesn't need +x (avoids noexec / permission denied).
		sudo -u "$SUDO_USER" -H "${env_args[@]}" bash "$PMB" "$PROFILE_ENV_ARG" "$@"
	else
		"${env_args[@]}" bash "$PMB" "$PROFILE_ENV_ARG" "$@"
	fi
}

echo "=== RESYNC: rootfs -> /home/pmos/rootfs/{${PROFILE_NAME},${PMOS_DEVICE}}.img (post-install mutations; exact filename resolved inside chroot) ==="

# Inner script runs as root inside the native chroot (default for `pmbootstrap chroot`).
# Do NOT use --output stdout here: that mode is for streaming a binary payload (see export.sh
# `cat /boot/boot.img`). Our inner script prints diagnostics; stdout in stdout-mode can make
# pmbootstrap return non-zero even when the inner script ends with exit 0.
# Export PROFILE_* into the inner sh via env (safe: no extra `sh -c` argv after the script).
# Native `pmbootstrap chroot` mangles long `sh -c "$script"` (logs show `/bin/sh -eu -c IMG_COMBINED=`
# with no quotes; argv splits and rsync can exit 32). Pipe the script on stdin to `sh -s` instead
# — no giant -c string on the command line. (apply-overlay uses `chroot -r` + -c; native chroot differs.)
# Do not put a `#` comment between backslash-continued lines here.
# shellcheck disable=SC2016
read -r -d '' ATOMOS_RESYNC_INNER <<'ATOMOS_RESYNC_INNER_SCRIPT' || true
# pmbootstrap 3.9 names the install disk image after PMOS_DEVICE (e.g.
# qemu-aarch64.img) on QEMU profiles, not PROFILE_NAME (arm64-virt.img).
# We must probe both in the same fallback order that scripts/export/export.sh
# uses (PROFILE_NAME.img first, then PMOS_DEVICE.img), otherwise resync
# silently finds nothing and the exported image ships pmbootstrap's
# install-time rootfs with none of our post-install customizations -
# exactly the "apk policy phosh shows stock 0.54.0-r0 on the booted
# guest" symptom.
PROFILE_IMG="/home/pmos/rootfs/${PROFILE_NAME}.img"
PROFILE_BOOT="/home/pmos/rootfs/${PROFILE_NAME}-boot.img"
PROFILE_ROOT="/home/pmos/rootfs/${PROFILE_NAME}-root.img"
DEVICE_IMG="/home/pmos/rootfs/${PMOS_DEVICE}.img"
DEVICE_BOOT="/home/pmos/rootfs/${PMOS_DEVICE}-boot.img"
DEVICE_ROOT="/home/pmos/rootfs/${PMOS_DEVICE}-root.img"

IMG_COMBINED=""
IMG_BOOT=""
IMG_ROOT=""
if [ -f "$PROFILE_IMG" ]; then
    IMG_COMBINED="$PROFILE_IMG"
elif [ -f "$PROFILE_BOOT" ] && [ -f "$PROFILE_ROOT" ]; then
    IMG_BOOT="$PROFILE_BOOT"
    IMG_ROOT="$PROFILE_ROOT"
elif [ -f "$DEVICE_IMG" ]; then
    IMG_COMBINED="$DEVICE_IMG"
elif [ -f "$DEVICE_BOOT" ] && [ -f "$DEVICE_ROOT" ]; then
    IMG_BOOT="$DEVICE_BOOT"
    IMG_ROOT="$DEVICE_ROOT"
fi

log() { printf "%s\n" "$*" >&2; }

reread_partitions() {
	local dev="$1"
	if command -v blockdev >/dev/null 2>&1; then
		blockdev --rereadpt "$dev" 2>/dev/null || true
	elif command -v partprobe >/dev/null 2>&1; then
		partprobe "$dev" 2>/dev/null || true
	fi
}

# Do not `exit "$?"` here: ash/dash often leave $? as 1/2 after `if`/`[` even when the last
# command was successful; that re-exit turns a good resync into make failing with Error 2.
cleanup() {
	trap - EXIT INT HUP
	if [ -n "${BOOT_MNTED:-}" ] && mountpoint -q /mnt/install/boot 2>/dev/null; then
		umount /mnt/install/boot || true
	fi
	if [ -n "${ROOT_MNTED:-}" ] && mountpoint -q /mnt/install 2>/dev/null; then
		umount /mnt/install || true
	fi
	if [ -n "${LOOP_BOOT:-}" ]; then
		losetup -d "${LOOP_BOOT}" 2>/dev/null || true
	fi
	if [ -n "${LOOP_ROOT:-}" ]; then
		losetup -d "${LOOP_ROOT}" 2>/dev/null || true
	fi
	if [ -n "${LOOP_COMBINED:-}" ]; then
		losetup -d "${LOOP_COMBINED}" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT HUP

if [ ! -d "${ROOTFS_MP}" ] || [ ! -d "${ROOTFS_MP}/usr" ]; then
	log "ERROR: device rootfs bind mount missing: ${ROOTFS_MP} (expected /usr)."
	log "  Run from make build after install so the rootfs chroot is mounted."
	exit 2
fi

apk add --no-interactive --quiet rsync 2>/dev/null || apk add --no-interactive rsync

mkdir -p /mnt/install

sync_combined() {
	local img="$1"
	LOOP_COMBINED="$(losetup -f --show -P "$img")"
	reread_partitions "${LOOP_COMBINED}"
	BOOT_PART=""
	ROOT_PART=""
	for p in "${LOOP_COMBINED}"p*; do
		[ -e "$p" ] || continue
		[ -b "$p" ] || continue
		LABEL="$(blkid -o value -s LABEL "$p" 2>/dev/null || true)"
		PARTLABEL="$(blkid -o value -s PARTLABEL "$p" 2>/dev/null || true)"
		# Must be printf "%s\n" (not %sn); tr needs quoted [:upper:] / [:lower:] character classes.
		LC="$(printf "%s\n" "$LABEL" | tr "[:upper:]" "[:lower:]")"
		PLC="$(printf "%s\n" "$PARTLABEL" | tr "[:upper:]" "[:lower:]")"
		# Filesystem LABEL and GPT PARTLABEL (some images only set one).
		case "$LC" in
			pmos_boot) BOOT_PART="$p" ;;
			pmos_root) ROOT_PART="$p" ;;
		esac
		case "$PLC" in
			pmos_boot) BOOT_PART="$p" ;;
			pmos_root) ROOT_PART="$p" ;;
		esac
	done
	# pmb#463: optional empty partition between boot (p1) and root (p3).
	if [ -z "${BOOT_PART}" ] || [ -z "${ROOT_PART}" ]; then
		log "NOTE: blkid did not match pmOS_*; trying p1/p2 and p1/p3 layout fallbacks"
		if [ -b "${LOOP_COMBINED}p1" ] && [ -b "${LOOP_COMBINED}p2" ] && [ -b "${LOOP_COMBINED}p3" ]; then
			BOOT_PART="${LOOP_COMBINED}p1"
			ROOT_PART="${LOOP_COMBINED}p3"
		elif [ -b "${LOOP_COMBINED}p1" ] && [ -b "${LOOP_COMBINED}p2" ]; then
			BOOT_PART="${LOOP_COMBINED}p1"
			ROOT_PART="${LOOP_COMBINED}p2"
		fi
	fi
	# Last resort: first vfat/exfat = boot; last ext4/f2fs/btrfs = root (typical GPT phone layout).
	if [ -z "${BOOT_PART}" ] || [ -z "${ROOT_PART}" ]; then
		log "NOTE: trying TYPE-based partition guess (vfat|exfat boot; ext4|f2fs|btrfs root)"
		LAST_EXT=""
		for p in "${LOOP_COMBINED}"p*; do
			[ -b "$p" ] || continue
			T="$(blkid -o value -s TYPE "$p" 2>/dev/null || true)"
			case "$T" in
				vfat|exfat) [ -z "${BOOT_PART}" ] && BOOT_PART="$p" ;;
				ext2) [ -z "${BOOT_PART}" ] && BOOT_PART="$p" ;;
				ext4|f2fs|btrfs) LAST_EXT="$p" ;;
			esac
		done
		[ -n "${LAST_EXT}" ] && ROOT_PART="${LAST_EXT}"
	fi
	if [ -z "${BOOT_PART}" ] || [ -z "${ROOT_PART}" ]; then
		log "ERROR: could not find boot/root partitions on ${img}"
		log "  BOOT_PART=${BOOT_PART:-empty} ROOT_PART=${ROOT_PART:-empty}"
		for p in "${LOOP_COMBINED}"p*; do
			[ -b "$p" ] || continue
			log "  $(blkid "$p" 2>/dev/null || echo "(blkid failed) $p")"
		done
		exit 3
	fi
	mkdir -p /mnt/install/boot
	mount "$ROOT_PART" /mnt/install
	ROOT_MNTED=1
	mount "$BOOT_PART" /mnt/install/boot
	BOOT_MNTED=1
}

sync_split() {
	# Root first (fills /mnt/install), then ESP/boot partition on /mnt/install/boot.
	mkdir -p /mnt/install
	LOOP_ROOT="$(losetup -f --show -P "${IMG_ROOT}")"
	reread_partitions "${LOOP_ROOT}"
	if [ -b "${LOOP_ROOT}p1" ]; then
		mount "${LOOP_ROOT}p1" /mnt/install
	else
		mount "${LOOP_ROOT}" /mnt/install
	fi
	ROOT_MNTED=1

	mkdir -p /mnt/install/boot
	LOOP_BOOT="$(losetup -f --show -P "${IMG_BOOT}")"
	reread_partitions "${LOOP_BOOT}"
	if [ -b "${LOOP_BOOT}p1" ]; then
		mount "${LOOP_BOOT}p1" /mnt/install/boot
	else
		mount "${LOOP_BOOT}" /mnt/install/boot
	fi
	BOOT_MNTED=1
}

if [ -n "${IMG_COMBINED}" ] && [ -f "${IMG_COMBINED}" ]; then
	log "atomos: resync rootfs -> combined disk image ${IMG_COMBINED}"
	sync_combined "${IMG_COMBINED}"
elif [ -n "${IMG_BOOT}" ] && [ -n "${IMG_ROOT}" ] && [ -f "${IMG_BOOT}" ] && [ -f "${IMG_ROOT}" ]; then
	log "atomos: resync rootfs -> split images ${IMG_BOOT} + ${IMG_ROOT}"
	sync_split
else
	log "ERROR: no disk image found. Probed (in priority order):"
	log "  ${PROFILE_IMG} (exists: $( [ -f "$PROFILE_IMG" ] && echo yes || echo no ))"
	log "  ${PROFILE_BOOT} + ${PROFILE_ROOT} (exist: $( [ -f "$PROFILE_BOOT" ] && echo yes || echo no ) + $( [ -f "$PROFILE_ROOT" ] && echo yes || echo no ))"
	log "  ${DEVICE_IMG} (exists: $( [ -f "$DEVICE_IMG" ] && echo yes || echo no ))"
	log "  ${DEVICE_BOOT} + ${DEVICE_ROOT} (exist: $( [ -f "$DEVICE_BOOT" ] && echo yes || echo no ) + $( [ -f "$DEVICE_ROOT" ] && echo yes || echo no ))"
	log "This is the filename-convention mismatch that silently ships a"
	log "stock rootfs when PMOS_DEVICE != PROFILE_NAME (e.g. arm64-virt"
	log "profile uses PMOS_DEVICE=qemu-aarch64 and pmbootstrap names the"
	log "install image qemu-aarch64.img, not arm64-virt.img)."
	exit 4
fi

# Mirror pmb.install._install.copy_files_from_chroot (rsync path): top-level dirs except home.
cd "${ROOTFS_MP}" || exit 5
set --
for item in *; do
	[ "$item" = "home" ] && continue
	[ -e "$item" ] || continue
	set -- "$@" "$item"
done
if [ "$#" -eq 0 ]; then
	log "ERROR: no top-level folders to sync from ${ROOTFS_MP}"
	exit 5
fi

# rsync often returns 23/24 for partial transfer; some builds also use 31–35 for
# socket/partial/noise (e.g. 32). With set -e that would abort the build.
set +e
rsync -a --delete "$@" /mnt/install/
rsync_rc=$?
set -e
case "$rsync_rc" in
	0) ;;
	23|24|31|32|33|34|35)
		log "NOTE: rsync exited $rsync_rc (non-zero but treated as tolerable; see rsync(1) exit codes)."
		;;
	*)
		log "ERROR: rsync failed with exit code $rsync_rc"
		exit 6
		;;
esac

rm -rf /mnt/install/home 2>/dev/null || true

WALL_REL=""
if [ -f "${ROOTFS_MP}/usr/share/backgrounds/gnome/gargantua-black.jpg" ] && \
   [ -f /mnt/install/usr/share/backgrounds/gnome/gargantua-black.jpg ]; then
	WALL_REL="usr/share/backgrounds/gnome/gargantua-black.jpg"
elif [ -f "${ROOTFS_MP}/usr/share/backgrounds/gargantua-black.jpg" ] && \
     [ -f /mnt/install/usr/share/backgrounds/gargantua-black.jpg ]; then
	WALL_REL="usr/share/backgrounds/gargantua-black.jpg"
elif [ -f "${ROOTFS_MP}/usr/share/backgrounds/atomos/gargantua-black.jpg" ] && \
     [ -f /mnt/install/usr/share/backgrounds/atomos/gargantua-black.jpg ]; then
	WALL_REL="usr/share/backgrounds/atomos/gargantua-black.jpg"
fi

if [ -n "$WALL_REL" ] && command -v sha256sum >/dev/null 2>&1; then
	set +e
	CHROOT_SHA="$(sha256sum "${ROOTFS_MP}/${WALL_REL}" 2>/dev/null | cut -d" " -f1)"
	IMG_SHA="$(sha256sum "/mnt/install/${WALL_REL}" 2>/dev/null | cut -d" " -f1)"
	set -e
	if [ -n "$CHROOT_SHA" ] && [ -n "$IMG_SHA" ]; then
		if [ "$CHROOT_SHA" != "$IMG_SHA" ]; then
			log "WARNING: wallpaper sha256 mismatch after rsync (unexpected)."
			log "  chroot: $CHROOT_SHA"
			log "  image:  $IMG_SHA"
		else
			log "atomos: verified gargantua-black.jpg sha256 matches chroot (${CHROOT_SHA})."
		fi
	fi
elif [ -n "$WALL_REL" ]; then
	log "NOTE: sha256sum not in PATH; skipping wallpaper hash check."
fi

log "atomos: resync complete."
exit 0
ATOMOS_RESYNC_INNER_SCRIPT

printf '%s' "$ATOMOS_RESYNC_INNER" | pmb_exec chroot --output log -- env \
	PROFILE_NAME="$PROFILE_NAME" \
	PMOS_DEVICE="$PMOS_DEVICE" \
	ROOTFS_MP="$ROOTFS_MP" \
	/bin/sh -eu -s

echo "=== RESYNC DONE ==="
