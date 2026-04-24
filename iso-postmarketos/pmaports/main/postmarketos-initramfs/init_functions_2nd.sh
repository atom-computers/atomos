#!/bin/busybox ash
# Additional functions that depend on initramfs-extra
# Functions are notated with the reason they're only in
# initramfs-extra

# udevd is too big
setup_udev() {
	if ! command -v udevd > /dev/null || ! command -v udevadm > /dev/null; then
		echo "ERROR: udev not found!"
		return
	fi

	# This is the same series of steps performed by the udev,
	# udev-trigger and udev-settle RC services. See also:
	# - https://git.alpinelinux.org/aports/tree/main/eudev/setup-udev
	# - https://git.alpinelinux.org/aports/tree/main/udev-init-scripts/APKBUILD
	udevd -d --resolve-names=never
	udevadm trigger --type=devices --action=add
	udevadm settle
}

# parted is too big
resize_root_partition() {
	local partition

	find_root_partition partition

	# Do not resize the installer partition
	if [ "$(blkid --label pmOS_install)" = "$partition" ]; then
		echo "Resize root partition: skipped (on-device installer)"
		return
	fi

	local resize_dev="" check_dev="" partnum=2

	# Always resize if using subpartitions, which means the partition
	# is stored as a nested GPT inside another partition. In this case we want to
	# resize the GPT so the inner root partition can make use of all the available
	# space.
	if [ -n "$SUBPARTITION_LOOP" ]; then
		#
		resize_dev="$SUBPARTITION_LOOP"
		check_dev="$SUBPARTITION_LOOP"
	# Resize the root partition (non-subpartitions). Usually we do not want
	# this, except for QEMU devices and non-android devices (e.g.
	# PinePhone). For them, it is fine to use the whole storage device and
	# so we pass PMOS_FORCE_PARTITION_RESIZE as kernel parameter.
	elif [ "$force_partition_resize" = "y" ]; then
		check_dev="$(echo "$partition" | sed -E 's/p?2$//')"
		resize_dev="$check_dev"
	# Resize the root partition (non-subpartitions) on Chrome OS devices.
	# Match $deviceinfo_cgpt_kpart not being empty instead of cmdline
	# because it does not make sense here as all these devices use the same
	# partitioning methods. This also resizes third partition instead of
	# second, because these devices have an additional kernel partition
	# at the start.
	elif [ -n "$deviceinfo_cgpt_kpart" ]; then
		check_dev="$(echo "$partition" | sed -E 's/p?3$//')"
		resize_dev="$check_dev"
		partnum=3
	else
		echo "Unable to resize root partition: failed to find qualifying partition"
		return
	fi

	# Resize if needed
	if has_unallocated_space "$check_dev"; then
		echo "Resize root partition ($partition)"
		parted -f -s "$resize_dev" resizepart "$partnum" 100%
		partprobe
	else
		echo "Not resizing root partition ($partition): no free space left"
	fi
}

unlock_root_partition() {
	command -v cryptsetup >/dev/null || return
	if cryptsetup isLuks "$PMOS_ROOT"; then
		# Make sure the splash doesn't interfere
		hide_splash
		tried=0
		until cryptsetup status root | grep -qwi active; do
			fde-unlock "$PMOS_ROOT" "$tried"
			tried=$((tried + 1))
		done
		PMOS_ROOT=/dev/mapper/root
		# Show again the loading splashscreen
		show_splash "Loading..."
	fi
}

# resize2fs, resize.f2fs, and xfs_growfs are too big
resize_root_filesystem() {
	local partition

	find_root_partition partition
	touch /etc/mtab # see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=673323
	check_filesystem "$partition"
	type="$(get_partition_type "$partition")"
	case "$type" in
		ext4)
			echo "Resize 'ext4' root filesystem ($partition)"
			modprobe ext4
			resize2fs "$partition"
			;;
		f2fs)
			echo "Resize 'f2fs' root filesystem ($partition)"
			modprobe f2fs
			resize.f2fs "$partition"
			;;
		btrfs)
			# Resize happens below after mount
			;;
		xfs)
			# Resize happens below after mount
			modprobe xfs
			;;
		*)	echo "WARNING: Can not resize '$type' filesystem ($partition)." ;;
	esac
}

resize_filesystem_after_mount() {
	mountpoint="$1"
	type="$(get_mounted_filesystem_type "$mountpoint")"
	case "$type" in
		ext4)
			# ext4 can do online resize on recent kernels, but we still do it offline
			# for better compatibility with older kernels
			;;
		f2fs)
			# f2fs does not support online resizing
			;;
		btrfs)
			echo "Resize 'btrfs' filesystem ($mountpoint)"
			btrfs filesystem resize max "$mountpoint"
			;;
		xfs)
			echo "Resize 'xfs' root filesystem ($mountpoint)"
			xfs_growfs -d "$mountpoint"
			;;
	esac
}
