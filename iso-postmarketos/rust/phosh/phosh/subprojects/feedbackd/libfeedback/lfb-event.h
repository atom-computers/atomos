/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: LGPL-2.1+
 */
#pragma once

#include <gio/gio.h>
#include <glib-object.h>

#if !defined (__LIBFEEDBACK_H_INSIDE__) && !defined (LIBFEEDBACK_COMPILATION)
#error "Only <libfeedback.h> can be included directly."
#endif

G_BEGIN_DECLS

/**
 * LfbEventState:
 * @LFB_EVENT_STATE_ERRORED: An error occurred triggering feedbacks
 * @LFB_EVENT_STATE_NONE: No state information yet
 * @LFB_EVENT_STATE_RUNNING: The feedbacks for this event are currently running
 * @LFB_EVENT_STATE_ENDED: All feedbacks for this event ended
 *
 * Enum values to indicate the current state of the feedbacks
 * triggered by an event.
 */

typedef enum _LfbEventState {
  LFB_EVENT_STATE_ERRORED = -1,
  LFB_EVENT_STATE_NONE    = 0,
  LFB_EVENT_STATE_RUNNING = 1,
  LFB_EVENT_STATE_ENDED   = 2,
} LfbEventState;

/**
 * LfbEventEndReason:
 * @LFB_EVENT_END_REASON_NOT_FOUND: There was no feedback in the current theme for this event
 *                                  so no feedback was provided to the user.
 * @LFB_EVENT_END_REASON_NATURAL: All feedbacks finished playing their natural length
 * @LFB_EVENT_END_REASON_EXPIRED: Feedbacks ran until the set timeout expired
 * @LFB_EVENT_END_REASON_EXPLICIT: The feedbacks were ended explicitly
 *
 * Enum values used to indicate why the feedbacks for an event ended.
 **/
typedef enum _LfbEventEndReason {

  LFB_EVENT_END_REASON_NOT_FOUND = -1,
  LFB_EVENT_END_REASON_NATURAL   = 0,
  LFB_EVENT_END_REASON_EXPIRED   = 1,
  LFB_EVENT_END_REASON_EXPLICIT  = 2,
} LfbEventEndReason;

#define LFB_TYPE_EVENT (lfb_event_get_type())

G_DECLARE_FINAL_TYPE (LfbEvent, lfb_event, LFB, EVENT, GObject)

LfbEvent*   lfb_event_new (const char *event);
gboolean    lfb_event_trigger_feedback (LfbEvent *self, GError **error);
void        lfb_event_trigger_feedback_async (LfbEvent            *self,
                                              GCancellable        *cancellable,
                                              GAsyncReadyCallback  callback,
                                              gpointer             user_data);
gboolean    lfb_event_trigger_feedback_finish (LfbEvent            *self,
                                               GAsyncResult        *res,
                                               GError             **error);
gboolean    lfb_event_end_feedback (LfbEvent *self, GError **error);
void        lfb_event_end_feedback_async (LfbEvent            *self,
                                          GCancellable        *cancellable,
                                          GAsyncReadyCallback  callback,
                                          gpointer             user_data);
gboolean    lfb_event_end_feedback_finish (LfbEvent            *self,
                                           GAsyncResult        *res,
                                           GError             **error);
void        lfb_event_set_timeout (LfbEvent *self, gint timeout);
gint        lfb_event_get_timeout (LfbEvent *self);
void        lfb_event_set_feedback_profile (LfbEvent *self, const char *profile);
const char *lfb_event_get_feedback_profile (LfbEvent *self);
void        lfb_event_set_important (LfbEvent *self, gboolean important);
gboolean    lfb_event_get_important (LfbEvent *self);
void        lfb_event_set_app_id (LfbEvent *self, const char *app_id);
const char *lfb_event_get_app_id (LfbEvent *self);
const char *lfb_event_get_event (LfbEvent *self);
void        lfb_event_set_sound_file (LfbEvent *self, const char *sound_file);
const char *lfb_event_get_sound_file (LfbEvent *self);

LfbEventState     lfb_event_get_state (LfbEvent *self);
LfbEventEndReason lfb_event_get_end_reason (LfbEvent *self);

G_END_DECLS
