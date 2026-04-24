#!/bin/sh
set -e
echo "Capacity: $POWER_SUPPLY_CAPACITY; Voltage: $POWER_SUPPLY_VOLTAGE_NOW; Level: $POWER_SUPPLY_CAPACITY_LEVEL" >> /tmp/bq27k.log
if [ "$POWER_SUPPLY_CAPACITY_LEVEL" = "Low" ] || [ "$POWER_SUPPLY_CAPACITY_LEVEL" = "Critical" ]; then
	if [ "$POWER_SUPPLY_STATUS" != "Charging" ]; then
		/sbin/poweroff
	fi
fi
# Adjust polling rate based on reported voltage. As voltage drops to near
# critical levels, poll more frequently, in order to catch status changes
# early
if [ "$POWER_SUPPLY_VOLTAGE_NOW" -le 3350000 ]; then
	echo 5 > /sys/module/bq27xxx_battery/parameters/poll_interval
elif [ "$POWER_SUPPLY_VOLTAGE_NOW" -ge 3500000 ]; then
	echo 45 > /sys/module/bq27xxx_battery/parameters/poll_interval
fi
