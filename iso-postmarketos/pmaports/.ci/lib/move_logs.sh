#!/bin/sh -e
# Copyright 2021 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later

if [ -z "$1" ]; then
	echo "usage: $(basename "$0") \$CI_PROJECT_DIR"
	exit 1
fi

for log in \
	/home/pmos/.local/var/pmbootstrap/log.txt \
	/home/pmos/.local/var/pmbootstrap/log_testsuite_pmaports.txt \
	/home/pmos/.config/pmbootstrap.cfg \
; do
	[ -e "$log" ] && mv "$log" "$1"
done
