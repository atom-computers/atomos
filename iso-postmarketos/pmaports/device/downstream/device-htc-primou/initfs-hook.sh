#!/bin/sh

# set framebuffer resolution
echo 16 > /sys/class/graphics/fb0/bits_per_pixel
echo 480,1600 > /sys/class/graphics/fb0/virtual_size
