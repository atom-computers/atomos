/*
 * Copyright (C) 2023 Dylan Van Assche <me@dylanvanassche.be>
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-dev-led-multicolor.h"

G_BEGIN_DECLS

#define FBD_TYPE_DEV_LED_QCOM_MULTICOLOR fbd_dev_led_qcom_multicolor_get_type()

G_DECLARE_FINAL_TYPE (FbdDevLedQcomMulticolor, fbd_dev_led_qcom_multicolor, FBD, DEV_LED_QCOM_MULTICOLOR, FbdDevLedMulticolor)

FbdDevLed          *fbd_dev_led_qcom_multicolor_new  (GUdevDevice *dev, GError **err);

G_END_DECLS
