#!/bin/sh
logger "Disconnected from charger"
echo 0 > /sys/class/leds/green/brightness
echo 100 > /sys/class/leds/red/brightness
