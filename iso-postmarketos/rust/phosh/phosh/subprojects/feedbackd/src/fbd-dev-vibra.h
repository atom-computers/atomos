/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include <glib-object.h>
#include <gudev/gudev.h>

G_BEGIN_DECLS

#define FBD_TYPE_DEV_VIBRA (fbd_dev_vibra_get_type())

G_DECLARE_FINAL_TYPE (FbdDevVibra, fbd_dev_vibra, FBD, DEV_VIBRA, GObject);

FbdDevVibra *fbd_dev_vibra_new (GUdevDevice *device, GError **error);
gboolean     fbd_dev_vibra_rumble (FbdDevVibra *device,
                                   double       magnitude,
                                   guint        duration,
                                   gboolean     upload);
gboolean     fbd_dev_vibra_periodic (FbdDevVibra *self,
                                     guint        duration,
                                     double       magnitude,
                                     double       fade_in_level,
                                     guint        fade_in_time);
gboolean     fbd_dev_vibra_stop (FbdDevVibra *self);
gboolean     fbd_dev_vibra_remove_effect (FbdDevVibra *self);
GUdevDevice *fbd_dev_vibra_get_device(FbdDevVibra *self);
gboolean     fbd_dev_vibra_is_busy (FbdDevVibra *self);

G_END_DECLS
