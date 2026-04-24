#!/bin/sh

while :
do
	# Wait for graphical environment to start
	until PID=$(pidof weston) || PID=$(pidof kwin_wayland) || PID=$(pidof xorg-server)
	do
		sleep 2
	done

	# Run msm-fb-refresher twice to workaround buggy framebuffer driver
	for _ in 1 2
	do
		msm-fb-refresher
	done

	wait "$PID"
done
