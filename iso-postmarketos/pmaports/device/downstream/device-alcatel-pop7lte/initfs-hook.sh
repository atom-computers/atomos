#!/bin/sh

# Blank and set brightness (fixes blank screen after boot splash)
echo 0 > /sys/class/graphics/fb0/blank
echo 255 > /sys/devices/fd900000.qcom,mdss_mdp/qcom,mdss_fb_primary.139/leds/lcd-backlight/brightness

