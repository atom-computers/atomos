/*
 * Copyright (C) 2023 Dylan Van Assche <me@dylanvanassche.be>
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-dev-led.h"

G_BEGIN_DECLS

#define FBD_TYPE_DEV_LED_QCOM fbd_dev_led_qcom_get_type()

G_DECLARE_FINAL_TYPE (FbdDevLedQcom, fbd_dev_led_qcom, FBD, DEV_LED_QCOM, FbdDevLed)

FbdDevLed          *fbd_dev_led_qcom_new  (GUdevDevice *dev, GError **err);

G_END_DECLS
