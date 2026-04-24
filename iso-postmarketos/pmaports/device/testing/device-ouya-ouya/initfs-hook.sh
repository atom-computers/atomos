#!/bin/sh

# set cooling governor that is meant for simple on/off cooling fans
echo "bang_bang" | tee /sys/class/thermal/thermal_zone0/policy
