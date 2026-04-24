#!/bin/sh -e
# Description: Validate and lint deviceinfo files
# Options: with-dot-git
# https://postmarketos.org/pmb-ci

if [ "$(id -u)" = 0 ]; then
	set -x
	apk add git python3
	apk add dint --allow-untrusted --repository=https://mirror.postmarketos.org/postmarketos/main
	exec su "${TESTUSER:-build}" -c "sh -e $0"
fi

.ci/lib/deviceinfo_linting.py
