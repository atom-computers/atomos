#!/bin/sh -e
# Copyright 2025 Pablo Correa Gomez
# SPDX-License-Identifier: GPL-3.0-or-later
# Description: create documentation with antora
# Options: with-dot-git
# Artifacts: build/site
# https://postmarketos.org/pmb-ci


# Install dependencies
if [ "$(id -u)" = 0 ]; then
	set -x
	apk -q add py3-pip make git
	apk add dint --allow-untrusted --repository=https://mirror.postmarketos.org/postmarketos/main
	exec su "${TESTUSER:-build}" -c "sh -e $0"
fi

cd docs/
make venv
make
