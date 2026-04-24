#!/bin/sh

# enable display
echo 120 > /sys/class/leds/lcd-backlight/brightness
echo "U:320x480p-0" > /sys/class/graphics/fb0/mode

