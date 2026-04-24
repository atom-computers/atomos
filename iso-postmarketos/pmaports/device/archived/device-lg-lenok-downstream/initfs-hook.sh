#!/bin/sh

# set framebuffer resolution
echo 320,320 > /sys/class/graphics/fb0/virtual_size
