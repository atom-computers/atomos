#!/bin/sh
# Initramfs hook to copy vendor firmware to final rootfs before switchroot

set -e

# Check if vendor firmware was extracted
if [ ! -d /vendorfw ] || [ -z "$(ls -A /vendorfw 2>/dev/null)" ]; then
	echo "No vendor firmware found, skipping copy"
	exit 0
fi

echo "Copying vendor firmware to target rootfs..."

# Create vendor firmware directory in target rootfs
mkdir -p /sysroot/usr/lib/firmware/vendor

# Mount tmpfs for vendor firmware
if ! mount -t tmpfs -o mode=0755 vendorfw /sysroot/usr/lib/firmware/vendor; then
	echo "Error: Failed to mount tmpfs at /sysroot/usr/lib/firmware/vendor" >&2
	exit 1
fi

# Copy vendor firmware
if ! cp -a /vendorfw/* /vendorfw/.vendorfw.manifest /sysroot/usr/lib/firmware/vendor/; then
	umount /sysroot/usr/lib/firmware/vendor
	echo "Error: Failed to copy vendor firmware" >&2
	exit 1
fi

echo "Vendor firmware copied to /usr/lib/firmware/vendor"
