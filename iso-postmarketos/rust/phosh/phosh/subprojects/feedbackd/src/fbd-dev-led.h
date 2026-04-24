/*
 * Copyright (C) 2023 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-feedback-led.h"

#include <gudev/gudev.h>

#include <glib-object.h>

G_BEGIN_DECLS

#define FBD_TYPE_DEV_LED fbd_dev_led_get_type()

G_DECLARE_DERIVABLE_TYPE (FbdDevLed, fbd_dev_led, FBD, DEV_LED, GObject)

FbdDevLed          *fbd_dev_led_new  (GUdevDevice *dev, GError **err);
gboolean            fbd_dev_led_set_brightness (FbdDevLed *led, guint brightness);
guint               fbd_dev_led_get_max_brightness (FbdDevLed *led);
gboolean            fbd_dev_led_set_color (FbdDevLed           *led,
                                           FbdFeedbackLedColor  color,
                                           FbdLedRgbColor      *rgb);
gboolean            fbd_dev_led_start_periodic (FbdDevLed      *led,
                                                guint           max_brightness_percentage,
                                                guint           freq);
gboolean            fbd_dev_led_supports_color (FbdDevLed *led, FbdFeedbackLedColor color);
int                 fbd_dev_led_get_priority (FbdDevLed *self);

struct _FbdDevLedClass {
  GObjectClass parent_class;

  gboolean (*probe)          (FbdDevLed            *led, GError **error);
  gboolean (*start_periodic) (FbdDevLed           *led,
                              guint                max_brightness_percentage,
                              guint                freq);
  gboolean (*set_color)      (FbdDevLed            *led,
                              FbdFeedbackLedColor   color,
                              FbdLedRgbColor       *rgb);
  gboolean (*supports_color) (FbdDevLed            *led,
                              FbdFeedbackLedColor   color);
};

G_END_DECLS
