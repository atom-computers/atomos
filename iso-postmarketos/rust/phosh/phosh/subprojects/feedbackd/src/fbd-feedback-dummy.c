/*
 * Copyright (C) 2020 Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-feedback-dummy"

#include "fbd-enums.h"
#include "fbd-feedback-dummy.h"
#include "fbd-feedback-manager.h"

/**
 * SECTION:fbd-feedback-dummy
 * @short_description: Describes a dummy feedback event that does nothing
 * @Title: FbdFeedbackDummy
 */

enum {
  PROP_0,
  PROP_DURATION,
  PROP_LAST_PROP,
};
static GParamSpec *props[PROP_LAST_PROP];

typedef struct _FbdFeedbackDummy {
  FbdFeedbackBase parent;

  guint duration;
  guint timer_id;
} FbdFeedbackDummy;

G_DEFINE_TYPE (FbdFeedbackDummy, fbd_feedback_dummy, FBD_TYPE_FEEDBACK_BASE);

static void
fbd_feedback_dummy_set_property (GObject      *object,
                                   guint         property_id,
                                   const GValue *value,
                                   GParamSpec   *pspec)
{
  FbdFeedbackDummy *self = FBD_FEEDBACK_DUMMY (object);

  switch (property_id) {
  case PROP_DURATION:
    self->duration = g_value_get_uint (value);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static void
fbd_feedback_dummy_get_property (GObject    *object,
				 guint       property_id,
				 GValue     *value,
				 GParamSpec *pspec)
{
  FbdFeedbackDummy *self = FBD_FEEDBACK_DUMMY (object);

  switch (property_id) {
  case PROP_DURATION:
    g_value_set_uint (value, self->duration);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static gboolean
on_timeout_expired (FbdFeedbackDummy *self)
{
  fbd_feedback_base_done (FBD_FEEDBACK_BASE(self));
  return G_SOURCE_REMOVE;
}

static void
fbd_feedback_dummy_run (FbdFeedbackBase *base)
{
  FbdFeedbackDummy *self = FBD_FEEDBACK_DUMMY (base);

  if (self->duration) {
    self->timer_id = g_timeout_add (self->duration,
				  (GSourceFunc)on_timeout_expired,
				  self);
    g_source_set_name_by_id (self->timer_id, "feedback-dummy-timer");
  } else {
    fbd_feedback_base_done (base);
  }
}

static void
fbd_feedback_dummy_end (FbdFeedbackBase *base)
{
  FbdFeedbackDummy *self = FBD_FEEDBACK_DUMMY (base);

  g_clear_handle_id(&self->timer_id, g_source_remove);
  fbd_feedback_base_done (base);
}

static void
fbd_feedback_dummy_class_init (FbdFeedbackDummyClass *klass)
{
  FbdFeedbackBaseClass *base_class = FBD_FEEDBACK_BASE_CLASS (klass);
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->set_property = fbd_feedback_dummy_set_property;
  object_class->get_property = fbd_feedback_dummy_get_property;

  base_class->run = fbd_feedback_dummy_run;
  base_class->end = fbd_feedback_dummy_end;

  props[PROP_DURATION] =
    g_param_spec_uint (
      "duration",
      "Duration",
      "Dummy event duration in msecs",
      0, G_MAXUINT, 0,
      G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);
}

static void
fbd_feedback_dummy_init (FbdFeedbackDummy *self)
{
}

guint
fbd_feedback_dummy_get_duration (FbdFeedbackDummy *self)
{
  g_return_val_if_fail (FBD_IS_FEEDBACK_DUMMY (self), 0);

  return self->duration;
}
