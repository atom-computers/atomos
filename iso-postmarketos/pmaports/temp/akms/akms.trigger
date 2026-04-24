#!/bin/sh

# shellcheck disable=SC1090
CFG_FILE='/etc/akms.conf'

if ! [ -f "$CFG_FILE" ]; then
	echo "$CFG_FILE does not exist, skipping akms trigger" >&2
	exit 0
fi

. "$CFG_FILE"

# shellcheck disable=SC2154
case "$disable_trigger" in
	yes | true | 1) exit 0;;
esac

for srcdir in "$@"; do
	[ -f "$srcdir"/AKMBUILD ] || continue
	if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ]; then
		echo ">>> AKMS is running in chroot environment, disabling overlay and sandboxing"
		echo ">>> Please make sure module build dependencies are already installed"
		akms install --no-overlay --no-sandbox "$srcdir"
	else
		echo ">>> AKMS running in sandbox"
		akms install "$srcdir"
	fi

done

# Triggers exiting with non-zero status cause headaches. APK marks the
# corresponding package and the world as broken and starts exiting with
# status 1 even after e.g. successful installation of a new package.
exit 0
