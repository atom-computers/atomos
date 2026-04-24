#!/bin/sh -e
# Description: editorconfig-checker: lint for trailing whitespaces etc.
# https://postmarketos.org/pmb-ci

if [ "$(id -u)" = 0 ]; then
	set -x
	apk -q add \
		editorconfig-checker
	exec su "${TESTUSER:-build}" -c "sh -e $0"
fi

set -x
ec
