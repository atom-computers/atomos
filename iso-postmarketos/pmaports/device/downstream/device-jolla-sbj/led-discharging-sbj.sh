#!/bin/sh
logger "Disconnected from charger"
echo 0 > /sys/class/leds/led:rgb_red/brightness
