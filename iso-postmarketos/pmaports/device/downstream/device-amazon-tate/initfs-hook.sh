#!/bin/sh

# Turn overlay0 off and on again to remove bootloader screen
echo 0 > /sys/devices/platform/omapdss/overlay0/enabled
echo 1 > /sys/devices/platform/omapdss/overlay0/enabled
