#!/bin/sh

# Fix ALSA audio play
echo 1 > /proc/driver/ssp_master
