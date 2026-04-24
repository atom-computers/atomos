main() {
	# Wait until graphical environment is running
	sleep 5
	# Workaround for buggy graphics driver
	while [ ! ];
	do
		echo '0,0' > /sys/class/graphics/fb0/pan;
	done
}

# tty1 autologin
if [ $(tty) = "/dev/tty1" ]; then
	# Run in background, to make /etc/profile not wait for it to finish
	main &
fi
