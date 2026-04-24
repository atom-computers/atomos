#!/bin/sh

# enable touchscreen
echo 1 > /sys/devices/f9966000.i2c/i2c-1/1-004a/drv_irq

# write to screen brightness to fix black screen after splash
cat /sys/devices/fd900000.qcom,mdss_mdp/qcom,mdss_fb_primary.164/leds/lcd-backlight/brightness > \
	/sys/devices/fd900000.qcom,mdss_mdp/qcom,mdss_fb_primary.164/leds/lcd-backlight/brightness

