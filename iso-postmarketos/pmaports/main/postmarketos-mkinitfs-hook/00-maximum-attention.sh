#!/bin/sh

# shellcheck disable=SC1091
. ./init_functions.sh

BLINK_INTERVAL=2 # seconds
VIBRATION_DURATION=400 #ms
VIBRATION_INTERVAL=2 #s

find_leds() {
	find /sys -name "max_brightness" -print0 | xargs -0 -I{} dirname {}
}

find_vibrator() {
	echo /sys/class/timed_output/vibrator
}


# blink_leds takes a list of LEDs as parameters,
# it iterates over every LED, and changes their value,
# alternating between max_brightness and 0 every BLINK_INTERVAL
blink_leds() {
	state=false # false = off, true=on
	while true; do
		for led in "$@"; do
			if [ "$state" = true ]; then
				cat "$led"/max_brightness > "$led"/brightness
			else
				echo 0 > "$led"/brightness
			fi
			echo blinking LED: "$led"
		done
		sleep ${BLINK_INTERVAL}s
		if [ "$state" = true ]; then
			state=false
		else
			state=true
		fi
	done
}

# vibrate_loop vibrates each VIBRATION_INTERVAL for VIBRATION_DURATION
# it takes a timed_device path to the vibrator as $1
vibrate_loop() {
	if [ ! -f "$1"/enable ]; then
		return;
	fi

	while true; do
		echo $VIBRATION_DURATION > "$1"/enable
		sleep ${VIBRATION_INTERVAL}s
	done
}

blink_leds "$(find_leds)" &
vibrate_loop "$(find_vibrator)" &

fail_halt_boot
