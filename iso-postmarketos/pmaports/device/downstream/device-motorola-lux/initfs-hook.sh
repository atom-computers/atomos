#!/bin/sh

# activate touchscreen
echo 1 > /sys/devices/soc.0/78b8000.i2c/i2c-4/4-0020/drv_irq
