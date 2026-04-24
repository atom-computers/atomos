#!/bin/sh

# blank and unblank for pmOS splash screen
echo 1 > /sys/class/graphics/fb0/blank
echo 0 > /sys/class/graphics/fb0/blank
