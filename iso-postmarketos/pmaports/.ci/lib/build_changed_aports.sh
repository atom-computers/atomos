#!/bin/sh -e
# Description: build modified packages for this architecture
# Options: native slow
# Use 'native' because it requires running pmbootstrap.
# https://postmarketos.org/pmb-ci

if [ "$(id -u)" = 0 ]; then
	set -x
	wget "https://gitlab.postmarketos.org/postmarketOS/ci-common/-/raw/main/install_pmbootstrap.sh"
	sh ./install_pmbootstrap.sh
	exec su "${TESTUSER:-pmos}" -c "sh -e $0"
fi

export PYTHONUNBUFFERED=1

# Get the architecture from the symlink we are running
arch="$(echo "$0" | cut -d '-' -f 2 | cut -d '.' -f 1)"

set -x
.ci/lib/build_changed_aports.py "$arch"
