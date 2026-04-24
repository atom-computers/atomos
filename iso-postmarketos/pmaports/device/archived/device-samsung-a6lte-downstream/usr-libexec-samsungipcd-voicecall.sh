#!/bin/sh
# This script sets up the audio subsystem to route audio to and from the modem.
# Called by samsungipcd when the call starts. When the call ends, we receive a
# newline and terminate ourselves.
# Note: as a side effect, software on the phone cannot access the microphone
# during a call.

# Put ourselves into a PID namespace. This is an easy and non-racey way to
# ensure that all child processes get killed on our exit.
if [ "$$" != 1 ]; then
	unshare -f -p sh "$0"
	exitcode="$?"
	# Restore MIC1 state to normal. We should be the only entity fiddling
	# with that.
	amixer -D sysdefault cset name='MIC1 MIC1 On' 1
	# Workaround for https://gitlab.freedesktop.org/mobile-broadband/ModemManager/-/issues/813
	mmcli -m 0 --voice-hangup-all
	exit "$exitcode"
fi

# callaudiod has already changed the UCM verb, no need to do it manually
#alsaucm set _verb 'Voice Call'

# In order for sound to be forwarded, there must be applictions that are
# currently playing and recording audio. To ensure that they exists, we
# connect to each user's PipeWire and start ones.

# Playback
for i in /run/user/*/; do
	# To avoid vulnerabilities in PulseAudio becoming LPEs, setuid to the
	# user running PipeWire.
	XDG_RUNTIME_DIR="$i" su -c 'aplay /dev/zero' "$(grep "^[^:]*:[^:]*:$(basename "$i"):" /etc/passwd | cut -d : -f 1-1)" &
done

# Same for recording
for i in /run/user/*/; do
	XDG_RUNTIME_DIR="$i" su -c 'arecord /dev/null' "$(grep "^[^:]*:[^:]*:$(basename "$i"):" /etc/passwd | cut -d : -f 1-1)" &
done

# Microphone switching logic
for i in /run/user/*/; do
	XDG_RUNTIME_DIR="$i" su -c '
		# Set locale to C to avoid parsing localized command output
		export LANG=C
		# Report microphone mute events
		( echo; pactl subscribe; ) | while read; do pactl get-source-mute @DEFAULT_SOURCE@; done
	' "$(grep "^[^:]*:[^:]*:$(basename "$i"):" /etc/passwd | cut -d : -f 1-1)" &
done | uniq | while read line; do
	if [[ "$line" == "Mute: yes" ]]; then
		amixer -D sysdefault cset name='MIC1 MIC1 On' 0
	elif [[ "$line" == "Mute: no" ]]; then
		amixer -D sysdefault cset name='MIC1 MIC1 On' 1
	fi
done &

# Wait for newline from samsungipcd. This means that the call has ended.
read

# No need to clean up, closing the PID namespace will kill all children
#jobs -p | xargs kill

# Again, callaudiod will switch UCM verbs for us
#alsaucm set _verb 'HiFi'
