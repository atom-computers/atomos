#!/bin/sh
. ./init_functions.sh
. /usr/share/misc/source_deviceinfo

mount_loopback_device() {
	loopback_img=postmarketOS.img
	partitions="/dev/mmcblk0p29 /dev/mmcblk0p30 /dev/mmcblk0p31"

	mkdir /tmpmnt
	for part in $partitions; do
		mount -o ro $part /tmpmnt

		if [ -f "/tmpmnt/$loopback_img" ]; then
			mount -o remount,rw /tmpmnt
			loopback_device=$(losetup -f)
			losetup $loopback_device "/tmpmnt/$loopback_img"
			kpartx -afs $loopback_device
			return 0
		fi

		umount /tmpmnt
	done
}

mount_loopback_device
