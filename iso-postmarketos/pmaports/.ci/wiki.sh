#!/bin/sh -e
# Description: verify devices are documented in the wiki
# Options: native
# Run natively so we don't need to set up a chroot, python3 is the only dep.
# https://postmarketos.org/pmb-ci

if [ "$(id -u)" = 0 ]; then
	set -x
	apk -q add \
		git \
		python3
	exec su "${TESTUSER:-build}" -c "sh -e $0"
fi

set -x
# shellcheck disable=SC2068
.ci/lib/check_devices_in_wiki.py --booting $@
