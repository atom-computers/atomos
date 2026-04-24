#!/bin/sh

# postmarketos-mkinitfs's init script does already have a framebuffer workaround script
# but that script checks if fb0/mode is empty. in our case, it already has the correct value
# but the framebuffer is nevertheless not doing anything.
# additionally if we set the mode again the at time the postmarketos init script does,
# absolutely nothing happens. It seems to work if we sleep 5 seconds to give whatever needs
# more time, more time and then set the framebuffer mode again.


set_xiaomi_ido_framebuffer_mode() {
	[ -e "/sys/class/graphics/fb0/modes" ] || return
	[ -e "/sys/class/graphics/fb0/mode" ] || return

	_mode="$(cat /sys/class/graphics/fb0/modes)"
	echo "Setting framebuffer mode to: $_mode"
	echo "$_mode" > /sys/class/graphics/fb0/mode
}

sleep 5 && set_xiaomi_ido_framebuffer_mode &
