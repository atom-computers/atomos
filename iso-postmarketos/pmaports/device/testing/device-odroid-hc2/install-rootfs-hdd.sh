#!/bin/sh
set -e

MOUNT_POINT=/mnt/hdd
MMC_ROOT_PARTITION=/dev/mmcblk0p2

echo "### Move rootfs to external HDD ###"
echo "This script requires root permissions!"
echo "This action is inreversible without reflashing your device!"
echo "Are you sure you want to continue? [y/N]"
read -n 1 ANSWER
echo ""

if [ "$ANSWER" != "y" ]; then
	echo "Operation aborted"
	exit 1
fi

echo "Which partition should be used as rootfs?:"
read HDD_ROOT_PARTITION
echo ""

echo "### Copying rootfs to partition $HDD_ROOT_PARTITION ###"

# Mount partition
echo "Trying to unmount $HDD_ROOT_PARTITION"
umount $HDD_ROOT_PARTITION || true  # may fail
echo "Mounting $HDD_ROOT_PARTITION at $MOUNT_POINT"
mkdir -p $MOUNT_POINT
mount $HDD_ROOT_PARTITION $MOUNT_POINT

# Copy rootfs
echo "Copying rootfs... This can take a while."
rsync \
	-aAXx \
	--exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} \
	/ \
	$MOUNT_POINT

# Verify all files are copied
rsync \
	-aAXx \
	--exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} \
	/ \
	$MOUNT_POINT
sync
echo "Rootfs successfully copied!"

# pmOS initfs looks for rootfs by label, rename partitions
echo "Renaming partitions"
e2label $MMC_ROOT_PARTITION old_rootfs
e2label $HDD_ROOT_PARTITION pmOS_root

echo "Rootfs moved to external HDD, you must reboot NOW!"
