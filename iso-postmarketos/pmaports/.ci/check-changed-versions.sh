#!/bin/sh -e
# Copyright 2023 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later
# Description: check pkgver/pkgrel bumps, amount of changed pkgs etc
# Options: native
# Use 'native' because it requires running pmbootstrap.
# https://postmarketos.org/pmb-ci

if [ "$(id -u)" = 0 ]; then
	set -x
	# In .gitlab-ci.yml currently .ci/pytest.sh runs before this and
	# already downloads and runs install_pmbootstrap.sh.
	if ! [ -e install_pmbootstrap.sh ]; then
		wget "https://gitlab.postmarketos.org/postmarketOS/ci-common/-/raw/main/install_pmbootstrap.sh"
		sh ./install_pmbootstrap.sh
	fi
	exec su "${TESTUSER:-pmos}" -c "sh -e $0"
fi

.ci/lib/check_changed_versions.py
