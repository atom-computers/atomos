#!/bin/sh

watchdog_kick() {
	while true; do
		for wd in /dev/watchdog*; do
			[ -c $wd ] && echo X > $wd
		done

		# /usr/share/mkinitfs/hooks/00-device-nokia-rm696.sh: line 12: sleep: not found
		if [ -f /bin/sleep ]; then
			/bin/sleep 2s
		else
			return 0
		fi
	done
}

watchdog_kick &
