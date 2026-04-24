#!/bin/sh

# $1 is path to generated initramfs, we want to work on boot.img
bootimgfile=$(echo "${1}" | sed 's/initramfs/boot.img/g')
avbtool add_hash_footer --partition_name boot --image "${bootimgfile}" --dynamic_partition_size
