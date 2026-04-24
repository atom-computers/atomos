/*
 * Copyright (C) 2020 Purism SPC
 *               2024-2025 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-feedback-vibra"

#include "fbd.h"
#include "fbd-enums.h"
#include "fbd-feedback-vibra.h"
#include "fbd-feedback-vibra-priv.h"
#include "fbd-feedback-manager.h"

/**
 * SECTION:fbd-feedback-vibra
 * @short_description: Describes a feedback via a haptic motor
 * @Title: FbdFeedbackVibra
 *
 * The #FbdVibraVibra describes the properties of a haptic feedback
 * event. It knows nothing about the hardware itself but calls
 * #FbdDevVibra for that.
 */

enum {
  PROP_0,
  PROP_DURATION,
  PROP_LAST_PROP,
};
static GParamSpec *props[PROP_LAST_PROP];

typedef struct _FbdFeedbackVibraPrivate {
  guint      duration;
  guint      timer_id;
  double     max_strength;

  GSettings *settings;
} FbdFeedbackVibraPrivate;

G_DEFINE_TYPE_WITH_PRIVATE (FbdFeedbackVibra, fbd_feedback_vibra, FBD_TYPE_FEEDBACK_BASE);


static void
on_max_haptic_strength_changed (FbdFeedbackVibra *self)
{
  FbdFeedbackVibraPrivate *priv = fbd_feedback_vibra_get_instance_private (self);

  priv->max_strength = g_settings_get_double (priv->settings, "max-haptic-strength");
  g_debug ("Max haptic strength: %f", priv->max_strength);
}


static void
on_timeout_expired (FbdFeedbackVibra *self)
{
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  FbdFeedbackVibraPrivate *priv = fbd_feedback_vibra_get_instance_private (self);
  FbdDevVibra *dev = fbd_feedback_manager_get_dev_vibra (manager);

  fbd_dev_vibra_stop (dev);
  priv->timer_id = 0;
  fbd_feedback_base_done (FBD_FEEDBACK_BASE (self));
}


static void
fbd_feedback_vibra_run (FbdFeedbackBase *base)
{
  FbdFeedbackVibra *self = FBD_FEEDBACK_VIBRA (base);
  FbdFeedbackVibraPrivate *priv = fbd_feedback_vibra_get_instance_private (self);
  FbdFeedbackVibraClass *klass;

  klass = FBD_FEEDBACK_VIBRA_GET_CLASS (self);
  g_return_if_fail (klass->start_vibra);
  klass->start_vibra (self);

  priv->timer_id = g_timeout_add_once (priv->duration,
                                       (GSourceOnceFunc)on_timeout_expired,
                                       self);
  g_source_set_name_by_id (priv->timer_id, "feedback-vibra-timer");
}


static void
fbd_feedback_vibra_end (FbdFeedbackBase *base)
{
  FbdFeedbackVibra *self = FBD_FEEDBACK_VIBRA (base);
  FbdFeedbackVibraPrivate *priv = fbd_feedback_vibra_get_instance_private (self);
  FbdFeedbackVibraClass *klass = FBD_FEEDBACK_VIBRA_GET_CLASS (self);

  if (!priv->timer_id)
    return;

  g_return_if_fail (klass->end_vibra);
  klass->end_vibra (self);
  g_clear_handle_id (&priv->timer_id, g_source_remove);
  fbd_feedback_base_done (FBD_FEEDBACK_BASE (self));
}


static void
fbd_feedback_vibra_set_property (GObject      *object,
                                 guint         property_id,
                                 const GValue *value,
                                 GParamSpec   *pspec)
{
  FbdFeedbackVibra *self = FBD_FEEDBACK_VIBRA (object);
  FbdFeedbackVibraPrivate *priv = fbd_feedback_vibra_get_instance_private (self);

  switch (property_id) {
  case PROP_DURATION:
    priv->duration = g_value_get_uint (value);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static void
fbd_feedback_vibra_get_property (GObject    *object,
                                 guint       property_id,
                                 GValue     *value,
                                 GParamSpec *pspec)
{
  FbdFeedbackVibra *self = FBD_FEEDBACK_VIBRA (object);
  FbdFeedbackVibraPrivate *priv = fbd_feedback_vibra_get_instance_private (self);

  switch (property_id) {
  case PROP_DURATION:
    g_value_set_uint (value, priv->duration);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
fbd_feedback_vibra_finalize (GObject *object)
{
  FbdFeedbackVibra *self = FBD_FEEDBACK_VIBRA (object);
  FbdFeedbackVibraPrivate *priv = fbd_feedback_vibra_get_instance_private (self);

  g_clear_object (&priv->settings);

  G_OBJECT_CLASS (fbd_feedback_vibra_parent_class)->finalize (object);
}


static void
fbd_feedback_vibra_class_init (FbdFeedbackVibraClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  FbdFeedbackBaseClass *base_class = FBD_FEEDBACK_BASE_CLASS (klass);

  object_class->finalize = fbd_feedback_vibra_finalize;
  object_class->set_property = fbd_feedback_vibra_set_property;
  object_class->get_property = fbd_feedback_vibra_get_property;

  base_class->run = fbd_feedback_vibra_run;
  base_class->end = fbd_feedback_vibra_end;

  /**
   * FbdFeedbackVibra:duration:
   *
   * The total duration of the feedback event in milliseconds.
   */
  props[PROP_DURATION] =
    g_param_spec_uint (
      "duration", "", "",
      0, G_MAXUINT, FBD_FEEDBACK_VIBRA_DEFAULT_DURATION,
      G_PARAM_CONSTRUCT | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);
}

static void
fbd_feedback_vibra_init (FbdFeedbackVibra *self)
{
  FbdFeedbackVibraPrivate *priv = fbd_feedback_vibra_get_instance_private (self);

  priv->settings = g_settings_new (FEEDBACKD_SCHEMA_ID);
  g_signal_connect_object (priv->settings,
                           "changed::max-haptic-strength",
                           G_CALLBACK (on_max_haptic_strength_changed),
                           self,
                           G_CONNECT_SWAPPED);
  on_max_haptic_strength_changed (self);
}

guint
fbd_feedback_vibra_get_duration (FbdFeedbackVibra *self)
{
  FbdFeedbackVibraPrivate *priv;

  g_return_val_if_fail (FBD_IS_FEEDBACK_VIBRA (self), 0);
  priv = fbd_feedback_vibra_get_instance_private (self);
  return priv->duration;
}


void
fbd_feedback_vibra_set_duration (FbdFeedbackVibra *self, guint duration)
{
  FbdFeedbackVibraPrivate *priv;

  g_return_if_fail (FBD_IS_FEEDBACK_VIBRA (self));

  priv = fbd_feedback_vibra_get_instance_private (self);

  if (duration == priv->duration)
    return;

  priv->duration = duration;
  g_object_notify_by_pspec (G_OBJECT (self), props[PROP_DURATION]);
}


double
fbd_feedback_vibra_get_max_strength (FbdFeedbackVibra *self)
{
  FbdFeedbackVibraPrivate *priv;

  g_return_val_if_fail (FBD_IS_FEEDBACK_VIBRA (self), 1.0);

  priv = fbd_feedback_vibra_get_instance_private (self);

  return priv->max_strength;
}
