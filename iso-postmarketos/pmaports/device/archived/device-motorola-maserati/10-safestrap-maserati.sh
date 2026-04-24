#!/bin/sh
. ./init_functions.sh

SAFESTRAP_PARTITION="/dev/mmcblk1p25"

mount_safestrap() {
	grep -q PMOS_NO_SAFESTRAP /proc/cmdline && return

	mkdir /ss
	mount -t vfat -o uid=1023,gid=1023,fmask=0007,dmask=0007,allow_utime=0020 ${SAFESTRAP_PARTITION} /ss

	slot_loc=$(cat /ss/safestrap/active_slot)

	if [ ! -z $slot_loc ]; then
		if [ "$slot_loc" = "stock" ]; then
			umount /ss
		elif [ "$slot_loc" = "safe" ]; then
			umount /ss
		else
			# setup loopbacks
			data_partition=$(losetup -f)
			losetup $data_partition /ss/safestrap/$slot_loc/userdata.img
			kpartx -afs $data_partition

			system_partition=$(losetup -f)
			losetup $system_partition /ss/safestrap/$slot_loc/system.img
		fi
	fi
}

mount_safestrap
