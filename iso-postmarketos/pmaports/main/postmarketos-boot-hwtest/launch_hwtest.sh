#!/bin/sh

if [ "$(id -u)" = "10000" ] && [ $(tty) = "/dev/tty1" ]; then
	if [ -f /usr/share/hwtest.ini ]; then
		dbus-launch hwtest --verify /usr/share/hwtest.ini --export ~/hwtest.ini --formatter ColoredTTY
	else
		dbus-launch hwtest --formatter ColoredTTY --export ~/hwtest.ini
	fi
fi
