/*
 * Copyright (C) 2020 Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-feedback-vibra-rumble"

#include "fbd-enums.h"
#include "fbd-feedback-vibra-priv.h"
#include "fbd-feedback-vibra-rumble.h"
#include "fbd-feedback-manager.h"

/**
 * SECTION:fbd-feedback-vibra
 * @short_description: Describes a rumble feedback via a haptic motor
 * @Title: FbdFeedbackVibraRumble
 *
 * The #FbdVibraVibraRumble describes the properties of a haptic feedback
 * event. It knows nothing about the hardware itself but calls
 * #FbdDevVibra for that.
 *
 * TODO: could be dropped in favor of the more flexible `FbdFeedbackVibraPattern`.
 */

enum {
  PROP_0,
  PROP_COUNT,
  PROP_PAUSE,
  PROP_MAGNITUDE,
  PROP_LAST_PROP,
};
static GParamSpec *props[PROP_LAST_PROP];

typedef struct _FbdFeedbackVibraRumble {
  FbdFeedbackVibra parent;

  guint            count;     /* number of rumbles */
  guint            pause;     /* pause in msecs */

  double           magnitude; /* magnitude [0.0, 1.0] */
  guint            rumble;    /* rumble in msecs */
  guint            periods;   /* number of periods to play */
  guint            timer_id;
} FbdFeedbackVibraRumble;

G_DEFINE_TYPE (FbdFeedbackVibraRumble, fbd_feedback_vibra_rumble, FBD_TYPE_FEEDBACK_VIBRA);

static void
fbd_feedback_vibra_rumble_set_property (GObject      *object,
                                        guint         property_id,
                                        const GValue *value,
                                        GParamSpec   *pspec)
{
  FbdFeedbackVibraRumble *self = FBD_FEEDBACK_VIBRA_RUMBLE (object);

  switch (property_id) {
  case PROP_COUNT:
    self->count = g_value_get_uint (value);
    break;
  case PROP_PAUSE:
    self->pause = g_value_get_uint (value);
    break;
  case PROP_MAGNITUDE:
    self->magnitude = g_value_get_double (value);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static void
fbd_feedback_vibra_rumble_get_property (GObject    *object,
                                        guint       property_id,
                                        GValue     *value,
                                        GParamSpec *pspec)
{
  FbdFeedbackVibraRumble *self = FBD_FEEDBACK_VIBRA_RUMBLE (object);

  switch (property_id) {
  case PROP_COUNT:
    g_value_set_uint (value, self->count);
    break;
  case PROP_PAUSE:
    g_value_set_uint (value, self->pause);
    break;
  case PROP_MAGNITUDE:
    g_value_set_double (value, self->magnitude);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static gboolean
on_period_ended (FbdFeedbackVibraRumble *self)
{
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  FbdDevVibra *dev = fbd_feedback_manager_get_dev_vibra (manager);

  g_return_val_if_fail (FBD_IS_FEEDBACK_VIBRA_RUMBLE (self), G_SOURCE_REMOVE);

  if (self->periods) {
    double max_strength = fbd_feedback_vibra_get_max_strength (FBD_FEEDBACK_VIBRA (self));
    double magnitude;

    magnitude = MIN (self->magnitude, max_strength);
    fbd_dev_vibra_rumble (dev, magnitude, self->rumble, FALSE);
    self->periods--;
    return G_SOURCE_CONTINUE;
  }
  return G_SOURCE_REMOVE;
}

static void
fbd_feedback_vibra_rumble_end_vibra (FbdFeedbackVibra *vibra)
{
  FbdFeedbackVibraRumble *self = FBD_FEEDBACK_VIBRA_RUMBLE (vibra);
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  FbdDevVibra *dev = fbd_feedback_manager_get_dev_vibra (manager);

  fbd_dev_vibra_stop (dev);
  g_clear_handle_id(&self->timer_id, g_source_remove);
}

static void
fbd_feedback_vibra_rumble_start_vibra (FbdFeedbackVibra *vibra)
{
  FbdFeedbackVibraRumble *self = FBD_FEEDBACK_VIBRA_RUMBLE (vibra);
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  FbdDevVibra *dev = fbd_feedback_manager_get_dev_vibra (manager);
  guint duration = fbd_feedback_vibra_get_duration (vibra);
  double max_strength = fbd_feedback_vibra_get_max_strength (FBD_FEEDBACK_VIBRA (self));
  double magnitude;
  guint period;

  self->rumble = (duration / self->count) - self->pause;
  if (self->rumble <= 0) {
    self->rumble = FBD_FEEDBACK_VIBRA_DEFAULT_DURATION;
    self->pause = 0;
    self->count = 1;
  }
  period = self->rumble + self->pause;
  self->periods = self->count;

  magnitude = MIN (self->magnitude, max_strength);
  g_debug ("Rumble Vibra event: magnitude: %f, duration %d, rumble: %d, pause: %d, period: %d",
           magnitude, duration, self->rumble, self->pause, period);
  fbd_dev_vibra_rumble (dev, magnitude, self->rumble, TRUE);
  self->periods--;
  if (self->periods) {
    self->timer_id = g_timeout_add (period, (GSourceFunc) on_period_ended, self);
  }
}

static gboolean
fbd_feedback_vibra_rumble_is_available (FbdFeedbackBase *base)
{
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  FbdDevVibra *dev = fbd_feedback_manager_get_dev_vibra (manager);

  return FBD_IS_DEV_VIBRA (dev);
}

static void
fbd_feedback_vibra_rumble_class_init (FbdFeedbackVibraRumbleClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  FbdFeedbackBaseClass *base_class = FBD_FEEDBACK_BASE_CLASS (klass);
  FbdFeedbackVibraClass *vibra_class = FBD_FEEDBACK_VIBRA_CLASS (klass);

  object_class->set_property = fbd_feedback_vibra_rumble_set_property;
  object_class->get_property = fbd_feedback_vibra_rumble_get_property;

  base_class->is_available = fbd_feedback_vibra_rumble_is_available;

  vibra_class->start_vibra = fbd_feedback_vibra_rumble_start_vibra;
  vibra_class->end_vibra = fbd_feedback_vibra_rumble_end_vibra;

  props[PROP_COUNT] =
    g_param_spec_uint (
      "count",
      "Count",
      "The number of rumbles",
      0, G_MAXINT, 1,
      G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  props[PROP_PAUSE] =
    g_param_spec_uint (
      "pause",
      "Pause",
      "The pause in msecs between rumbles",
      0, G_MAXINT, 0,
      G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  props[PROP_MAGNITUDE] =
    g_param_spec_double ("magnitude", "", "",
                         0, 1.0, 0.5,
                         G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);
}

static void
fbd_feedback_vibra_rumble_init (FbdFeedbackVibraRumble *self)
{
  self->count = 1;
  self->magnitude = 0.5;
}
