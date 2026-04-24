/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-feedback-led.h"
#include "fbd-udev.h"

#include <glib-object.h>

G_BEGIN_DECLS

#define FBD_TYPE_DEV_LEDS (fbd_dev_leds_get_type ())

G_DECLARE_FINAL_TYPE (FbdDevLeds, fbd_dev_leds, FBD, DEV_LEDS, GObject);

FbdDevLeds *fbd_dev_leds_new (GError **error);
gboolean    fbd_dev_leds_start_periodic (FbdDevLeds          *self,
                                         FbdFeedbackLedColor  color,
                                         FbdLedRgbColor      *rgb,
                                         guint                max_brighness,
                                         guint                freq);
gboolean    fbd_dev_leds_stop (FbdDevLeds *self, FbdFeedbackLedColor color);
gboolean    fbd_dev_leds_has_led (FbdDevLeds *self, FbdFeedbackLedColor color);

G_END_DECLS
