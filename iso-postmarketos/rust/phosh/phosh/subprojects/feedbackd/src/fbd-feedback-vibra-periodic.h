/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-feedback-vibra.h"

G_BEGIN_DECLS

#define FBD_TYPE_FEEDBACK_VIBRA_PERIODIC (fbd_feedback_vibra_periodic_get_type())

G_DECLARE_FINAL_TYPE (FbdFeedbackVibraPeriodic, fbd_feedback_vibra_periodic, FBD,
		      FEEDBACK_VIBRA_PERIODIC,
		      FbdFeedbackVibra);

G_END_DECLS
