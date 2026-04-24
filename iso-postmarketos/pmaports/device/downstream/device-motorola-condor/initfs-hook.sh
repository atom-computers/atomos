#!/bin/sh

echo 1 > /sys/class/i2c-dev/i2c-1/device/1-0020/drv_irq
echo 1 > /sys/class/i2c-dev/i2c-1/device/1-0020/reset
