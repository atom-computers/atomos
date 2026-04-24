#!/bin/sh -e

deviceinfo_getty=""

# shellcheck disable=SC1091
. /usr/share/misc/source_deviceinfo

if [ -n "${deviceinfo_getty}" ]; then
	port=$(echo "${deviceinfo_getty}" | cut -s -d ";" -f 1)
	baudrate=$(echo "${deviceinfo_getty}" | cut -s -d ";" -f 2)

	if [ -n "${port}" ] && [ -n "${baudrate}" ]; then
		echo "Configuring a getty on port ${port} with baud rate ${baudrate}"
		sed -i -e "s/#ttyS0::respawn:\/sbin\/getty -L 115200 ttyS0 vt100/${port}::respawn:\/sbin\/getty -L ${baudrate} ${port} vt100/" /etc/inittab
	else
		echo "ERROR: Invalid value for deviceinfo_getty: ${deviceinfo_getty}"
		exit 1
	fi
fi

sync
exit 0
