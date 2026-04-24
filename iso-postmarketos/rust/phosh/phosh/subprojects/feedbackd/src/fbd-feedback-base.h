/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include <glib-object.h>

G_BEGIN_DECLS

#define FBD_TYPE_FEEDBACK_BASE (fbd_feedback_base_get_type())

G_DECLARE_DERIVABLE_TYPE (FbdFeedbackBase, fbd_feedback_base, FBD, FEEDBACK_BASE, GObject);

struct _FbdFeedbackBaseClass
{
  GObjectClass parent_class;

  void     (*run) (FbdFeedbackBase *self);
  void     (*end) (FbdFeedbackBase *self);
  gboolean (*is_available) (FbdFeedbackBase *self);
};


const gchar *fbd_feedback_get_event_name (FbdFeedbackBase *self);
void         fbd_feedback_run (FbdFeedbackBase *self);
void         fbd_feedback_end (FbdFeedbackBase *self);
gboolean     fbd_feedback_get_ended (FbdFeedbackBase *self);
void         fbd_feedback_base_done (FbdFeedbackBase *self);
gboolean     fbd_feedback_is_available (FbdFeedbackBase *self);

G_END_DECLS
