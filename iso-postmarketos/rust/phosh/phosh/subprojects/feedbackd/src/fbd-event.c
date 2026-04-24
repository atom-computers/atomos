/*
 * Copyright (C) 2020 Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-event"

#include "lfb-names.h"
#include "fbd.h"
#include "fbd-enums.h"
#include "fbd-event.h"

enum {
  SIGNAL_FEEDBACKS_ENDED,
  N_SIGNALS
};
static guint signals[N_SIGNALS];

enum {
  PROP_0,
  PROP_ID,
  PROP_APP_ID,
  PROP_EVENT,
  PROP_END_REASON,
  PROP_FEEDBACKS_ENDED,
  PROP_TIMEOUT,
  PROP_SENDER,
  PROP_LAST_PROP,
};
static GParamSpec *props[PROP_LAST_PROP];

typedef struct _FbdEvent {
  GObject parent;

  guint id;
  char *app_id;
  char *event;
  char *sender;

  int  timeout;
  gboolean expired;
  guint timeout_id;

  gboolean ended;
  FbdEventEndReason end_reason;

  GSList *feedbacks;
} FbdEvent;

G_DEFINE_TYPE (FbdEvent, fbd_event, G_TYPE_OBJECT);

static gboolean
on_timeout_expired (FbdEvent *self)
{
  g_return_val_if_fail (FBD_IS_EVENT (self), G_SOURCE_REMOVE);

  self->expired = TRUE;
  self->timeout_id = 0;
  return G_SOURCE_REMOVE;
}

static gboolean
check_ended (FbdEvent *self)
{
  if (!fbd_event_get_feedbacks_ended (self))
    return FALSE;

  self->ended = TRUE;
  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_FEEDBACKS_ENDED]);
  g_signal_emit (self, signals[SIGNAL_FEEDBACKS_ENDED], 0);
  return TRUE;
}

static void
on_fb_ended (FbdEvent *self, FbdFeedbackBase *fb)
{
  switch (self->timeout) {
  case FBD_EVENT_TIMEOUT_ONESHOT:
    check_ended (self);
    break;
  case FBD_EVENT_TIMEOUT_LOOP:
    if (self->end_reason != FBD_EVENT_END_REASON_NATURAL)
      check_ended (self);
    else
      fbd_feedback_run (fb);
    break;
  default:
    if (!self->expired && self->end_reason == FBD_EVENT_END_REASON_NATURAL)
      fbd_feedback_run (fb);
    else
      check_ended (self);
    break;
  }
}

static void
fbd_event_set_property (GObject      *object,
                        guint         property_id,
                        const GValue *value,
                        GParamSpec   *pspec)
{
  FbdEvent *self = FBD_EVENT (object);

  switch (property_id) {
  case PROP_ID:
    self->id = g_value_get_int (value);
    break;
  case PROP_APP_ID:
    g_free (self->app_id);
    self->app_id = g_value_dup_string (value);
    break;
  case PROP_EVENT:
    g_free (self->event);
    self->event = g_value_dup_string (value);
    break;
  case PROP_TIMEOUT:
    self->timeout = g_value_get_int (value);
    break;
  case PROP_END_REASON:
    fbd_event_set_end_reason (self, g_value_get_enum (value));
    break;
  case PROP_SENDER:
    g_free (self->sender);
    self->sender = g_value_dup_string (value);
    break;
  case PROP_FEEDBACKS_ENDED:
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static void
fbd_event_get_property (GObject    *object,
                        guint       property_id,
                        GValue     *value,
                        GParamSpec *pspec)
{
  FbdEvent *self = FBD_EVENT (object);

  switch (property_id) {
  case PROP_ID:
    g_value_set_int (value, self->id);
    break;
  case PROP_APP_ID:
    g_value_set_string (value, self->app_id);
    break;
  case PROP_EVENT:
    g_value_set_string (value, self->event);
    break;
  case PROP_TIMEOUT:
    g_value_set_int (value, self->timeout);
    break;
  case PROP_END_REASON:
    g_value_set_enum (value, fbd_event_get_end_reason (self));
    break;
  case PROP_FEEDBACKS_ENDED:
    g_value_set_boolean (value, self->ended);
    break;
  case PROP_SENDER:
    g_value_set_string (value, self->sender);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static void
fbd_event_dispose (GObject *object)
{
  FbdEvent *self = FBD_EVENT (object);

  g_clear_handle_id (&self->timeout_id, g_source_remove);

  if (self->feedbacks) {
    /* Feedbacks end themselves when unrefed */
    g_slist_free_full (self->feedbacks, g_object_unref);
    self->feedbacks = NULL;
  }

  G_OBJECT_CLASS (fbd_event_parent_class)->dispose (object);
}

static void
fbd_event_finalize (GObject *object)
{
  FbdEvent *self = FBD_EVENT (object);

  g_clear_pointer (&self->app_id, g_free);
  g_clear_pointer (&self->event, g_free);
  g_clear_pointer (&self->sender, g_free);

  G_OBJECT_CLASS (fbd_event_parent_class)->finalize (object);
}

static void
fbd_event_class_init (FbdEventClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->set_property = fbd_event_set_property;
  object_class->get_property = fbd_event_get_property;

  object_class->dispose = fbd_event_dispose;
  object_class->finalize = fbd_event_finalize;

  props[PROP_ID] =
    g_param_spec_int (
      "id",
      "Id",
      "The event id",
      0, G_MAXINT, 0,
      G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  props[PROP_APP_ID] =
    g_param_spec_string (
      "app-id",
      "App id",
      "The application id",
      NULL,
      G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  props[PROP_EVENT] =
    g_param_spec_string (
      "event",
      "Event",
      "The event name",
      NULL,
      G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  props[PROP_TIMEOUT] =
    g_param_spec_int (
      "timeout",
      "Timeout",
      "Timeout after which feedback for event should end",
      -1, G_MAXINT, -1,
      G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  props[PROP_FEEDBACKS_ENDED] =
    g_param_spec_boolean (
      "feedbacks-ended",
      "Feedbacks ended",
      "Whether all feedbacks have ended playing",
      FALSE,
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY);

  props[PROP_END_REASON] =
    g_param_spec_enum (
      "end-reason",
      "End reason",
      "The reason why the feedbacks ends/ended",
      FBD_TYPE_EVENT_END_REASON,
      FBD_EVENT_END_REASON_NATURAL,
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY);

  /**
   * FbdEvent:Sender:
   *
   * The DBus name of the sender
   */
  props[PROP_SENDER] =
    g_param_spec_string (
      "sender",
      "",
      "",
      NULL,
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);

  /**
   * FbdEvent::feedbacks-ended:
   *
   * Emitted when all feedbacks associated with this event ended.
   */
  signals[SIGNAL_FEEDBACKS_ENDED] = g_signal_new ("feedbacks-ended",
                                                  G_TYPE_FROM_CLASS (klass),
                                                  G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                                                  NULL,
                                                  G_TYPE_NONE,
                                                  0);
}

static void
fbd_event_init (FbdEvent *self)
{
  self->timeout = -1;
}

FbdEvent *
fbd_event_new (int id, const char *app_id, const char *event, int timeout, const char *sender)
{
  return FBD_EVENT (g_object_new (FBD_TYPE_EVENT,
                                  "id", id,
                                  "app_id", app_id,
                                  "event", event,
                                  "timeout", timeout,
                                  "sender", sender,
                                  NULL));
}

const char *
fbd_event_get_event (FbdEvent *self)
{
  g_return_val_if_fail (FBD_IS_EVENT (self), NULL);

  return self->event;
}

const char *
fbd_event_get_app_id (FbdEvent *self)
{
  g_return_val_if_fail (FBD_IS_EVENT (self), NULL);

  return self->app_id;
}

guint
fbd_event_get_id (FbdEvent *self)
{
  g_return_val_if_fail (FBD_IS_EVENT (self), 0);

  return self->id;
}

int
fbd_event_get_timeout (FbdEvent *self)
{
  g_return_val_if_fail (FBD_IS_EVENT (self), -1);

  return self->timeout;
}

/**
 * fbd_event_add_feedback:
 * @self: The event that gets a feedback added
 * @feedback: (transfer-none): The feedback to add
 *
 * Add a feedback to the list of feedbacks triggered by event
 */
void
fbd_event_add_feedback (FbdEvent *self, FbdFeedbackBase *feedback)
{
  self->feedbacks = g_slist_prepend (self->feedbacks, g_object_ref (feedback));
  g_object_set_data (G_OBJECT (feedback), "event-id", GUINT_TO_POINTER (self->id));
  g_signal_connect_object (feedback,
                           "ended",
                           (GCallback) on_fb_ended,
                           self,
                           G_CONNECT_SWAPPED);
}

GSList *
fbd_event_get_feedbacks (FbdEvent *self)
{
  return self->feedbacks;
}

int
fbd_event_remove_feedback (FbdEvent *self, FbdFeedbackBase *feedback)
{
  guint len;

  g_return_val_if_fail (FBD_IS_EVENT (self), 0);

  if (!self->feedbacks)
    return 0;

  if (g_slist_index (self->feedbacks, feedback) >= 0) {
    g_signal_handlers_disconnect_by_data (feedback, self);
    /* Drop our reference, feedbacks end themselves when unref'ed */
    g_object_unref (feedback);
  }

  self->feedbacks = g_slist_remove (self->feedbacks, feedback);

  len = g_slist_length (self->feedbacks);
  if (!len)
    check_ended (self);

  return len;
}

/**
 * fbd_event_run_feedbacks:
 * @self: The Event
 *
 * Run all feedbacks associated for an event.
 */
void
fbd_event_run_feedbacks (FbdEvent *self)
{
  g_return_if_fail (FBD_IS_EVENT (self));

  g_debug ("Running %d feedbacks for event %d", g_slist_length (self->feedbacks), self->id);

  if (!self->feedbacks)
    return;

  if (self->timeout > 0) {
    self->timeout_id = g_timeout_add_seconds (self->timeout,
                                              (GSourceFunc)on_timeout_expired,
                                              self);
    g_source_set_name_by_id (self->timeout_id, "event timeout source");
  }

  g_object_ref (self);
  for (GSList *l = self->feedbacks; l; l = l->next) {
    FbdFeedbackBase *fb = FBD_FEEDBACK_BASE (l->data);
    fbd_feedback_run (fb);
  }
  g_object_unref (self);
}

/**
 * fbd_event_end_feedbacks:
 * @self: The Event
 *
 * End all running feedbacks as early as possible.
 */
void
fbd_event_end_feedbacks (FbdEvent *self)
{
  g_return_if_fail (FBD_IS_EVENT (self));

  fbd_event_set_end_reason (self, FBD_EVENT_END_REASON_EXPLICIT);
  g_debug ("Ending %d feedbacks for event %d", g_slist_length (self->feedbacks), self->id);
  g_slist_foreach (self->feedbacks, (GFunc)fbd_feedback_end, NULL);
}

/**
 * fbd_event_end_feedbacks_by_level:
 * @self: The Event
 * @level: The profile level
 *
 * End all feedback strictly above the given profile level.
 */
void
fbd_event_end_feedbacks_by_level (FbdEvent *self, guint level)
{
  g_autoptr (GSList) feedbacks = NULL;
  guint num = 0;

  g_return_if_fail (FBD_IS_EVENT (self));
  /* Copy the list as we will remove feedbacks from self->feedbacks */
  feedbacks = g_slist_copy (fbd_event_get_feedbacks (self));

  for (GSList *l = feedbacks; l; l = l->next) {
    FbdFeedbackBase *fb = FBD_FEEDBACK_BASE (l->data);
    guint event_level;

    event_level = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (fb), "fbd-level"));
    if (event_level > level)
      num++;
  }

  if (num == 0)
    return;

  g_debug ("Will end %d feedbacks of event %s", num, fbd_event_get_event (self));
  /* Set 'explicit' if we end all remaining feedbacks */
  if (num == g_slist_length (self->feedbacks))
      fbd_event_set_end_reason (self, FBD_EVENT_END_REASON_EXPLICIT);

  for (GSList *l = feedbacks; l; l = l->next) {
    FbdFeedbackBase *fb = FBD_FEEDBACK_BASE (l->data);
    guint event_level;

    event_level = GPOINTER_TO_UINT (g_object_get_data (G_OBJECT (fb), "fbd-level"));
    if (event_level > level) {
      fbd_event_remove_feedback (self, fb);
      fbd_feedback_end (fb);
    }
  }
}

/**
 * fbd_event_get_feedbacks_ended:
 * @self: The Event
 *
 * Whether all feedbacks have finished running.
 *
 * Returns: %TRUE if all feedbacks have finished, otherwise %FALSE.
 */
gboolean
fbd_event_get_feedbacks_ended (FbdEvent *self)
{
  GSList *l;

  g_return_val_if_fail (FBD_IS_EVENT (self), FALSE);

  if (!self->feedbacks)
    return TRUE;

  for (l = self->feedbacks; l ; l = l->next) {
    if (!fbd_feedback_get_ended (FBD_FEEDBACK_BASE (l->data)))
      return FALSE;
  }

  return TRUE;
}

/**
 * fbd_event_set_end_reason:
 * @self: The Event
 * @reason: The reason why feedback for the event ended
 *
 * Sets the reason why feedback for the event ends/has ended.
 */
void
fbd_event_set_end_reason (FbdEvent *self, FbdEventEndReason reason)
{
  g_return_if_fail (FBD_IS_EVENT (self));

  if (self->end_reason == reason)
    return;
  self->end_reason = reason;
  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_END_REASON]);
}

/**
 * fbd_event_get_end_reason:
 * @self: The Event
 *
 * Returns: The reason why feedback for the event ended.
 */
FbdEventEndReason
fbd_event_get_end_reason (FbdEvent *self)
{
  g_return_val_if_fail (FBD_IS_EVENT (self), FBD_EVENT_END_REASON_NATURAL);

  return self->end_reason;
}

/**
 * fbd_event_get_sender:
 * @self: The Event
 *
 * Returns: The DBus sender that triggered the event.
 */
const char *
fbd_event_get_sender (FbdEvent *self)
{
  g_return_val_if_fail (FBD_IS_EVENT (self), NULL);

  return self->sender;
}
