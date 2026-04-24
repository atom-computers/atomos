#!/bin/sh

# Framebuffer
echo 0,1280 > /sys/devices/virtual/graphics/fb0/pan
echo 720,2560 > /sys/devices/virtual/graphics/fb0/virtual_size

