#!/bin/sh

# Calls to fbdebug were removed because
# they are the cause to the device's bootloop.

p=/sys/class/graphics/fb0
cat $p/modes > $p/mode
