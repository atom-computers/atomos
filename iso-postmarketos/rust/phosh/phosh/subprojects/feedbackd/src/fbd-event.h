/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-feedback-base.h"
#include "fbd-feedback-manager.h"

#include <glib-object.h>

G_BEGIN_DECLS

typedef enum _FbdEventEndReason {
  /* No usable feedback in current theme for this event */
  FBD_EVENT_END_REASON_NOT_FOUND = -1,
  /* all feedbacks finished playing their natural length */
  FBD_EVENT_END_REASON_NATURAL   = 0,
  /* The timer expired */
  FBD_EVENT_END_REASON_EXPIRED   = 1,
  /* Application wanted to end feedbacks explicitly */
  FBD_EVENT_END_REASON_EXPLICIT  = 2,
} FbdEventEndReason;

typedef enum _FbdEventTimeout {
  /* Run each feedback once */
  FBD_EVENT_TIMEOUT_ONESHOT  = -1,
  FBD_EVENT_TIMEOUT_LOOP     =  0,
} FbdEventTimeout;

#define FBD_TYPE_EVENT (fbd_event_get_type())

G_DECLARE_FINAL_TYPE (FbdEvent, fbd_event, FBD, EVENT, GObject);

FbdEvent    *fbd_event_new (gint id, const char *app_id, const char *event, int timeout, const char *sender);
const char  *fbd_event_get_event (FbdEvent *event);
const char  *fbd_event_get_app_id (FbdEvent *event);
guint        fbd_event_get_id (FbdEvent *event);
int          fbd_event_get_timeout (FbdEvent *self);
void         fbd_event_set_end_reason (FbdEvent *self, FbdEventEndReason reason);
FbdEventEndReason fbd_event_get_end_reason (FbdEvent *self);
GSList *     fbd_event_get_feedbacks (FbdEvent *self);
void         fbd_event_add_feedback (FbdEvent *self,
                                     FbdFeedbackBase *feedback);
int          fbd_event_remove_feedback (FbdEvent *self,
                                        FbdFeedbackBase *feedback);
void         fbd_event_run_feedbacks (FbdEvent *self);
void         fbd_event_end_feedbacks (FbdEvent *self);
void         fbd_event_end_feedbacks_by_level (FbdEvent *self, guint level);
gboolean     fbd_event_get_feedbacks_ended (FbdEvent *self);
const char  *fbd_event_get_sender (FbdEvent *self);

G_END_DECLS
