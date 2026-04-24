/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include <glib.h>
#include <gudev/gudev.h>


G_BEGIN_DECLS

gboolean fbd_udev_set_sysfs_path_attr_as_string (GUdevDevice *dev, const gchar *attr,
						 const gchar *s, GError **err);
gboolean fbd_udev_set_sysfs_path_attr_as_int (GUdevDevice *dev, const gchar *attr,
					      gint val, GError **err);

G_END_DECLS
