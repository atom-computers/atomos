/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-feedback-base.h"

G_BEGIN_DECLS

#define FBD_TYPE_FEEDBACK_DUMMY (fbd_feedback_dummy_get_type())

G_DECLARE_FINAL_TYPE (FbdFeedbackDummy, fbd_feedback_dummy, FBD, FEEDBACK_DUMMY, FbdFeedbackBase);

guint fbd_feedback_dummy_get_duration (FbdFeedbackDummy *self);

G_END_DECLS
