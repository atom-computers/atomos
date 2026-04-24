#!/bin/sh

# set framebuffer virtual size and panning
echo 736,2560 > /sys/class/graphics/fb0/virtual_size
echo 0,1280 > /sys/class/graphics/fb0/pan
echo 162 > /sys/class/leds/lcd-backlight/brightness

