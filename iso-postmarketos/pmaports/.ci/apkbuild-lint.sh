#!/bin/sh -e
# Description: run apkbuild-lint on modified APKBUILDs
# Options: with-dot-git
# https://postmarketos.org/pmb-ci

if [ "$(id -u)" = 0 ]; then
	set -x
	apk add atools git python3
	exec su "${TESTUSER:-build}" -c "sh -e $0"
fi

.ci/lib/apkbuild_linting.py
