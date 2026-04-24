/*
 * Copyright (C) 2020 Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-feedback-base"

#include "fbd-feedback-base.h"

/**
 * SECTION:fbd-feedback-base
 * @short_description: Base class for different feedback types
 * @Title: FbdFeedbackManager
 *
 * You usually don't want to create objects of this type. It just
 * serves as a base class for other feedback types.
 */

enum {
  PROP_0,
  PROP_EVENT_NAME,
  PROP_LAST_PROP,
};
static GParamSpec *props[PROP_LAST_PROP];

enum {
  SIGNAL_ENDED,
  N_SIGNALS
};
static guint signals[N_SIGNALS];

typedef struct _FbdFeedbackBasePrivate {
  gchar *event_name;
  gboolean ended;
} FbdFeedbackBasePrivate;

G_DEFINE_TYPE_WITH_PRIVATE (FbdFeedbackBase, fbd_feedback_base, G_TYPE_OBJECT);

static void
fbd_feedback_base_set_property (GObject        *object,
				guint         property_id,
				const GValue *value,
				GParamSpec   *pspec)
{
  FbdFeedbackBase *self = FBD_FEEDBACK_BASE (object);
  FbdFeedbackBasePrivate *priv = fbd_feedback_base_get_instance_private (self);

  switch (property_id) {
  case PROP_EVENT_NAME:
    g_free (priv->event_name);
    priv->event_name = g_value_dup_string (value);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
fbd_feedback_base_get_property (GObject  *object,
				guint       property_id,
				GValue     *value,
				GParamSpec *pspec)
{
  FbdFeedbackBase *self = FBD_FEEDBACK_BASE (object);
  FbdFeedbackBasePrivate *priv = fbd_feedback_base_get_instance_private (self);

  switch (property_id) {
  case PROP_EVENT_NAME:
    g_value_set_string (value, priv->event_name);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static void
fbd_feedback_base_dispose (GObject *object)
{
  FbdFeedbackBase *self = FBD_FEEDBACK_BASE (object);

  /* end feedback if running */
  if (!fbd_feedback_get_ended (self))
    fbd_feedback_end (self);

  G_OBJECT_CLASS (fbd_feedback_base_parent_class)->dispose (object);
}

static void
fbd_feedback_base_finalize (GObject *object)
{
  FbdFeedbackBase *self = FBD_FEEDBACK_BASE (object);
  FbdFeedbackBasePrivate *priv = fbd_feedback_base_get_instance_private (self);

  g_clear_pointer (&priv->event_name, g_free);

  G_OBJECT_CLASS (fbd_feedback_base_parent_class)->finalize (object);
}

static void
fbd_feedback_base_class_init (FbdFeedbackBaseClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->set_property = fbd_feedback_base_set_property;
  object_class->get_property = fbd_feedback_base_get_property;

  object_class->dispose = fbd_feedback_base_dispose;
  object_class->finalize = fbd_feedback_base_finalize;

  props[PROP_EVENT_NAME] =
    g_param_spec_string (
      "event-name",
      "Event Name",
      "The event this feedback is associated with",
      NULL,
      G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);

  /**
   * FbdFeedbackBase::ended:
   *
   * Emitted when the feedback has ended
   */
  signals[SIGNAL_ENDED] = g_signal_new ("ended",
                                        G_TYPE_FROM_CLASS (klass),
                                        G_SIGNAL_RUN_LAST, 0, NULL, NULL,
                                        NULL,
                                        G_TYPE_NONE,
                                        0);
}

static void
fbd_feedback_base_init (FbdFeedbackBase *self)
{
}

/**
 * fbd_feedback_get_event_name:
 * @self: The feedback
 *
 * Returns: the name from the event naming spec this feedback is associated with.
 */
const gchar *
fbd_feedback_get_event_name (FbdFeedbackBase *self)
{
  FbdFeedbackBasePrivate *priv;

  g_return_val_if_fail (FBD_IS_FEEDBACK_BASE (self), NULL);
  priv = fbd_feedback_base_get_instance_private (self);

  return priv->event_name;
}

/**
 * fbd_feedback_run:
 * @self: The feedback to run
 *
 * Emit the feedback.
 */
void
fbd_feedback_run (FbdFeedbackBase *self)
{
  FbdFeedbackBaseClass *klass;
  FbdFeedbackBasePrivate *priv;

  g_return_if_fail (FBD_IS_FEEDBACK_BASE (self));
  priv = fbd_feedback_base_get_instance_private (self);

  priv->ended = FALSE;
  klass = FBD_FEEDBACK_BASE_GET_CLASS (self);
  g_return_if_fail (klass->run);
  klass->run (self);
}

/**
 * fbd_feedback_end:
 * @self: The feedback to end
 *
 * End the feedback immediately.
 */
void
fbd_feedback_end (FbdFeedbackBase *self)
{
  FbdFeedbackBaseClass *klass;

  g_return_if_fail (FBD_IS_FEEDBACK_BASE (self));

  klass = FBD_FEEDBACK_BASE_GET_CLASS (self);
  g_return_if_fail (klass->end);
  klass->end (self);
}


/**
 * fbd_feedback_get_ended:
 * @self: The feedback
 *
 * Whether the feedback is ended.
 *
 * Returns: %TRUE if feedback has ended, otherwise %FALSE.
 */
gboolean
fbd_feedback_get_ended (FbdFeedbackBase *self)
{
  FbdFeedbackBasePrivate *priv = fbd_feedback_base_get_instance_private (self);

  return priv->ended;
}

/**
 * fbd_feedback_base_done:
 * @self: The feedback
 *
 * Invoked by a derived classes to notify that it's done emitting feedback,
 * e.g. when the vibra motor stopped or a sound finished playing.
 */
void
fbd_feedback_base_done (FbdFeedbackBase *self)
{
  FbdFeedbackBasePrivate *priv = fbd_feedback_base_get_instance_private (self);

  priv->ended = TRUE;
  g_signal_emit (self, signals[SIGNAL_ENDED], 0);
}

/**
 * fbd_feedback_available:
 * @self: The feedback
 *
 * Whether this feedback type is available at all. This can be %FALSE e.g.
 * due to missing hardware.
 *
 * Returns: %FALSE if the feedback type is not available at all %TRUE if unsure
 * or available.
 */
gboolean
fbd_feedback_is_available (FbdFeedbackBase *self)
{
  FbdFeedbackBaseClass *klass;

  g_return_val_if_fail (FBD_IS_FEEDBACK_BASE (self), FALSE);

  klass = FBD_FEEDBACK_BASE_GET_CLASS (self);
  if (klass->is_available)
    return klass->is_available (self);
  else
    return TRUE;
}

