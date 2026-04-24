#!/bin/ash

user=$( getent passwd 10000 | cut -d: -f1 )
cmd=$( echo $0 | awk '{i=split($0,a,"/"); print a[i]}' )

function adjust_keypad_bl {
	for i in $(seq 1 6); do
			echo $1 > /sys/class/leds/lp5523\:kb$i/brightness
	done
}

case $cmd in
	KP_SLIDE_OPEN)
		adjust_keypad_bl 63
		su $user -c 'DISPLAY=:0.0 /usr/bin/xset dpms force on'
		su $user -c 'DISPLAY=:0.0 /usr/bin/xinput enable "TSC2005 touchscreen"'
		;;
	KP_SLIDE_CLOSE)
		adjust_keypad_bl 0
		;;
	CAM_BTN_DWN)
		echo "Not implemented yet"
		;;
	CAM_BTN_UP)
		echo "Not implemented yet"
		;;
	CAM_FOCUS_DWN)
		echo "Not implemented yet"
		;;
	CAM_FOCUS_UP)
		echo "Not implemented yet"
		;;
	CAM_LID_CLOSE)
		echo "Not implemented yet"
		;;
	CAM_LID_OPEN)
		echo "Not implemented yet"
		;;
	SCRNLCK_DWN)
		echo "Not implemented yet"
		;;
	SCRNLCK_UP)
		echo "Not implemented yet"
		;;
	HEADPHONE_INSERT)
		alsactl restore -f /var/lib/alsa/asound.state.headset
		;;
	HEADPHONE_REMOVE)
		alsactl restore -f /var/lib/alsa/asound.state.speakers
		;;
	MICROPHONE_INSERT)
		echo "Not implemented yet"
		;;
	MICROPHONE_REMOVE)
		echo "Not implemented yet"
		;;
	VIDEOOUT_INSERT)
		echo "Not implemented yet"
		;;
	VIDEOOUT_REMOVE)
		echo "Not implemented yet"
		;;
	*)
		echo "Unknown event"
		exit 1
		;;
esac
