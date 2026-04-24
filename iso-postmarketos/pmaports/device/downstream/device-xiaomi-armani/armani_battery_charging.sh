#!/bin/sh
logger "Battery is in charging state"
echo 0 > /sys/class/leds/red/brightness
echo 100 > /sys/class/leds/green/brightness
