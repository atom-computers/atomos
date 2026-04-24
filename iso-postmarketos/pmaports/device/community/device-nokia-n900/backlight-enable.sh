#!/bin/sh

# Enable backlight before the password prompt
echo 60 > /sys/class/backlight/acx565akm/brightness
