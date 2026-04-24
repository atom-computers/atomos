#!/bin/sh

mkdir -p /efs
umount /efs 2>/dev/null || true
mount -o ro /dev/disk/by-partlabel/EFS /efs
