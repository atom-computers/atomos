#!/bin/sh

# Enable USB Power
echo 529 > /sys/class/gpio/export
echo "out" >/sys/class/gpio/gpio529/direction
echo 0 >  /sys/class/gpio/gpio529/value
# Wait 5 seconds to let the kernel detect the usb stick
sleep 5
