#!/bin/sh

touch_state=$(xinput list-props "TSC2005 touchscreen" | grep "Device Enabled" | tr -d "\t" | cut -d ":" -f 2)

case "$touch_state" in
	0)
		xinput enable "TSC2005 touchscreen"
		xset dpms force on
		;;
	1)
		xinput disable "TSC2005 touchscreen"
		xset dpms force off
		;;
esac
