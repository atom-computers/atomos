#!/bin/sh -e
# Copyright 2023 Oliver Smith
# SPDX-License-Identifier: GPL-3.0-or-later

if ! mount | grep -q /proc/sys/fs/binfmt_misc; then
	echo "Mounting binfmt_misc"
	mount -t binfmt_misc none /proc/sys/fs/binfmt_misc
fi

if id "build" > /dev/null 2>&1; then
	echo "User 'build' exists already"
else
	echo "Creating build user"
	adduser -D build
	chown -R build:build .
	echo 'build ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers
fi
