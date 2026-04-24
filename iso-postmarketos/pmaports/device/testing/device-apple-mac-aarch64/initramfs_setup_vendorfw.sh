#!/bin/sh
# Initramfs hook to setup vendor firmware from ESP for Apple Silicon Macs
# Extracts firmware.cpio from ESP to /vendorfw in initramfs
# Also see: https://asahilinux.org/docs/platform/open-os-interop/#os-handling

set -e

DT_ESP_FILE="/proc/device-tree/chosen/asahi,efi-system-partition"

# Check if we're on Apple Silicon Mac
if [ ! -f "$DT_ESP_FILE" ]; then
	echo "Error: Not on Apple Silicon Mac or missing device tree property" >&2
	exit 1
fi

# Read ESP PARTUUID as string
ESP_PARTUUID=$(cat "$DT_ESP_FILE")

if [ -z "$ESP_PARTUUID" ]; then
	echo "Error: Failed to read ESP PARTUUID from device tree" >&2
	exit 1
fi

echo "Found ESP PARTUUID: $ESP_PARTUUID"

# Find block device by PARTUUID
ESP_DEVICE="/dev/disk/by-partuuid/$ESP_PARTUUID"

if [ ! -b "$ESP_DEVICE" ]; then
	echo "Error: ESP device not found: $ESP_DEVICE" >&2
	exit 1
fi

echo "Found ESP device: $ESP_DEVICE"

# Mount ESP
if ! mount -t vfat "$ESP_DEVICE" /boot; then
	echo "Error: Failed to mount ESP" >&2
	exit 1
fi
echo "Mounted ESP to /boot"

cleanup() {
	if mountpoint -q /boot 2>/dev/null; then
		umount /boot || echo "Warning: Failed to unmount ESP" >&2
	fi
}
trap cleanup EXIT

# Check if firmware.cpio exists
if [ ! -f "/boot/vendorfw/firmware.cpio" ]; then
	umount /boot
	echo "Error: Firmware CPIO not found: /boot/vendorfw/firmware.cpio" >&2
	exit 1
fi

# Check for existing content and warn
if [ -n "$(ls -A /vendorfw 2>/dev/null)" ]; then
	echo "Warning: /vendorfw already contains files, overwriting..." >&2
fi

# Extract firmware CPIO
echo "Extracting vendor firmware..."
cd /
if ! cpio -dui -F "/boot/vendorfw/firmware.cpio"; then
	echo "Error: Failed to extract firmware CPIO" >&2
	exit 1
fi

ln -s /vendorfw /usr/lib/firmware/vendor

echo "Vendor firmware setup complete"
