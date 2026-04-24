#!/bin/sh

echo "PMOS: Entering APX" > /dev/kmsg

devmem2 0x7000E450 w 0x02
devmem2 0x7000E400 w 0x10
