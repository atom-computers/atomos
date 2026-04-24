#!/bin/sh
logger "Battery is in charging state"
echo 100 > /sys/class/leds/led:rgb_red/brightness
