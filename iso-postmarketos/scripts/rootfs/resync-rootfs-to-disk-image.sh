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

# Ensure the device rootfs is bind-mounted at /mnt/rootfs_<device> inside
# the native chroot BEFORE the inner script runs. Background:
#   - pmbootstrap's mount_device_rootfs() (vendor/pmbootstrap/pmb/helpers/
#     mount.py:111) bind-mounts the device rootfs chroot dir into the
#     native chroot's /mnt/rootfs_<chroot_name>.
#   - It is invoked automatically by pmbootstrap's own copy_files_from_chroot
#     during `pmb install`, AND every time we run `pmb chroot -r --`
#     (because -r enters the device rootfs which depends on the bind).
#   - It is NOT invoked by `pmb chroot --` (the native-chroot mode our
#     resync inner script runs under).
#   - pmbootstrap may shutdown bind mounts between operations (especially
#     after errors or a post-build housekeeping pass). When it does, our
#     resync sees /mnt/rootfs_<device> missing/empty and exits 2 -- which
#     under set -e in build-image.sh aborts the build before
#     export.sh streams the (now stale) install-time image to disk. The
#     image still flashes and boots, but it ships the rootfs as
#     pmbootstrap install left it -- without any of our post-install
#     customizations (atomos-overview-chat-ui, atomos-home-bg, vendor
#     phosh apk upgrade, custom wallpaper, dconf overrides, overlay).
#
# Fix: trigger mount_device_rootfs by running a no-op inside the device
# rootfs (`pmb chroot -r -- /bin/true`). The bind mount it sets up
# survives in the native chroot's mount namespace until pmb shutdown is
# called, so the subsequent `pmb chroot --` resync sees the populated
# /mnt/rootfs_<device>.
echo "RESYNC pre-flight: ensuring /mnt/rootfs_${PMOS_DEVICE} bind mount in native chroot..."
if ! pmb_exec chroot -r -- /bin/true >/dev/null 2>&1; then
    echo "WARN: pmb chroot -r failed during pre-flight; resync inner script will retry the mount check and may exit 2." >&2
fi

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
	# If the sparse round-trip set up a raw temp file but we exited before
	# converting back, clean it up. (Successful run removes it explicitly.)
	if [ -n "${ATOMOS_RESYNC_RAW_TMP:-}" ] && [ -f "${ATOMOS_RESYNC_RAW_TMP}" ]; then
		rm -f "${ATOMOS_RESYNC_RAW_TMP}" 2>/dev/null || true
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

# Detect Android sparse image format. pmbootstrap install for devices with
# deviceinfo_flash_sparse=true (FP4, many other Qualcomm Android phones)
# converts the rootfs image in place via img2simg
# (vendor/pmbootstrap/pmb/install/_install.py:983-986). The on-disk file at
# /home/pmos/rootfs/<device>.img is then in Android sparse format (magic
# 0xed 0x26 0xff 0x3a, little-endian 0x3aFF26ED), NOT a raw ext4/GPT image.
# losetup -P on that file attaches it as a flat block device with no
# partitions -- so the previous resync code matched no BOOT_PART/ROOT_PART
# and exited 3, BUT the pmbootstrap chroot --output log mode swallowed the
# inner exit code. The build "succeeded", export.sh streamed the unmodified
# install-time sparse image, and the device flashed it -- which carries
# stock phosh from `pmb install`, none of the post-install customizations
# (vendor phosh, atomos-overview-chat-ui, atomos-home-bg, dconf overrides,
# overlay) that the rootfs chroot has.
is_android_sparse() {
	local f="$1"
	[ -r "$f" ] || return 1
	local magic
	# Android sparse magic: bytes ED 26 FF 3A (little-endian 0x3AFF26ED).
	magic="$(head -c 4 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
	[ "$magic" = "ed26ff3a" ]
}

sync_combined() {
	local img="$1"

	# If the image is Android sparse, simg2img to a raw temp file so losetup
	# can read its partition table. After rsync + post-rsync verify, we
	# img2simg the raw file back over the original sparse one (atomic mv).
	# This is the build-image.sh equivalent of the explicit raw->sparse
	# round-trip build-fairphone4.sh:1604-1627 does inline.
	if is_android_sparse "$img"; then
		log "atomos: detected Android sparse image at $img; converting to raw ext4 for resync ..."
		if ! command -v simg2img >/dev/null 2>&1 || ! command -v img2simg >/dev/null 2>&1; then
			log "atomos: installing android-tools (simg2img + img2simg) in native chroot ..."
			apk add --no-interactive --quiet android-tools 2>/dev/null \
				|| apk add --no-interactive android-tools
		fi
		ATOMOS_RESYNC_SPARSE_SRC="$img"
		ATOMOS_RESYNC_RAW_TMP="${img%.img}.atomos-resync-raw.img"
		rm -f "$ATOMOS_RESYNC_RAW_TMP"
		if ! simg2img "$img" "$ATOMOS_RESYNC_RAW_TMP"; then
			log "ERROR: simg2img failed for $img -> $ATOMOS_RESYNC_RAW_TMP"
			rm -f "$ATOMOS_RESYNC_RAW_TMP"
			exit 11
		fi
		log "atomos: simg2img OK -> $ATOMOS_RESYNC_RAW_TMP ($(du -h "$ATOMOS_RESYNC_RAW_TMP" 2>/dev/null | cut -f1))"
		img="$ATOMOS_RESYNC_RAW_TMP"
	fi

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

# Post-rsync verification of the AtomOS customizations -- not just the
# wallpaper. rsync exits 23/24 on partial transfer (e.g. file errors,
# vanished sources mid-stream); we tolerate those exit codes above so the
# build doesn't abort on transient noise. But "tolerated" must not silently
# include "atomos-overview-chat-ui binary did not land in the image" --
# that is the exact symptom users hit when post-install customizations are
# present in the rootfs chroot but missing from the exported image.
#
# These checks compare the file in the rootfs chroot against the file at
# the same path in /mnt/install (the mounted disk image). Missing in image
# OR sha256 mismatch = a real failure that warrants exit non-zero so the
# build pipeline catches it instead of shipping a half-customized image.
#
# Each entry is checked only when present in the chroot (so QEMU profiles
# without home-bg don't fail this guard, and stock-phosh profiles where
# vendor phosh wasn't installed don't trip the libphosh check).
verify_customization_files() {
	local relpath="$1"
	# Both paths must exist OR both must be absent. Anything else is a
	# silent rsync bug that previous runs of this script let through.
	local in_chroot=0 in_image=0
	[ -e "${ROOTFS_MP}/${relpath}" ] && in_chroot=1
	[ -e "/mnt/install/${relpath}" ] && in_image=1
	if [ "$in_chroot" -eq 1 ] && [ "$in_image" -eq 0 ]; then
		log "VERIFY-FAIL: $relpath is in the rootfs chroot but MISSING from the image."
		log "  this is a resync bug; the exported image will ship without this customization."
		return 1
	fi
	if [ "$in_chroot" -eq 0 ] && [ "$in_image" -eq 1 ]; then
		# Pre-existing in install image without a chroot source = stale
		# leftover from a prior install. --delete on the rsync should have
		# removed it. Warn but don't fail.
		log "NOTE: $relpath is in the image but not in the rootfs chroot (rsync --delete did not remove it)."
		return 0
	fi
	if [ "$in_chroot" -eq 0 ] && [ "$in_image" -eq 0 ]; then
		# Neither has it -- expected when the customization was opt-out
		# (e.g. --without-home-bg, or vendor phosh disabled).
		return 0
	fi
	# Both present: verify content actually matches. sha256 is overkill for
	# a regular file but cheap, and surfaces "rsync wrote 0-byte files"
	# / "rsync wrote stale content" failure modes that simple presence
	# checks miss.
	if [ -f "${ROOTFS_MP}/${relpath}" ] && [ -f "/mnt/install/${relpath}" ] \
		&& command -v sha256sum >/dev/null 2>&1; then
		local chroot_sha image_sha
		chroot_sha="$(sha256sum "${ROOTFS_MP}/${relpath}" 2>/dev/null | cut -d" " -f1)"
		image_sha="$(sha256sum "/mnt/install/${relpath}" 2>/dev/null | cut -d" " -f1)"
		if [ -n "$chroot_sha" ] && [ -n "$image_sha" ] && [ "$chroot_sha" != "$image_sha" ]; then
			log "VERIFY-FAIL: $relpath sha256 differs between rootfs chroot and image."
			log "  chroot: $chroot_sha"
			log "  image:  $image_sha"
			return 1
		fi
	fi
	return 0
}

verify_atomos_customizations_in_image() {
	# AtomOS customizations that are added by build-image.sh AFTER pmb
	# install. If they exist in the rootfs chroot, they MUST be in the
	# exported image; otherwise the device boots with stock postmarketOS
	# instead of AtomOS.
	local fail=0
	local p
	for p in \
		"usr/local/bin/atomos-overview-chat-ui" \
		"usr/bin/atomos-overview-chat-ui" \
		"usr/libexec/atomos-overview-chat-ui" \
		"usr/libexec/atomos-overview-chat-submit" \
		"usr/local/bin/atomos-home-bg" \
		"usr/bin/atomos-home-bg" \
		"usr/libexec/atomos-home-bg" \
		"usr/share/atomos-home-bg/index.html" \
		"etc/xdg/autostart/atomos-home-bg.desktop" \
		"etc/atomos/overview-chat-ui-overlay-contract" \
		"etc/dconf/db/local.d/51-atomos-phosh-favorites.conf" \
		"usr/libexec/phosh"; do
		verify_customization_files "$p" || fail=1
	done
	if [ "$fail" -ne 0 ]; then
		if [ "${ATOMOS_SKIP_RESYNC_VERIFY:-0}" = "1" ]; then
			log "WARN: post-rsync verification failed; continuing because ATOMOS_SKIP_RESYNC_VERIFY=1."
			return 0
		fi
		log "ERROR: post-rsync verification failed -- one or more AtomOS customizations are in the rootfs chroot but did NOT land in the exported image."
		log "  This means the device will boot with the install-time rootfs (stock postmarketOS) instead of the AtomOS overlay set."
		log "  Possible causes:"
		log "    1. rsync exited 23/24 (partial transfer) and silently dropped /usr/local/bin/."
		log "    2. /mnt/rootfs_<device> bind mount was empty/stale during the rsync pass."
		log "    3. /mnt/install was unmounted before rsync finished writing."
		log "  To downgrade this to a warning (and accept a half-customized image): export ATOMOS_SKIP_RESYNC_VERIFY=1"
		return 1
	fi
	log "atomos: post-rsync verification OK -- AtomOS customizations match between chroot and image."
	return 0
}

verify_atomos_customizations_in_image || exit 7

# Convert the modified raw ext4 back to Android sparse and atomically replace
# the original sparse image. This MUST happen after the customizations have
# landed in the raw image (the rsync above) AND been verified
# (verify_atomos_customizations_in_image), but BEFORE we exit -- otherwise
# the cleanup trap removes the raw temp file and the original sparse stays
# unchanged. Atomic mv on the same filesystem so a partial write can't leave
# a half-converted image at the path export.sh streams from.
if [ -n "${ATOMOS_RESYNC_RAW_TMP:-}" ] && [ -n "${ATOMOS_RESYNC_SPARSE_SRC:-}" ]; then
	# Unmount + detach BEFORE converting back so the raw file is closed
	# and final on disk. The cleanup trap would do this on exit, but we
	# need it done now (before the img2simg read).
	if [ -n "${BOOT_MNTED:-}" ] && mountpoint -q /mnt/install/boot 2>/dev/null; then
		umount /mnt/install/boot && BOOT_MNTED=""
	fi
	if [ -n "${ROOT_MNTED:-}" ] && mountpoint -q /mnt/install 2>/dev/null; then
		umount /mnt/install && ROOT_MNTED=""
	fi
	if [ -n "${LOOP_COMBINED:-}" ]; then
		losetup -d "${LOOP_COMBINED}" && LOOP_COMBINED=""
	fi
	sync
	new_sparse="${ATOMOS_RESYNC_SPARSE_SRC}.atomos-resync-new"
	rm -f "$new_sparse"
	log "atomos: converting modified raw ext4 back to Android sparse via img2simg ..."
	if ! img2simg "$ATOMOS_RESYNC_RAW_TMP" "$new_sparse"; then
		log "ERROR: img2simg failed converting modified raw image back to sparse."
		log "  raw:    $ATOMOS_RESYNC_RAW_TMP"
		log "  sparse: $new_sparse (will be removed)"
		log "  Original sparse image at $ATOMOS_RESYNC_SPARSE_SRC is unchanged (still install-time stock)."
		rm -f "$new_sparse" "$ATOMOS_RESYNC_RAW_TMP"
		exit 12
	fi
	if ! mv -f "$new_sparse" "$ATOMOS_RESYNC_SPARSE_SRC"; then
		log "ERROR: failed to atomically replace $ATOMOS_RESYNC_SPARSE_SRC with re-packed sparse image."
		rm -f "$new_sparse" "$ATOMOS_RESYNC_RAW_TMP"
		exit 13
	fi
	rm -f "$ATOMOS_RESYNC_RAW_TMP"
	# Clear the marker so the cleanup trap doesn't try to remove the now
	# already-removed temp file (it just guards rm -f, but be tidy).
	ATOMOS_RESYNC_RAW_TMP=""
	log "atomos: sparse re-pack complete; $ATOMOS_RESYNC_SPARSE_SRC now contains post-customization rootfs."
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
