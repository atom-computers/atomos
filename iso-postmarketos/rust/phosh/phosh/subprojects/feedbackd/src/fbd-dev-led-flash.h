/*
 * Copyright (C) 2024 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-dev-led.h"

G_BEGIN_DECLS

#define FBD_TYPE_DEV_LED_FLASH fbd_dev_led_flash_get_type()

G_DECLARE_FINAL_TYPE (FbdDevLedFlash, fbd_dev_led_flash, FBD, DEV_LED_FLASH, FbdDevLed)

FbdDevLed          *fbd_dev_led_flash_new  (GUdevDevice *dev, GError **err);

G_END_DECLS
