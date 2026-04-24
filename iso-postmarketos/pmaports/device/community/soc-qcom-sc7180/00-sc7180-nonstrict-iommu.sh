#!/bin/sh

# This script relaxes iommu for the devices, relaxing memory
# protection, but we consider it a fine tradeoff because those
# hardware blocks don't have firmware on them.

# It Increases eMMC speed by 15% according to gnome disks benchmark
# with sample size 1000 MiB and number of samples 2.

iommus="
	/sys/devices/platform/soc@0/7c4000.mmc/iommu_group/type
	/sys/devices/platform/soc@0/8804000.mmc/iommu_group/type
	/sys/devices/platform/soc@0/a6f8800.usb/a600000.usb/iommu_group/type
"

for iommu in $iommus; do
	[ -f "$iommu" ] && echo "DMA-FQ" > "$iommu"
done
