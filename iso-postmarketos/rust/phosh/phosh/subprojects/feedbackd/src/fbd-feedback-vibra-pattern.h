/*
 * Copyright (C) 2024 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-feedback-vibra.h"

G_BEGIN_DECLS

#define FBD_TYPE_FEEDBACK_VIBRA_PATTERN (fbd_feedback_vibra_pattern_get_type())

G_DECLARE_FINAL_TYPE (FbdFeedbackVibraPattern, fbd_feedback_vibra_pattern, FBD,
		      FEEDBACK_VIBRA_PATTERN,
		      FbdFeedbackVibra);

FbdFeedbackVibraPattern *fbd_feedback_vibra_pattern_new (GArray *magnitudes, GArray *durations);

G_END_DECLS
