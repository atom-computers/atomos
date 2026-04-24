#!/bin/sh

# Set the backlight to MAX intensity
cat /sys/class/leds/wled-backlight/max_brightness > /sys/class/leds/wled-backlight/brightness

# Set to ""proper"" HxW
echo "480,800" > /sys/class/graphics/fb0/virtual_size
