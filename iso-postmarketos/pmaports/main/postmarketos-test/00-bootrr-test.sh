#!/bin/sh -e
# Description: bootrr sanity check

bootrr | tee bootrr.log

if [ grep -q 'fail' bootrr.log ]; then
	echo "PMOS-CI-TEST: bootrr sanity check failed"
	exit 1
fi
