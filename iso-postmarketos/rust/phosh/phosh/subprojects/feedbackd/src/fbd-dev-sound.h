/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include <glib-object.h>

#include "fbd-feedback-sound.h"

G_BEGIN_DECLS

#define FBD_TYPE_DEV_SOUND (fbd_dev_sound_get_type())

G_DECLARE_FINAL_TYPE (FbdDevSound, fbd_dev_sound, FBD, DEV_SOUND, GObject);

typedef void (*FbdDevSoundPlayedCallback)(FbdFeedbackSound *feedback);

FbdDevSound *fbd_dev_sound_new (GError **error);
gboolean     fbd_dev_sound_play (FbdDevSound *self,
                                 FbdFeedbackSound *feedback,
                                 FbdDevSoundPlayedCallback callback);
gboolean     fbd_dev_sound_stop (FbdDevSound *self, FbdFeedbackSound *feedback);

G_END_DECLS
