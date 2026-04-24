/*
 * Copyright (C) 2024 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include <fbd-feedback-vibra.h>

G_BEGIN_DECLS

void   fbd_feedback_vibra_set_duration (FbdFeedbackVibra *self, guint duration);
double fbd_feedback_vibra_get_max_strength (FbdFeedbackVibra *self);

G_END_DECLS
