/*
 * Copyright (C) 2023 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-dev-led.h"
#include "fbd-feedback-led.h"

#include <gudev/gudev.h>
#include <glib-object.h>

G_BEGIN_DECLS

#define LED_MAX_BRIGHTNESS_ATTR  "max_brightness"

GUdevDevice      *fbd_dev_led_get_device  (FbdDevLed *led);
void              fbd_dev_led_set_max_brightness (FbdDevLed *led, guint max_brightness);
void              fbd_dev_led_set_supported_color (FbdDevLed *led, FbdFeedbackLedColor color);
void              fbd_dev_led_set_priority (FbdDevLed *self, int priority);

G_END_DECLS
