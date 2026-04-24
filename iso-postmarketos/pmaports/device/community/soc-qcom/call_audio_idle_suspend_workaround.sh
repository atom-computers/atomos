#!/bin/sh

# dbus-monitor is run as a child process to this script. Kill child process too when the script terminates.
trap 'pkill -9 -P $$ && exit 0' INT TERM

interface=org.freedesktop.ModemManager1.Call
member=StateChanged

dbus-monitor --system "type='signal',interface='$interface',member='$member'" |
	while read -r line; do
		state=$(echo "$line" | awk '/\<int32\>/ {print $2}')
		if [ -n "$state" ]; then
			# Call State is based on https://www.freedesktop.org/software/ModemManager/doc/latest/ModemManager/ModemManager-Flags-and-Enumerations.html#MMCallState
			if [ "$state" -eq '0' ] || [ "$state" -eq '3' ]; then
				echo "Call Started"

				# Unload module-suspend-on-idle when call begins
				pidof pulseaudio && pactl unload-module module-suspend-on-idle

				# With Wireplumber audio, the Pulseaudio
				# compatibility layer doesn't support
				# loading/unloading the suspend module. Add
				# loopback sinks and sources instead.
				sleep 1
				pw-loopback -m '[FL FR]' --capture-props='media.class=Audio/Sink' &
				pw-loopback -m '[FL FR]' --playback-props='media.class=Audio/Source' &
			fi

			if [ "$state" -eq '7' ]; then
				echo "Call Ended"
				killall -9 pw-loopback &

				# Reload module-suspend-on-idle after call ends
				pidof pulseaudio && pactl load-module module-suspend-on-idle
			fi
		fi
	done &

wait
