#!/bin/sh
# Set the postmarketOS wallpaper in Plasma based UIs. Replace this hack when we
# have a cleaner method: https://bugs.kde.org/show_bug.cgi?id=487816

MARKER=~/.local/state/postmarketos/plasma-wallpaper-has-been-set
WALLPAPER_PATH="/usr/share/wallpapers/postmarketos"

# Only run this script in Plasma sessions. This variable is set in in both
# Plasma Desktop and Plasma Mobile (unlike e.g. XDG_DESKTOP_SESSION).
if [ -z "$KDE_FULL_SESSION" ]; then
	exit 1
fi

# Only run this script once. If the user selects a different wallpaper
# afterwards, it should not be changed.
if [ -e "$MARKER" ]; then
	exit 0
fi

echo "set-plasma-wallpaper: changing to: $WALLPAPER_PATH"

# Unfortunately this fails if the D-Bus API isn't available yet. So we have to
# try multiple times.
for i in $(seq 1 30); do
	sleep 1

	if ! plasma-apply-wallpaperimage "$WALLPAPER_PATH"; then
		continue
	fi

	mkdir -p "$(dirname "$MARKER")"
	touch "$MARKER"
	echo "set-plasma-wallpaper: success"
	exit 0
done

echo "set-plasma-wallpaper: failed"
exit 1
