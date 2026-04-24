/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-event.h"
#include "fbd-feedback-base.h"
#include "fbd-feedback-manager.h"
#include "fbd-feedback-profile.h"

#include <glib-object.h>

G_BEGIN_DECLS

#define FBD_TYPE_FEEDBACK_THEME (fbd_feedback_theme_get_type())

G_DECLARE_FINAL_TYPE (FbdFeedbackTheme, fbd_feedback_theme, FBD, FEEDBACK_THEME, GObject);

FbdFeedbackTheme   *fbd_feedback_theme_new (const char *name);
FbdFeedbackTheme   *fbd_feedback_theme_new_from_data (const gchar *data, GError **error);
FbdFeedbackTheme   *fbd_feedback_theme_new_from_file (const gchar *filename, GError **error);
void                fbd_feedback_theme_update (FbdFeedbackTheme *self, FbdFeedbackTheme *from);

const char         *fbd_feedback_theme_get_name (FbdFeedbackTheme *self);
void                fbd_feedback_theme_set_name (FbdFeedbackTheme *self, const char *name);
void                fbd_feedback_theme_set_parent_name (FbdFeedbackTheme *self,
                                                        const char *parent_name);
const char         *fbd_feedback_theme_get_parent_name (FbdFeedbackTheme *self);
void                fbd_feedback_theme_add_profile (FbdFeedbackTheme *self,
						    FbdFeedbackProfile *profile);
FbdFeedbackProfile *fbd_feedback_theme_get_profile (FbdFeedbackTheme *self, const char *name);

GSList             *fbd_feedback_theme_lookup_feedback (FbdFeedbackTheme *self,
                                                        FbdFeedbackProfileLevel profile,
                                                        FbdEvent *event);

G_END_DECLS
