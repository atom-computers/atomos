#!/bin/sh -e
# Description: run unit-tests for packages
# https://postmarketos.org/pmb-ci
#
# This script only exists to allow running unit-tests locally.
# In actual CI the package tests/ subdir has it's own YAML
# fine defining a job which calls testlib for that package.
# This way we can run all the package unit-tests locally but
# have them be individual jobs in GitLab.

if [ "$(id -u)" = 0 ]; then
	set -x
	exec su "${TESTUSER:-build}" -c "sh -e $0"
fi

find . -type d -name "tests" | while read -r testdir; do
	pkg="$(basename "$(dirname "$testdir")")"
	.ci/lib/testlib.sh "$testdir" "$pkg"
done
