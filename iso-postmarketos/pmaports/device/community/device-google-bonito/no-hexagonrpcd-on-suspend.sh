#!/bin/sh

if [ "$1" = "pre" ]
then
	# If HexagonRPCD listens for a remote method call while the device is
	# waking up, the DSP may crash. Assume that HexagonRPCD has fulfilled
	# all incoming remote method invocations, and stop it.
	rc-service hexagonrpcd-adsp-sensorspd stop
fi
