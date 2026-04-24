/*
 * Copyright (C) 2020 Purism SPC
 *               2024-2025 The Phosh Developers
 *
 * SPDX-License-Identifier: LGPL-2.1+
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#include "libfeedback.h"
#include "lfb-priv.h"

#include <gio/gio.h>

/**
 * LfbEvent:
 *
 * An event triggering feedback to the user
 *
 * #LfbEvent represents an event that should trigger
 * audio, haptic and/or visual feedback to the user by triggering
 * feedback on a feedback daemon. Valid event names are specified
 * in the
 * [Event naming specification](Event-naming-spec-0.0.0.html).
 *
 * One event can trigger multiple feedbacks at once (e.g. audio and
 * haptic feedback). This is determined by the feedback theme in
 * use (which is not under the appliction's control) and the active
 * feedback profile (see [func@Lfb.set_feedback_profile].
 *
 * After initializing the library via [func@Lfb.init] feedback can be
 * triggered like:
 *
 * ```c
 *   g_autoptr (GError) err = NULL;
 *   LfbEvent *event = lfb_event_new ("message-new-instant");
 *   lfb_event_set_timeout (event, 0);
 *   if (!lfb_event_trigger_feedback (event, &err))
 *     g_warning ("Failed to trigger feedback: %s", err->message);
 * ```
 *
 * When all feedback for this event has ended the [signal@LfbEvent::feedback-ended]
 * signal is emitted. If you want to end the feedback ahead of time use
 * [method@LfbEvent.end_feedback]:
 *
 * ```c
 *   if (!lfb_event_end_feedback (event, &err))
 *     g_warning ("Failed to end feedback: %s", err->message);
 * ```
 *
 * Since these methods involve DBus calls there are asynchronous variants
 * available, e.g. [method@LfbEvent.trigger_feedback_async]:
 *
 * ```c
 *   static void
 *   on_feedback_triggered (LfbEvent      *event,
 *                          GAsyncResult  *res,
 *                          gpointer      unused)
 *   {
 *      g_autoptr (GError) err = NULL;
 *      if (!lfb_event_trigger_feedback_finish (event, res, &err)) {
 *         g_warning ("Failed to trigger feedback for %s: %s",
 *                    lfb_event_get_event (event), err->message);
 *      }
 *   }
 *
 *   static void
 *   my_function ()
 *   {
 *     LfbEvent *event = lfb_event_new ("message-new-instant");
 *     lfb_event_trigger_feedback_async (event, NULL,
 *                                      (GAsyncReadyCallback)on_feedback_triggered,
 *                                      NULL);
 *   }
 * ```
 */

enum {
  PROP_0,
  PROP_EVENT,
  PROP_TIMEOUT,
  PROP_STATE,
  PROP_END_REASON,
  PROP_FEEDBACK_PROFILE,
  PROP_IMPORTANT,
  PROP_APP_ID,
  PROP_SOUND_FILE,
  PROP_LAST_PROP,
};
static GParamSpec *props[PROP_LAST_PROP];

enum {
      SIGNAL_FEEDBACK_ENDED,
      N_SIGNALS,
};
static guint signals[N_SIGNALS];

typedef struct _LfbEvent {
  GObject        parent;

  char          *event;
  gint           timeout;
  gchar         *profile;
  gboolean       important;
  char          *app_id;
  char          *sound_file;

  guint          id;
  LfbEventState  state;
  gint           end_reason;
  gulong         handler_id;
} LfbEvent;

G_DEFINE_TYPE (LfbEvent, lfb_event, G_TYPE_OBJECT);

typedef struct _LfbAsyncData {
  LfbEvent *event;
  GTask    *task;
} LfbAsyncData;

static void
lfb_event_set_state (LfbEvent *self, LfbEventState state)
{
  if (self->state == state)
    return;

  self->state = state;
  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_STATE]);
}

static void
lfb_event_set_end_reason (LfbEvent *self, LfbEventEndReason reason)
{
  if (self->end_reason == reason)
    return;

  self->end_reason = reason;
  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_END_REASON]);
}

static GVariant *
build_hints (LfbEvent *self)
{
  GVariantBuilder hints_builder;

  g_variant_builder_init (&hints_builder, G_VARIANT_TYPE ("a{sv}"));
  if (self->profile) {
    g_variant_builder_add (&hints_builder, "{sv}", "profile",
                           g_variant_new_string (self->profile));
  }
  if (self->important) {
    g_variant_builder_add (&hints_builder, "{sv}", "important",
                           g_variant_new_boolean (self->important));
  }
  if (self->sound_file) {
    g_variant_builder_add (&hints_builder, "{sv}", "sound-file",
                           g_variant_new_string (self->sound_file));
  }
  return g_variant_builder_end (&hints_builder);
}

static void
on_trigger_feedback_finished (LfbGdbusFeedback *proxy,
                              GAsyncResult     *res,
                              LfbAsyncData     *data)

{
  GTask *task = data->task;
  LfbEvent *self = data->event;
  g_autoptr (GError) err = NULL;
  gboolean success;

  g_return_if_fail (G_IS_TASK (task));
  g_return_if_fail (LFB_GDBUS_IS_FEEDBACK (proxy));
  g_return_if_fail (LFB_IS_EVENT (self));

  success = lfb_gdbus_feedback_call_trigger_feedback_finish (proxy,
                                                             &self->id,
                                                             res,
                                                             &err);

  lfb_event_set_state (self, success ? LFB_EVENT_STATE_RUNNING : LFB_EVENT_STATE_ERRORED);
  if (!success) {
    g_task_return_error (task, g_steal_pointer (&err));
  } else {
    g_task_return_boolean (task, TRUE);
    _lfb_active_add_id (self->id);
  }

  g_free (data);
  g_object_unref (task);
  g_object_unref (self);
}

static void
on_end_feedback_finished (LfbGdbusFeedback *proxy,
                          GAsyncResult     *res,
                          LfbAsyncData     *data)

{
  GTask *task = data->task;
  LfbEvent *self = data->event;
  g_autoptr (GError) err = NULL;
  gboolean success;

  g_return_if_fail (G_IS_TASK (task));
  g_return_if_fail (LFB_GDBUS_IS_FEEDBACK (proxy));
  g_return_if_fail (LFB_IS_EVENT (self));

  success = lfb_gdbus_feedback_call_end_feedback_finish (proxy,
                                                         res,
                                                         &err);
  if (!success) {
    g_task_return_error (task, g_steal_pointer (&err));
  } else
    g_task_return_boolean (task, TRUE);

  g_free (data);
  g_object_unref (task);
  g_object_unref (self);
}

static void
lfb_event_set_property (GObject      *object,
                        guint         property_id,
                        const GValue *value,
                        GParamSpec   *pspec)
{
  LfbEvent *self = LFB_EVENT (object);

  switch (property_id) {
  case PROP_EVENT:
    g_free (self->event);
    self->event = g_value_dup_string (value);
    g_object_notify_by_pspec (G_OBJECT (self), props[PROP_EVENT]);
    break;
  case PROP_TIMEOUT:
    lfb_event_set_timeout (self, g_value_get_int (value));
    break;
  case PROP_FEEDBACK_PROFILE:
    lfb_event_set_feedback_profile (self, g_value_get_string (value));
    break;
  case PROP_IMPORTANT:
    lfb_event_set_important (self, g_value_get_boolean (value));
    break;
  case PROP_APP_ID:
    lfb_event_set_app_id (self, g_value_get_string (value));
    break;
  case PROP_SOUND_FILE:
    lfb_event_set_sound_file (self, g_value_get_string (value));
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
lfb_event_get_property (GObject    *object,
                        guint       property_id,
                        GValue     *value,
                        GParamSpec *pspec)
{
  LfbEvent *self = LFB_EVENT (object);

  switch (property_id) {
  case PROP_EVENT:
    g_value_set_string (value, self->event);
    break;
  case PROP_TIMEOUT:
    g_value_set_int (value, self->timeout);
    break;
  case PROP_FEEDBACK_PROFILE:
    g_value_set_string (value, lfb_event_get_feedback_profile (self));
    break;
  case PROP_IMPORTANT:
    g_value_set_boolean (value, lfb_event_get_important (self));
    break;
  case PROP_APP_ID:
    g_value_set_string (value, lfb_event_get_app_id (self));
    break;
  case PROP_SOUND_FILE:
    g_value_set_string (value, lfb_event_get_sound_file (self));
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static void
lfb_event_finalize (GObject *object)
{
  LfbEvent *self = LFB_EVENT (object);

  /* Signal handler is disconnected automatically due to g_signal_connect_object */
  self->handler_id = 0;

  g_clear_pointer (&self->sound_file, g_free);
  g_clear_pointer (&self->event, g_free);
  g_clear_pointer (&self->profile, g_free);
  g_clear_pointer (&self->app_id, g_free);

  G_OBJECT_CLASS (lfb_event_parent_class)->finalize (object);
}

static void
lfb_event_class_init (LfbEventClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->set_property = lfb_event_set_property;
  object_class->get_property = lfb_event_get_property;

  object_class->finalize = lfb_event_finalize;

  /**
   * LfbEvent:event:
   *
   * The type of event from the Event naming spec, e.g. 'message-new-instant'.
   */
  props[PROP_EVENT] =
    g_param_spec_string (
      "event",
      "Event",
      "The name of the event triggering the feedback",
      NULL,
      G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  /**
   * LfbEvent:timeout:
   *
   * How long feedback should be provided in seconds. The special value
   * %-1 uses the natural length of each feedback while %0 plays each feedback
   * in a loop until ended explicitly via e.g. [method@LfbEvent.end_feedback].
   */
  props[PROP_TIMEOUT] =
    g_param_spec_int (
      "timeout",
      "Timeout",
      "When the event should timeout",
      -1, G_MAXINT, -1,
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  props[PROP_STATE] =
    g_param_spec_enum (
      "state",
      "State",
      "The event's state",
      LFB_TYPE_EVENT_STATE,
      LFB_EVENT_END_REASON_NATURAL,
      G_PARAM_READABLE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY);

  props[PROP_END_REASON] =
    g_param_spec_enum (
      "end-reason",
      "End reason",
      "The reason why the feedbacks ended",
      LFB_TYPE_EVENT_END_REASON,
      LFB_EVENT_END_REASON_NATURAL,
      G_PARAM_READABLE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY);
  /**
   * LfbEvent:feedback-profile:
   *
   * The name of the feedback profile to use for this event. See
   * [method@LfbEvent.set_feedback_profile] for details.
   */
  props[PROP_FEEDBACK_PROFILE] =
    g_param_spec_string (
      "feedback-profile",
      "Feedback profile",
      "Feedback profile to use for this event",
      NULL,
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY);
  /**
   * LfbEvent:important:
   *
   * Whether to flag this event as important.
   * [method@LfbEvent.set_important] for details.
   */
  props[PROP_IMPORTANT] =
    g_param_spec_boolean (
      "important",
      "Important",
      "Whether to flags this event as important",
      FALSE,
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY);
  /**
   * LfbEvent:app-id:
   *
   * The application id to use for the event.
   * [method@LfbEvent.set_feedback_profile] for details.
   */
  props[PROP_APP_ID] =
    g_param_spec_string (
      "app-id",
      "Application Id",
      "The Application id to use for this event",
      NULL,
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY);
  /**
   * LfbEvent:sound-file:
   *
   * A custom sound-file to play. See [method@LfbEvent.set_sound_file]
   * for details.
   */
  props[PROP_SOUND_FILE] =
    g_param_spec_string (
      "sound-file",
      "Sound file",
      "Custom sound file to play",
      NULL,
      G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS | G_PARAM_EXPLICIT_NOTIFY);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);

  /**
   * LfbEvent::feedback-ended:
   *
   * Emitted when all feedbacks triggered by the event have ended.
   */
  signals[SIGNAL_FEEDBACK_ENDED] = g_signal_new ("feedback-ended",
                                                 G_TYPE_FROM_CLASS (klass),
                                                 G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                                                 NULL,
                                                 G_TYPE_NONE,
                                                 0);
}

static void
lfb_event_init (LfbEvent *self)
{
  self->timeout = -1;
  self->state = LFB_EVENT_STATE_NONE;
  self->end_reason = LFB_EVENT_END_REASON_NATURAL;
}

/**
 * lfb_event_new:
 * @event: The event's name.
 *
 * Creates a new [class@Lfb.Event] based on the given event
 * name. See [property@Lfb.Event:event] for details.
 *
 * Returns: The [class@Lfb.Event].
 */
LfbEvent *
lfb_event_new (const char *event)
{
  return g_object_new (LFB_TYPE_EVENT, "event", event, NULL);
}

static void
on_feedback_ended (LfbEvent         *self,
                   guint             event_id,
                   guint             reason,
                   LfbGdbusFeedback *proxy)
{
  g_return_if_fail (LFB_IS_EVENT (self));
  g_return_if_fail (LFB_GDBUS_IS_FEEDBACK (proxy));

  if (event_id != self->id)
    return;

  lfb_event_set_end_reason (self, reason);
  lfb_event_set_state (self, LFB_EVENT_STATE_ENDED);
  g_signal_emit (self, signals[SIGNAL_FEEDBACK_ENDED], 0);
  _lfb_active_remove_id (self->id);
  self->id = 0;
  g_signal_handler_disconnect (proxy, self->handler_id);
  self->handler_id = 0;
}

/**
 * lfb_event_trigger_feedback:
 * @self: The event to trigger feedback for.
 * @error: The returned error information.
 *
 * Tells the feedback server to provide proper feedback for the give
 * event to the user.
 *
 * Returns: %TRUE if successful. On error, this will return %FALSE and set
 *          @error.
 */
gboolean
lfb_event_trigger_feedback (LfbEvent *self, GError **error)
{
  LfbGdbusFeedback *proxy;
  gboolean success;
  const char *app_id;

  g_return_val_if_fail (LFB_IS_EVENT (self), FALSE);
  g_return_val_if_fail (error == NULL || *error == NULL, FALSE);

   if (!lfb_is_initted ())
     g_error ("You must call lfb_init() before triggering events.");

   proxy = _lfb_get_proxy ();
   g_return_val_if_fail (G_IS_DBUS_PROXY (proxy), FALSE);

   if (self->handler_id == 0) {
     self->handler_id = g_signal_connect_object (proxy,
                                                 "feedback-ended",
                                                 G_CALLBACK (on_feedback_ended),
                                                 self,
                                                 G_CONNECT_SWAPPED);
   }

   app_id = self->app_id ?: lfb_get_app_id ();
   success =  lfb_gdbus_feedback_call_trigger_feedback_sync (proxy,
                                                             app_id,
                                                             self->event,
                                                             build_hints (self),
                                                             self->timeout,
                                                             &self->id,
                                                             NULL,
                                                             error);
   if (success)
     _lfb_active_add_id (self->id);
   lfb_event_set_state (self, success ? LFB_EVENT_STATE_RUNNING : LFB_EVENT_STATE_ERRORED);
   return success;
}

/**
 * lfb_event_trigger_feedback_async:
 * @self: The event to trigger feedback for.
 * @cancellable: (nullable): A #GCancellable to cancel the operation or %NULL.
 * @callback: A #GAsyncReadyCallback to call when the request is satisfied or %NULL.
 * @user_data: User data to pass to @callback.
 *
 * Tells the feedback server to provide proper feedback for the give
 * event to the user. This is the sync version of
 * [method@LfbEvent.trigger_feedback].
 */
void
lfb_event_trigger_feedback_async (LfbEvent            *self,
                                  GCancellable        *cancellable,
                                  GAsyncReadyCallback  callback,
                                  gpointer             user_data)
{
  LfbAsyncData *data;
  LfbGdbusFeedback *proxy;
  const char *app_id;

  g_return_if_fail (LFB_IS_EVENT (self));
  if (!lfb_is_initted ())
     g_error ("You must call lfb_init() before triggering events.");

  proxy = _lfb_get_proxy ();
  g_return_if_fail (LFB_GDBUS_IS_FEEDBACK (proxy));

  if (self->handler_id == 0) {
    self->handler_id = g_signal_connect_object (proxy,
                                                "feedback-ended",
                                                G_CALLBACK (on_feedback_ended),
                                                self,
                                                G_CONNECT_SWAPPED);
  }

  data = g_new0 (LfbAsyncData, 1);
  data->task = g_task_new (self, cancellable, callback, user_data);
  data->event = g_object_ref (self);

  app_id = self->app_id ?: lfb_get_app_id ();
  lfb_gdbus_feedback_call_trigger_feedback (proxy,
                                            app_id,
                                            self->event,
                                            build_hints (self),
                                            self->timeout,
                                            cancellable,
                                            (GAsyncReadyCallback)on_trigger_feedback_finished,
                                            data);
}

/**
 * lfb_event_trigger_feedback_finish:
 * @self: the event
 * @res: Result object passed to the callback of [method@LfbEvent.trigger_feedback_async]
 * @error: Return location for error
 *
 * Finish an async operation started by [method@LfbEvent.trigger_feedback_async]. You
 * must call this function in the callback to free memory and receive any
 * errors which occurred.
 *
 * Returns: %TRUE if triggering the feedbacks was successful
 */
gboolean
lfb_event_trigger_feedback_finish (LfbEvent      *self,
                                   GAsyncResult  *res,
                                   GError       **error)
{
  g_return_val_if_fail (g_task_is_valid (res, self), FALSE);

  return g_task_propagate_boolean (G_TASK (res), error);
}

/**
 * lfb_event_end_feedback:
 * @self: The event to end feedback for.
 * @error: The returned error information.
 *
 * Tells the feedback server to end all feedback for the given event as
 * soon as possible.
 *
 * Returns: %TRUE if successful. On error, this will return %FALSE and set
 *          @error.
 */
gboolean
lfb_event_end_feedback (LfbEvent *self, GError **error)
{
  LfbGdbusFeedback *proxy;

  g_return_val_if_fail (LFB_IS_EVENT (self), FALSE);
  g_return_val_if_fail (error == NULL || *error == NULL, FALSE);

  if (!lfb_is_initted ())
     g_error ("You must call lfb_init() before ending events.");

  proxy = _lfb_get_proxy ();
  g_return_val_if_fail (LFB_GDBUS_IS_FEEDBACK (proxy), FALSE);
  return lfb_gdbus_feedback_call_end_feedback_sync (proxy, self->id, NULL, error);
}

/**
 * lfb_event_end_feedback_finish:
 * @self: the event
 * @res: Result object passed to the callback of [method@LfbEvent.end_feedback_async]
 * @error: Return location for error
 *
 * Finish an async operation started by lfb_event_end_feedback_async. You
 * must call this function in the callback to free memory and receive any
 * errors which occurred.
 *
 * This does not mean that the feedbacks finished right away. Connect to the
 * [@signal@LfbEvent::feedback-ended] signal for this.
 *
 * Returns: %TRUE if ending the feedbacks was successful
 */
gboolean
lfb_event_end_feedback_finish (LfbEvent      *self,
                               GAsyncResult  *res,
                               GError       **error)
{
  g_return_val_if_fail (g_task_is_valid (res, self), FALSE);

  return g_task_propagate_boolean (G_TASK (res), error);
}

/**
 * lfb_event_end_feedback_async:
 * @self: The event to end feedback for.
 * @cancellable: (nullable): A #GCancellable to cancel the operation or %NULL.
 * @callback: A #GAsyncReadyCallback to call when the request is satisfied or %NULL.
 * @user_data: User data to pass to @callback.
 *
 * Tells the feedback server to end all feedback for the given event as
 * soon as possible.
 */
void
lfb_event_end_feedback_async (LfbEvent            *self,
                              GCancellable        *cancellable,
                              GAsyncReadyCallback  callback,
                              gpointer             user_data)
{
  LfbAsyncData *data;
  LfbGdbusFeedback *proxy;

  g_return_if_fail (LFB_IS_EVENT (self));
  if (!lfb_is_initted ())
     g_error ("You must call lfb_init() before ending events.");

  proxy = _lfb_get_proxy ();
  g_return_if_fail (LFB_GDBUS_IS_FEEDBACK (proxy));

  data = g_new0 (LfbAsyncData, 1);
  data->task = g_task_new (self, cancellable, callback, user_data);
  data->event = g_object_ref (self);
  lfb_gdbus_feedback_call_end_feedback (proxy,
                                        self->id,
                                        cancellable,
                                        (GAsyncReadyCallback)on_end_feedback_finished,
                                        data);
}

/**
 * lfb_event_set_timeout:
 * @self: The event
 * @timeout: The timeout
 *
 * Tells the feedback server to end feedback after #timeout seconds.
 * The value -1 indicates to not set a timeout and let feedbacks stop
 * on their own while 0 indicates to loop all feedbacks endlessly.
 * They must be stopped via [method@LfbEvent.end_feedback] in this case.
 *
 * It is an error to change the timeout after the feedback has been triggered
 * via [method@LfbEvent.trigger_feedback].
 */
void
lfb_event_set_timeout (LfbEvent *self, gint timeout)
{
  g_return_if_fail (LFB_IS_EVENT (self));

  if (self->timeout == timeout)
    return;

  self->timeout = timeout;
  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_TIMEOUT]);
}

/**
 * lfb_event_get_event:
 * @self: The event
 *
 * Get the event's name according to the event naming spec.
 *
 * Returns: The event name
 */
const char *
lfb_event_get_event (LfbEvent *self)
{
  g_return_val_if_fail (LFB_IS_EVENT (self), NULL);
  return self->event;
}

/**
 * lfb_event_get_timeout:
 * @self: The event
 *
 * Get the currently set timeout.
 *
 * Returns: The event timeout in milliseconds
 */
gint
lfb_event_get_timeout (LfbEvent *self)
{
  g_return_val_if_fail (LFB_IS_EVENT (self), -1);
  return self->timeout;
}

/**
 * lfb_event_get_state:
 * @self: The event
 *
 * Get the current event state (e.g. if triggered feeedback is
 * currently running.
 *
 * Returns: The state of the feedback triggered by event.
 */
LfbEventState
lfb_event_get_state (LfbEvent *self)
{
  g_return_val_if_fail (LFB_IS_EVENT (self), LFB_EVENT_STATE_NONE);
  return self->state;
}

/**
 * lfb_event_get_end_reason:
 * @self: The event
 *
 * Get the reason why the feadback ended.
 *
 * Returns: The reason why feedback ended.
 */
LfbEventEndReason
lfb_event_get_end_reason (LfbEvent *self)
{
  g_return_val_if_fail (LFB_IS_EVENT (self), LFB_EVENT_END_REASON_NATURAL);
  return self->end_reason;
}

/**
 * lfb_event_set_feedback_profile:
 * @self: The event
 * @profile: The feedback profile to use
 *
 * Tells the feedback server to use the given feedback profile for
 * this event when it is submitted. The server might ignore this
 * request.  Valid profile names and their 'noisiness' are specified
 * in the [Feedback theme specification](Feedback-theme-spec-0.0.0.html).
 *
 * A value of %NULL (the default) lets the server pick the profile.
 */
void
lfb_event_set_feedback_profile (LfbEvent *self, const gchar *profile)
{
  g_return_if_fail (LFB_IS_EVENT (self));

  if (!g_strcmp0 (self->profile, profile))
    return;

  g_free (self->profile);
  self->profile = g_strdup (profile);
  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_FEEDBACK_PROFILE]);
}

/**
 * lfb_event_get_feedback_profile:
 * @self: The event
 *
 * Gets the set feedback profile. If no profile was set it returns
 * %NULL. The event uses the system wide profile in this case.
 *
 * Returns: The set feedback profile to use for this event or %NULL.
 */
const char *
lfb_event_get_feedback_profile (LfbEvent *self)
{
  g_return_val_if_fail (LFB_IS_EVENT (self), NULL);

  return self->profile;
}

/**
 * lfb_event_set_important:
 * @self: The event
 * @important: Whether to flag this event as important
 *
 * Tells the feedback server that the sender deems this to be an
 * important event. A feedback server might allow the sender to
 * override the current global feedback level when this is set.
 */
void
lfb_event_set_important (LfbEvent *self, gboolean important)
{
  g_return_if_fail (LFB_IS_EVENT (self));

  if (self->important == important)
    return;

  self->important = important;
  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_IMPORTANT]);
}

/**
 * lfb_event_get_important:
 * @self: The event
 *
 * Gets the set feedback profile. If no profile was set it returns
 * %NULL. The event uses the system wide profile in this case.
 *
 * Returns: The set feedback profile to use for this event or %NULL.
 */
gboolean
lfb_event_get_important (LfbEvent *self)
{
  g_return_val_if_fail (LFB_IS_EVENT (self), FALSE);

  return self->important;
}

/**
 * lfb_event_set_app_id:
 * @self: The event
 * @app_id: The application id to use
 *
 * Tells the feedback server to use the given application id for
 * this event when it is submitted. The server might ignore this
 * request. This can be used by notification daemons to honor per
 * application settings automatically.
 *
 * The functions is usually not used by applications.
 *
 * A value of %NULL (the default) lets the server pick the profile.
 */
void
lfb_event_set_app_id (LfbEvent *self, const gchar *app_id)
{
  g_return_if_fail (LFB_IS_EVENT (self));

  if (!g_strcmp0 (self->app_id, app_id))
    return;

  g_free (self->app_id);
  self->app_id = g_strdup (app_id);
  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_APP_ID]);
}

/**
 * lfb_event_get_app_id:
 * @self: The event
 *
 * Returns the app-id for this event. If no app-id has been explicitly
 * set, %NULL is returned. The event uses the app-id returned by
 * [func@Lfb.get_app_id] in this case.
 *
 * Returns:(transfer none): The set app-id for this event or %NULL.
 */
const char *
lfb_event_get_app_id (LfbEvent *self)
{
  g_return_val_if_fail (LFB_IS_EVENT (self), NULL);

  return self->app_id;
}

/**
 * lfb_event_set_sound_file:
 * @self: The event
 * @sound_file: The sound file
 *
 * Tells the feedback server to use the given sound file if a sound is
 * to be played. It will only be used if sound is suitable for the
 * events feedback level.
 *
 * A value of %NULL (the default) lets the server pick the sound
 * based on the event.
 */
void
lfb_event_set_sound_file (LfbEvent *self, const gchar *sound_file)
{
  g_return_if_fail (LFB_IS_EVENT (self));

  if (!g_strcmp0 (self->sound_file, sound_file))
    return;

  g_free (self->sound_file);
  self->sound_file = g_strdup (sound_file);
  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_SOUND_FILE]);
}

/**
 * lfb_event_get_sound_file:
 * @self: The event
 *
 * Returns the sound file for this event if set.
 *
 * Returns:(transfer none): The set sound file for this event or %NULL.
 */
const char *
lfb_event_get_sound_file (LfbEvent *self)
{
  g_return_val_if_fail (LFB_IS_EVENT (self), NULL);

  return self->sound_file;
}
