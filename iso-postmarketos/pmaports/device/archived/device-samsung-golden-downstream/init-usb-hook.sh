#!/bin/sh

# Enable usb, pulled from TWRP sources
cat /sys/devices/platform/ab8500-i2c.0/ab8500-usb.0/serial_number  > /sys/devices/virtual/android_usb/android0/iSerial
cat /sys/devices/platform/ab8500-i2c.0/ab8500-usb.0/boot_time_device > /sys/devices/platform/ab8500-i2c.0/ab8500-usb.0/boot_time_device
cat /sys/devices/platform/ab8505-i2c.0/ab8500-usb.0/boot_time_device > /sys/devices/platform/ab8505-i2c.0/ab8500-usb.0/boot_time_device

