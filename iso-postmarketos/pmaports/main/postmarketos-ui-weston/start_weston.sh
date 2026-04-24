#!/bin/sh
# postmarketOS specific wrapper for weston to allow device specific configs,
# and to autostart postmarketos-demos.

export DISPLAY=:0

# Create XDG_RUNTIME_DIR
# https://wayland.freedesktop.org/building.html
XDG_RUNTIME_DIR=/tmp/$(id -u)-runtime-dir
export XDG_RUNTIME_DIR
if ! test -d "${XDG_RUNTIME_DIR}"; then
	mkdir "${XDG_RUNTIME_DIR}"
	chmod 0700 "${XDG_RUNTIME_DIR}"
fi

# Find right weston.ini
cfg="/etc/xdg/weston/weston.ini"
[ -e "$cfg" ] || cfg="$cfg.default"
WESTON_OPTS="--config=$cfg"

# #633: Weston doesn't support autostarting applications (yet), so
# we try to run postmarketos-demos for 10 seconds, until it succeeds.
(
	for _ in $(seq 0 19); do
		sleep 0.5
		postmarketos-demos && break
	done
) &


exec weston "${WESTON_OPTS}" 2>&1 | logger -t "$(whoami):weston"
