#!/bin/sh

# Enable Display
cat /sys/class/graphics/fb0/modes > /sys/class/graphics/fb0/mode
