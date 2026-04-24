#!/bin/sh -e
# Execute the binary from the native chroot if it is installed there. This is
# done for archiver tools such as unxz, so they don't need to go through QEMU.
BASENAME="$(basename "$0")"

if [ -n "$LD_PRELOAD" ]; then
	# The archiver tool gets called during package(), which abuild runs
	# with libfakeroot.so. Some packages do this, like bootchart2, which
	# compresses man pages in its "make install". We can't run the native
	# binary here due to the LD_PRELOAD, so run the foreign arch one.
	export PATH="/usr/bin:/usr/sbin:/sbin:/bin"
	exec "$BASENAME" "$@"
fi

# Try /native first, then the foreign arch paths. Never try
# /native/usr/lib/crossdirect as this would result in a loop.
UNWRAPPED_PATH="/native/usr/bin:/native/usr/sbin:/native/sbin:/native/bin:/usr/bin:/usr/sbin:/sbin:/bin"
UNWRAPPED_BIN="$(PATH="$UNWRAPPED_PATH" command -v "$BASENAME")"

case "$UNWRAPPED_BIN" in
	/native/*)
		export LD_LIBRARY_PATH="/native/usr/lib:/native/lib"
		export PATH="$UNWRAPPED_PATH"
		;;
esac

exec "$UNWRAPPED_BIN" "$@"
