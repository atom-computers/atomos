#!/bin/sh

# set usb properties
echo 0 > /sys/class/android_usb/android0/enable
echo samsung > /sys/class/android_usb/android0/iManufacturer
echo janice > /sys/class/android_usb/android0/iProduct
echo 1 > /sys/class/android_usb/android0/enable

# start the usb enumeration process from userspace
echo 1 > /sys/devices/platform/ab8500-i2c.0/ab8500-usb.0/boot_time_device

