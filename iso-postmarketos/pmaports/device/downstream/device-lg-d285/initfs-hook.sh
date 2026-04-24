#!/bin/sh

# set framebuffer resolution
echo 1 > /sys/devices/fd900000.qcom,mdss_mdp/qcom,mdss_fb_primary.134/leds/lcd-backlight/brightness
