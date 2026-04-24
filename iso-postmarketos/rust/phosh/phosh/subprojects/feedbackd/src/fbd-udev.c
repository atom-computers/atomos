/*
 * Copyright (C) 2020 Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 *
 */

#define G_LOG_DOMAIN "fbd-udev"

#include "fbd-udev.h"

#include <gio/gio.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>

gboolean
fbd_udev_set_sysfs_path_attr_as_string (GUdevDevice *dev, const gchar *attr,
                                        const gchar *s, GError **err)
{
  gint fd;
  int len;
  g_autofree gchar *path = g_strjoin ("/", g_udev_device_get_sysfs_path (dev),
                                      attr, NULL);

  fd = open (path, O_WRONLY|O_TRUNC, 0666);
  if (fd < 0) {
    g_set_error (err, G_IO_ERROR, G_IO_ERROR_FAILED, "Failed to open %s: %s",
                 path, strerror (errno));
    return FALSE;
  }

  len = strlen (s);
  if (write (fd, s, len) < 0) {
    g_set_error (err, G_IO_ERROR, G_IO_ERROR_FAILED, "Failed to write %s to %s: %s",
                 s, path, strerror (errno));
    close (fd);
    return FALSE;
  }

  if (close (fd) < 0) {
    g_set_error (err, G_IO_ERROR, G_IO_ERROR_FAILED, "Failed to close %s: %s",
                 path, strerror (errno));
    return FALSE;
  }

  return TRUE;
}

gboolean
fbd_udev_set_sysfs_path_attr_as_int (GUdevDevice *dev, const gchar *attr,
                                     gint val, GError **err)
{
  gint fd;
  int len;
  g_autofree gchar *s = NULL;

  g_autofree gchar *path = g_strjoin ("/", g_udev_device_get_sysfs_path (dev),
                                      attr, NULL);

  fd = open (path, O_WRONLY|O_TRUNC, 0666);
  if (fd < 0) {
    g_set_error (err, G_IO_ERROR, G_IO_ERROR_FAILED, "Failed to open %s: %s",
                 path, strerror (errno));
    return FALSE;
  }

  s = g_strdup_printf ("%d", val);
  len = strlen (s);
  if (write (fd, s, len) < len) {
    g_set_error (err, G_IO_ERROR, G_IO_ERROR_FAILED, "Failed to write %s: %s",
                 path, strerror (errno));
    close (fd);
    return FALSE;
  }

  if (close (fd) < 0) {
    g_set_error (err, G_IO_ERROR, G_IO_ERROR_FAILED, "Failed to close %s: %s",
                 path, strerror (errno));
    return FALSE;
  }

  return TRUE;
}
