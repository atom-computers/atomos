/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-feedback-base.h"

G_BEGIN_DECLS

#define FBD_TYPE_FEEDBACK_VIBRA (fbd_feedback_vibra_get_type())

#define FBD_FEEDBACK_VIBRA_DEFAULT_DURATION 1000

G_DECLARE_DERIVABLE_TYPE (FbdFeedbackVibra, fbd_feedback_vibra, FBD, FEEDBACK_VIBRA, FbdFeedbackBase);

struct _FbdFeedbackVibraClass
{
  FbdFeedbackBaseClass parent_class;

  void (*start_vibra) (FbdFeedbackVibra *self);
  void (*end_vibra) (FbdFeedbackVibra *self);
};

guint fbd_feedback_vibra_get_duration (FbdFeedbackVibra *self);

G_END_DECLS
