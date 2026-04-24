#!/bin/sh
# Silence shellcheck's errorneous "(warning): In POSIX sh, 'enable' is undefined."
# shellcheck disable=3044
set -e

set_kbd_backlight() {
	for i in $(seq 1 6); do
		brightnessctl --quiet --device="*kb$i" s "$1"
	done
}

enable() {
	swaymsg input "0:2005:TSC2005_touchscreen" events enabled
	swaymsg output DPI-1 power on
	set_kbd_backlight 25
	swaymsg exec "swayidle timeout 120 'swaymsg exec sway-saver.sh disable'"
}

disable() {
	swaymsg input "0:2005:TSC2005_touchscreen" events disabled
	swaymsg output DPI-1 power off
	set_kbd_backlight 0
	pkill -f swayidle
}

# Enable/disable based on cmdline parameter
if [ "$#" -eq 1 ]; then
	case "$1" in
		enable|disable)
			eval "$1"
			;;
	esac
	exit 0
fi

state_touch=$(swaymsg -t get_inputs | jq -r '.[] | select (.identifier == "0:2005:TSC2005_touchscreen") | .libinput.send_events')

# Toggle enabled/disabled state
case "$state_touch" in
	disabled)
		enable
		;;
	enabled)
		disable
		;;
esac
