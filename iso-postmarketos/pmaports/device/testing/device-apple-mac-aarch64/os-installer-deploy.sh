#!/bin/sh

IMAGE_PATH="$1"
if [ ! -f "$IMAGE_PATH" ]; then
	echo "ERROR: No image given!"
	exit 1
fi

# Find ESP on local device, which should have the stage 2 bootloader that
# started this current session, then use that to locate the local storage device
# containing this ESP. If we're not installing to this device then throw an
# error.
ESP_UUID=$(cat /proc/device-tree/chosen/asahi,efi-system-partition)
ESP_PART_DEV=$(readlink -f "/dev/disk/by-partuuid/$ESP_UUID")
ESP_PART_NAME=$(basename "$ESP_PART_DEV")
LOCAL_DEVICE="/dev/$(basename "$(readlink -f "/sys/class/block/$ESP_PART_NAME/..")")"

if [ -z "$LOCAL_DEVICE" ]; then
	echo "ERROR: unable to find boot device!"
	exit 1
fi

# Check if installing to local device with stage2 ESP
if [ "$LOCAL_DEVICE" != "$OSI_DEVICE_PATH" ]; then
	echo "ERROR: This currently only supports installing to local storage ($LOCAL_DEVICE), selected device: $OSI_DEVICE_PATH"
	exit 1
fi

cleanup() {
	# Unmount ESP  and image ESP if mounted
	if mountpoint -q /mnt/esp 2>/dev/null; then
		doas umount /mnt/esp
	fi
	if mountpoint -q /mnt/image-esp 2>/dev/null; then
		doas umount /mnt/image-esp
	fi

	# Detach loop device
	if [ -n "$LOOP_DEV" ] && [ -e "$LOOP_DEV" ]; then
		doas losetup -d "$LOOP_DEV"
	fi
}

trap cleanup EXIT INT TERM

# Set up loop device to access image partitions
LOOP_DEV=$(doas losetup --find --show --partscan "$IMAGE_PATH")

# TODO: Don't hardcode partition layout assumptions
# Currently assuming: p1=ESP/boot, p2=root partition
IMG_ESP_PART="${LOOP_DEV}p1"
IMG_ROOT_PART="${LOOP_DEV}p2"

# The ESP's filesystem UUID won't match the UUID in the image's fstab, so let's
# set the ESP's filesystem UUID to the UUID of the image's ESP. This saves us
# from having to mount (and optionally decrypt) the image's rootfs to change
# fstab...
IMG_ESP_UUID=$(doas blkid -s UUID -o value "$IMG_ESP_PART")
if [ -z "$IMG_ESP_UUID" ]; then
	echo "ERROR: Could not get ESP UUID from image!"
	exit 1
fi
# The FAT32 UUID is actually the ID for the volume.
# Convert FAT32 UUID format (1234-5678) to 8-digit hex vol. ID (12345678)
IMG_ESP_VOL_ID=$(echo "$IMG_ESP_UUID" | tr -d '-')
echo "Setting target ESP serial to match image: $IMG_ESP_VOL_ID"
doas fatlabel -i "$ESP_PART_DEV" "$IMG_ESP_VOL_ID"

# Generate repart config and use CopyBlocks for block-level copy, which should
# preserve filesystem UUID, and (optional) luks
doas mkdir -p /run/repart.d
doas tee /run/repart.d/70-pmos-root.conf > /dev/null <<EOF
[Partition]
Type=root
CopyBlocks=${IMG_ROOT_PART}
SizeMinBytes=5G
EOF

# Create the rootfs on target device
doas systemd-repart --dry-run=no "$OSI_DEVICE_PATH"

# Mount ESP partitions and copy contents
doas mkdir -p /mnt/esp /mnt/image-esp
doas mount "$ESP_PART_DEV" /mnt/esp
doas mount "$IMG_ESP_PART" /mnt/image-esp
doas cp -a /mnt/image-esp/* /mnt/esp/
