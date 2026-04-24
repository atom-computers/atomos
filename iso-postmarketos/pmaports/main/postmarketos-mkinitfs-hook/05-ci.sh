#!/bin/sh
# shellcheck shell=busybox

# shellcheck disable=SC1091
. ./init_functions.sh
. /usr/share/misc/source_deviceinfo

# Prints a given string a couple of times, over a span of time
# This helps paper over weirdness where the output may not flush
# as eagerly as expected, and the CI may miss the messages.
# This also helps if any messages would end-up interleaved.
_report_ci() {
	local precision=1000
	local duration=2
	local count=3
	while [ "$((count = count - 1))" -gt 0 ]; do
		printf '%s\n' "$@"
		sleep "$(printf '0.%03d' "$(( precision * duration / count ))")"
	done
}

DID_FAIL=0

echo "==> Running postmarketos-mkinitfs-hook-ci"

for f in /usr/libexec/pmos-tests-initramfs/*; do
	printf '\n==> Running test "%s"\n\n\n' "$f"
	if $f; then
		echo "==> OK: $f"
	else
		echo "==> FAIL: $f"
		DID_FAIL=1
	fi
done

if [ $DID_FAIL -ne 0 ]; then
	_report_ci "==> PMOS-CI-FAIL"
else
	_report_ci "==> PMOS-CI-OK"
fi

# We're done, kill it
# CDBA will exit if it sees 20 '~' characters
# in a row, send a whole bunch just to be sure
# In the worst case it will timeout.
_report_ci "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# CI tests done, disabling console and looping forever
dmesg -n 1
fail_halt_boot
