#!/bin/sh

# fix display for xorg
echo 0 > /sys/class/graphics/fb0/blank
echo 16 > /sys/devices/tegradc.0/graphics/fb0/bits_per_pixel
echo 0 0 > /sys/class/graphics/fb0/pan
