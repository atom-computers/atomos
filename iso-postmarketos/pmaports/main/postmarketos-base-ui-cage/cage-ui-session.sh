#!/bin/sh

. /usr/share/cage-ui/cage-ui-autorotate.sh

if [ -d /etc/cage-ui ]; then
	for script in /etc/cage-ui/*.sh; do
		# shellcheck source=/dev/null # since we do not control these scripts
		. "$script"
	done
fi

if [ -z "$CAGE_UI_COMMAND" ]; then
	if command -v postmarketos-demos >/dev/null 2>&1; then
		CAGE_UI_COMMAND=postmarketos-demos
	else
		echo "No command to run. Cage-UI expects a command to be run"
		echo "defined in environment variable named CAGE_UI_COMMAND."
		exit 1
	fi
fi

exec $CAGE_UI_COMMAND
