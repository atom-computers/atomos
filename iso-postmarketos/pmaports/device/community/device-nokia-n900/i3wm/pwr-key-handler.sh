#!/bin/sh

confirm(){
	printf "Yes\nNo" | dmenu -l 2 -p "Are you sure?" -H 60
}

CHOICE=$(printf "Close this menu\nTake screenshot\nReboot\nPower Off" | dmenu -l 5 -p "Choose an action" -H 50)

case "$CHOICE" in
	*screenshot)
		mkdir -p "$HOME"/Screenshots
		# shellcheck disable=SC2016
		# the variable $f is internal to scrot, see `man 1 scrot`
		scrot '%Y-%m-%d_%H-%M-%S.png' -e 'mv $f ~/Screenshots/'
		;;
	Reboot)
		CONFIRM=$(confirm)
		case "$CONFIRM" in
			Yes)
				loginctl reboot
				;;
		esac
		;;
	Power*)
		CONFIRM=$(confirm)
		case "$CONFIRM" in
			 Yes)
				loginctl poweroff
				;;
		esac
	;;
esac
