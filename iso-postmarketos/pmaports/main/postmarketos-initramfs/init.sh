#!/bin/busybox ash
# shellcheck disable=SC1091

# Export all variables so they're available in /init_2nd.sh
set -a

IN_CI="false"
LOG_PREFIX="[pmOS-rd]"

# Handle halt/poweroff/reboot
# Signals from busybox/halt.c
trap 'halt -f' USR1
trap 'poweroff -f' USR2
trap 'reboot -f' TERM

[ -e /hooks/10-verbose-initfs.sh ] && set -x

[ -e /hooks/05-ci.sh ] && IN_CI="true"

[ -e /etc/unudhcpd.conf ] && . /etc/unudhcpd.conf
. ./init_functions.sh
. /usr/share/misc/source_deviceinfo
[ -e /etc/os-release ] && . /etc/os-release
# provide a default for os-release's VERSION in case the file doesn't exist
VERSION="${VERSION:-unknown}"

# This is set during packaging and is used when triaging bug reports
INITRAMFS_PKG_VERSION="<<INITRAMFS_PKG_VERSION>>"

export PATH=/usr/bin:/bin:/usr/sbin:/sbin
/bin/busybox --install -s
/bin/busybox-extras --install -s

# Mount everything, set up logging, modules, mdev
mount_proc_sys_dev
parse_cmdline < /proc/cmdline
setup_log
echo "  ❬❬ PMOS STAGE 1 ❭❭"
echo "initramfs version: $INITRAMFS_PKG_VERSION"
setup_firmware_path

# Jump straight to the 2nd stage init if available
# (no separate -extra) or no-op otherwise
jump_init_2nd

echo "Loading initramfs-extra..."

# We need mdev to find the boot partition
setup_mdev

load_modules /lib/modules/initramfs.load

setup_usb_network
start_unudhcpd

if [ "$IN_CI" = "false" ]; then
	setup_framebuffer
	show_splash "Loading..."
fi

# Discover the partitions if they're "subpartitions"
# (where the whole disk image is flashed to a partition)
mount_subpartitions

# Poll for the boot partition to become available or crash
wait_boot_partition
mount_boot_partition /boot
extract_initramfs_extra /boot/initramfs-extra
# /boot is mounted later into the rootfs
umount /boot

# Kill mdev, since it's replaced by udev in the
# second stage init
kill mdev 2>/dev/null

# Now we can jump to the 2nd stage init
jump_init_2nd

# Somehow init_2nd.sh is missing
echo "$LOG_PREFIX ERROR: /init_2nd.sh not found!"
echo "$LOG_PREFIX For more information, see <https://postmarketos.org/debug-shell>"
fail_halt_boot
