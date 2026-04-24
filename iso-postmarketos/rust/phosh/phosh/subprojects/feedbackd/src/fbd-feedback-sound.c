/*
 * Copyright (C) 2020 Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-feedback-sound"

#include "fbd-enums.h"
#include "fbd-feedback-sound.h"
#include "fbd-feedback-manager.h"

/**
 * SECTION:fbd-feedback-sound
 * @short_description: Describes a feedback via a haptic motor
 * @Title: FbdFeedbackSound
 *
 * The #FbdSoundSound describes the properties of a sound feedback
 * event. It knows nothing about how to play sound itself but calls
 * #FbdDevSound for that.
 */

enum {
  PROP_0,
  PROP_EFFECT,
  PROP_FILE_NAME,
  PROP_MEDIA_ROLE,
  PROP_LAST_PROP,
};
static GParamSpec *props[PROP_LAST_PROP];

typedef struct _FbdFeedbackSound {
  FbdFeedbackBase parent;

  char           *effect;
  char           *file_name;
  char           *media_role;
} FbdFeedbackSound;

G_DEFINE_TYPE (FbdFeedbackSound, fbd_feedback_sound, FBD_TYPE_FEEDBACK_BASE);

static void
on_effect_finished (FbdFeedbackSound *self)

{
  fbd_feedback_base_done (FBD_FEEDBACK_BASE(self));
}

static void
fbd_feedback_sound_run (FbdFeedbackBase *base)
{
  FbdFeedbackSound *self = FBD_FEEDBACK_SOUND (base);
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  FbdDevSound *sound = fbd_feedback_manager_get_dev_sound (manager);

  g_return_if_fail (FBD_IS_DEV_SOUND (sound));
  g_debug ("Sound event %s", self->effect);
  fbd_dev_sound_play (sound, self, on_effect_finished);
}


static void
fbd_feedback_sound_end (FbdFeedbackBase *base)
{
  FbdFeedbackSound *self = FBD_FEEDBACK_SOUND (base);
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  FbdDevSound *sound = fbd_feedback_manager_get_dev_sound (manager);

  fbd_dev_sound_stop (sound, self);
}

static gboolean
fbd_feedback_sound_is_available (FbdFeedbackBase *base)
{
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  FbdDevSound *sound = fbd_feedback_manager_get_dev_sound (manager);

  return FBD_IS_DEV_SOUND (sound);
}

static void
fbd_feedback_sound_set_property (GObject      *object,
                                 guint         property_id,
                                 const GValue *value,
                                 GParamSpec   *pspec)
{
  FbdFeedbackSound *self = FBD_FEEDBACK_SOUND (object);

  switch (property_id) {
  case PROP_EFFECT:
    self->effect = g_value_dup_string (value);
    break;
  case PROP_FILE_NAME:
    self->file_name = g_value_dup_string (value);
    break;
  case PROP_MEDIA_ROLE:
    self->media_role = g_value_dup_string (value);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static void
fbd_feedback_sound_get_property (GObject    *object,
                                 guint       property_id,
                                 GValue     *value,
                                 GParamSpec *pspec)
{
  FbdFeedbackSound *self = FBD_FEEDBACK_SOUND (object);

  switch (property_id) {
  case PROP_EFFECT:
    g_value_set_string (value, fbd_feedback_sound_get_effect (self));
    break;
  case PROP_FILE_NAME:
    g_value_set_string (value, fbd_feedback_sound_get_file_name (self));
    break;
  case PROP_MEDIA_ROLE:
    g_value_set_string (value, fbd_feedback_sound_get_media_role (self));
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

static void
fbd_feedback_sound_finalize (GObject *object)
{
  FbdFeedbackSound *self = FBD_FEEDBACK_SOUND (object);

  g_clear_pointer (&self->effect, g_free);
  g_clear_pointer (&self->file_name, g_free);
  g_clear_pointer (&self->media_role, g_free);

  G_OBJECT_CLASS (fbd_feedback_sound_parent_class)->finalize (object);
}

static void
fbd_feedback_sound_class_init (FbdFeedbackSoundClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  FbdFeedbackBaseClass *base_class = FBD_FEEDBACK_BASE_CLASS (klass);

  object_class->finalize = fbd_feedback_sound_finalize;
  object_class->set_property = fbd_feedback_sound_set_property;
  object_class->get_property = fbd_feedback_sound_get_property;

  base_class->run = fbd_feedback_sound_run;
  base_class->end = fbd_feedback_sound_end;
  base_class->is_available = fbd_feedback_sound_is_available;

  /**
   * FbdFeedbackSound:effect:
   *
   * The sound effect name
   */
  props[PROP_EFFECT] =
    g_param_spec_string ("effect", "", "",
                         NULL,
                         G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);
  /**
   * FbdFeedbackSound:file-name:
   *
   * The file name to use for the sound effect. This overrides the
   * effect name.
   */
  props[PROP_FILE_NAME] =
    g_param_spec_string ("file-name", "", "",
                         NULL,
                         G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);
  /**
   * FbdFeedbackSound:media-role:
   *
   * The media-role to use when playing the sound.
   */
  props[PROP_MEDIA_ROLE] =
    g_param_spec_string ("media-role", "", "",
                         NULL,
                         G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);
}

static void
fbd_feedback_sound_init (FbdFeedbackSound *self)
{
}


FbdFeedbackSound *
fbd_feedback_sound_new_from_file_name (const char *filename)
{
  return g_object_new (FBD_TYPE_FEEDBACK_SOUND, "file-name", filename, NULL);
}


const char *
fbd_feedback_sound_get_effect (FbdFeedbackSound *self)
{
  return self->effect;
}


const char *
fbd_feedback_sound_get_file_name (FbdFeedbackSound *self)
{
  return self->file_name;
}


const char *
fbd_feedback_sound_get_media_role (FbdFeedbackSound *self)
{
  return self->media_role;
}
