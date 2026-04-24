#!/bin/sh

# enable touchscreen
sleep 5 # a little delay before activating touchscreen
echo 1 > /sys/devices/soc/78b7000.i2c/i2c-3/3-0020/drv_irq

