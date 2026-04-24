#!/bin/sh
# Stop the default bar. For unknown reasons, these commands do not work from
# inside the config
(
	sleep 3
	swaymsg bar bar-0 status_command -
	swaymsg bar mode invisible bar-0
)  &
