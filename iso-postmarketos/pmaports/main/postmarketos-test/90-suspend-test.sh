#!/bin/sh
# Validate suspend/resume cycle

echo "Checking that suspend works"

SLEEP_TIME=6

if [ ! -e /sys/class/rtc/rtc0 ]; then
	echo "SKIP: No RTC found"
	exit 0
fi

time=$(($(cat /sys/class/rtc/rtc0/since_epoch) + $SLEEP_TIME))
echo $time | tee /sys/class/rtc/rtc0/wakealarm
echo mem | tee /sys/power/state
sleep 3 # wait for the system to suspend
if [ $(cat /sys/class/rtc/rtc0/since_epoch) -lt $time ]; then
	echo "FAIL: System did not suspend"
	exit 1
fi
echo "PASS: System suspended and woke up again"
# The other failure mode is that we don't wake up again...
