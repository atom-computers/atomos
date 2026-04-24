#!/bin/sh -e
# Description: check modified kernel configs
# Options: native
# Use 'native' because it requires running pmbootstrap.
# https://postmarketos.org/pmb-ci

if [ "$(id -u)" = 0 ]; then
	set -x
	wget "https://gitlab.postmarketos.org/postmarketOS/ci-common/-/raw/main/install_pmbootstrap.sh"
	sh ./install_pmbootstrap.sh
	exec su "${TESTUSER:-pmos}" -c "sh -e $0"
fi

export PYTHONUNBUFFERED=1

.ci/lib/kconfig.py
