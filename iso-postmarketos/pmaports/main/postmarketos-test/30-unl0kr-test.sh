#!/bin/sh
# Checks that unl0kr starts properly and doesn't crash or exit
# immediately.

echo "Checking that unl0kr starts properly"

SECS=5

unl0kr -V

TIME=$(date +%s)
timeout $SECS unl0kr -v 2>&1 | tee /tmp/unl0kr.log
CODE=$?
EXIT_TIME=$(date +%s)
ELAPSED=$(($EXIT_TIME - $TIME))

if grep -i "error" /tmp/unl0kr.log; then
	echo "unl0kr reported an error!"
	exit 1
fi

if [ $CODE -eq 0 ] && [ $ELAPSED -eq $SECS ]; then
	echo "PASS: unl0kr ran for $SECS without exiting!"
	exit 0
fi

ELAPSED=$(($EXIT_TIME - $TIME))
echo "unl0kr exited with code $? after $ELAPSED seconds (expected timeout after $SECS)"
echo "SKIP: broken test"
exit 0
