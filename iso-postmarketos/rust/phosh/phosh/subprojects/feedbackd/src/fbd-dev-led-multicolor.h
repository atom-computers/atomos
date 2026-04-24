/*
 * Copyright (C) 2023 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-dev-led.h"

G_BEGIN_DECLS

#define FBD_TYPE_DEV_LED_MULTICOLOR fbd_dev_led_multicolor_get_type()

G_DECLARE_DERIVABLE_TYPE (FbdDevLedMulticolor, fbd_dev_led_multicolor, FBD, DEV_LED_MULTICOLOR, FbdDevLed)

FbdDevLed          *fbd_dev_led_multicolor_new  (GUdevDevice *dev, GError **err);

struct _FbdDevLedMulticolorClass {
  FbdDevLedClass parent_class;
};

G_END_DECLS
