/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include <fbd-feedback-base.h>

#include <glib-object.h>

G_BEGIN_DECLS

typedef enum _FbdFeedbackProfileLevel {
  FBD_FEEDBACK_PROFILE_LEVEL_UNKNOWN = -1,
  FBD_FEEDBACK_PROFILE_LEVEL_SILENT  =  0,
  FBD_FEEDBACK_PROFILE_LEVEL_QUIET,
  FBD_FEEDBACK_PROFILE_LEVEL_FULL,
  FBD_FEEDBACK_PROFILE_N_PROFILES,
} FbdFeedbackProfileLevel;

#define FBD_TYPE_FEEDBACK_PROFILE (fbd_feedback_profile_get_type())

G_DECLARE_FINAL_TYPE (FbdFeedbackProfile, fbd_feedback_profile, FBD, FEEDBACK_PROFILE, GObject);

FbdFeedbackProfile      *fbd_feedback_profile_new (const gchar *name);
void                     fbd_feedback_profile_update (FbdFeedbackProfile *self,
                                                      FbdFeedbackProfile *new);
const gchar             *fbd_feedback_profile_get_name (FbdFeedbackProfile *self);
void                     fbd_feedback_profile_add_feedback (FbdFeedbackProfile *self,
                                                            FbdFeedbackBase *feedback);
FbdFeedbackBase         *fbd_feedback_profile_get_feedback (FbdFeedbackProfile *self,
							    const char *event_name);
FbdFeedbackProfileLevel  fbd_feedback_profile_level (const char *name);
const char*              fbd_feedback_profile_level_to_string (FbdFeedbackProfileLevel level);

G_END_DECLS
