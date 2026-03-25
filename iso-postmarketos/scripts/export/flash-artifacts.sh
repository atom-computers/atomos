#!/bin/bash
# Flash using the exported .img artifacts directly via fastboot.
# This is the correct path when building inside a VM (e.g. Multipass) and
# flashing from the macOS host, since fastboot needs a real USB connection
# that the VM cannot see.
#
# Usage (inside VM, to transfer then flash on host):
#   # 1. Copy artifacts from VM to Mac:
#   #    multipass transfer atomos-build:/path/to/build/host-export-fairphone-fp4/boot.img .
#   #    multipass transfer atomos-build:/path/to/build/host-export-fairphone-fp4/fairphone-fp4.img .
#   # 2. Run this script on macOS:
#   #    bash scripts/export/flash-artifacts.sh build/host-export-fairphone-fp4 fairphone-fp4
#
# Or if you have the build dir mounted / available locally:
#   bash scripts/export/flash-artifacts.sh build/host-export-fairphone-fp4 fairphone-fp4
set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <export-dir> <profile>" >&2
    echo "" >&2
    echo "  export-dir  Directory containing boot.img and <profile>.img" >&2
    echo "  profile     Device profile name, e.g. fairphone-fp4" >&2
    echo "" >&2
    echo "Example:" >&2
    echo "  $0 build/host-export-fairphone-fp4 fairphone-fp4" >&2
    exit 1
fi

EXPORT_DIR="$1"
PROFILE="$2"

BOOT_IMG="$EXPORT_DIR/boot.img"
ROOTFS_IMG="$EXPORT_DIR/${PROFILE}.img"

if [ ! -f "$BOOT_IMG" ]; then
    echo "ERROR: boot.img not found at $BOOT_IMG" >&2
    echo "  Run 'make build' first." >&2
    exit 1
fi
if [ ! -f "$ROOTFS_IMG" ]; then
    echo "ERROR: rootfs image not found at $ROOTFS_IMG" >&2
    echo "  Run 'make build' first." >&2
    exit 1
fi

if ! command -v fastboot >/dev/null 2>&1; then
    echo "ERROR: fastboot not found in PATH." >&2
    if [ "$(uname -s)" = "Darwin" ]; then
        echo "  Install with: brew install android-platform-tools" >&2
    else
        echo "  Install with: sudo apt-get install android-tools-fastboot" >&2
    fi
    exit 1
fi

echo "Checking fastboot devices..."
DEVICES="$(fastboot devices 2>/dev/null)"
if [ -z "$DEVICES" ]; then
    echo "ERROR: no device found in fastboot mode." >&2
    echo "  Boot the Fairphone 4 into fastboot:" >&2
    echo "    Power off → hold Volume Down + Power until fastboot screen appears" >&2
    echo "  Then run this script again." >&2
    exit 1
fi
echo "$DEVICES"

echo ""
echo "Flashing kernel: $BOOT_IMG"
fastboot flash boot "$BOOT_IMG"

echo ""
echo "Flashing rootfs: $ROOTFS_IMG"
fastboot flash userdata "$ROOTFS_IMG"

echo ""
echo "Rebooting..."
fastboot reboot

echo "Done. The device should now boot the new image."
