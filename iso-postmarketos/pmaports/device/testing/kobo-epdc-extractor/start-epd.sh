#!/bin/sh
extract-waveform.sh
cd /sys/bus/platform/devices
echo *epdc >/sys/bus/platform/drivers/mxc_epdc/bind
