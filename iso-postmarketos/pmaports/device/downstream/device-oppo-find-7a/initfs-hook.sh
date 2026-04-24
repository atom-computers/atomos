#!/bin/sh

# set framebuffer virtual size
echo 1080,3840 > /sys/class/graphics/fb0/virtual_size
