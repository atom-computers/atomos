#!/bin/sh

echo "PMOS DEBUG: kernel panic in 30s" > /dev/kmsg
sleep 30s

echo "PMOS DEBUG: kernel panic now" > /dev/kmsg
echo c > /proc/sysrq-trigger

