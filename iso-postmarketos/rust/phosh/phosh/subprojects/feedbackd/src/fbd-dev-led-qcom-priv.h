/*
 * Copyright (C) 2023 Dylan Van Assche <me@dylanvanassche.be>
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-dev-led-qcom.h"

#include <glib-object.h>

G_BEGIN_DECLS

gboolean fbd_dev_led_probe_qcom (FbdDevLed *led, GError **error);

G_END_DECLS
