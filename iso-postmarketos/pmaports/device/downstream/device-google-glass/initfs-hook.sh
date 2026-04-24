#!/bin/sh

# Enable Display
echo 1 > /sys/devices/platform/omapdss/manager2/panel-notle-dpi/enabled
echo 160 > /sys/devices/platform/omapdss/manager2/panel-notle-dpi/brightness
echo 0 > /sys/devices/platform/omapfb/graphics/fb0/blank
echo "U:640x360p-312" > /sys/devices/platform/omapfb/graphics/fb0/mode

