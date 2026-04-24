#!/bin/sh

# enable touchscreen
echo 1 > /sys/devices/soc/78b7000.i2c/i2c-3/3-0020/drv_irq

# fixes the "boot to black screen" issue
echo 0 0 > /sys/class/graphics/fb0/pan

# Start Panel
startx
