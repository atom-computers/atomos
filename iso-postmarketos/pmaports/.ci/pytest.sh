#!/bin/sh -e
# Copyright 2023 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later
# Description: lint with various python tests
# Options: native
# Use 'native' because it requires running pmbootstrap.
# https://postmarketos.org/pmb-ci

if [ "$(id -u)" = 0 ]; then
	set -x
	wget "https://gitlab.postmarketos.org/postmarketOS/ci-common/-/raw/main/install_pmbootstrap.sh"
	sh ./install_pmbootstrap.sh pytest
	exec su "${TESTUSER:-pmos}" -c "sh -e $0"
fi

# Require pytest to be installed on the host system
if [ -z "$(command -v pytest)" ]; then
	echo "ERROR: pytest command not found, make sure it is in your PATH."
	exit 1
fi

pmaports="$(cd "$(dirname "$0")"/..; pwd -P)"
# Make sure that the work folder format is up to date, and that there are no
# mounts from aborted test cases (pmbootstrap#1595)
pmbootstrap work_migrate
pmbootstrap config aports "$pmaports"
pmbootstrap -q shutdown

# Needed to import "common"
export PYTHONPATH="$PYTHONPATH:.ci/lib"
# Run testcases
pytest -vv --tb=native "$pmaports/.ci/testcases" "$@"
