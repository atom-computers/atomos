#!/bin/sh

# blank and unblank for pmOS splash screen
echo 1 > /sys/class/graphics/fb0/blank
echo 0 > /sys/class/graphics/fb0/blank

if
	# phone booted by plugging in charger,
	# touchscreen will not work if we continue booting
	grep -q androidboot.mode=charger /proc/cmdline
then
	# allow for some charging to avoid infinite bootloop if critically low,
	# "poor man's charging-sdl"
	if grep -qx 0 /sys/class/power_supply/battery/capacity ; then sleep 24 ; fi

	# a reboot suffices to get the phone working normally,
	# this will show the samsung splash, unlike the initial boot
	reboot -ff
fi
