/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-feedback-vibra.h"

G_BEGIN_DECLS

#define FBD_TYPE_FEEDBACK_VIBRA_RUMBLE (fbd_feedback_vibra_rumble_get_type())

G_DECLARE_FINAL_TYPE (FbdFeedbackVibraRumble, fbd_feedback_vibra_rumble, FBD,
		      FEEDBACK_VIBRA_RUMBLE,
		      FbdFeedbackVibra);

G_END_DECLS
