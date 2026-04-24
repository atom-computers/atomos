#!/bin/sh -e
# This script fails on error (-e). We don't want an error while generating the
# initramfs to go unnoticed, it may lead to the device not booting anymore.

if ! [ -f /usr/share/deviceinfo/deviceinfo ]; then
	echo "mkinitfs: skipping (no deviceinfo file found)"
	exit 0
fi

# Don't run mkinitfs inside "pmbootstrap install" with this trigger script, as
# it would trigger multiple times as the rootfs gets constructed, slowing down
# the process. Instead, pmbootstrap runs "mkinitfs" explicitly once at the end
# of "pmbootstrap install".
if [ -f /in-pmbootstrap ]; then
	echo "mkinitfs: skipping (running in pmbootstrap)"
	echo "mkinitfs: to force building a new initramfs, run 'mkinitfs'"
	exit 0
fi

/usr/sbin/mkinitfs
