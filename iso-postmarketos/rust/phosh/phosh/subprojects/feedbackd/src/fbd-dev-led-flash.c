/*
 * Copyright (C) 2024 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 *
 * See Documentation/ABI/testing/sysfs-class-led-trigger-pattern
 */

#define G_LOG_DOMAIN "fbd-dev-led-flash"

#include "fbd-dev-led-priv.h"
#include "fbd-dev-led-flash.h"
#include "fbd-enums.h"
#include "fbd-udev.h"

#include <gio/gio.h>

/**
 * fbd-dev-led-flash:
 *
 * The LED of a camera flash
 */
typedef struct _FbdDevLedFlash {
  FbdDevLed parent;
} FbdDevLedFlash;


G_DEFINE_TYPE (FbdDevLedFlash, fbd_dev_led_flash, FBD_TYPE_DEV_LED)


static gboolean
fbd_dev_led_flash_probe (FbdDevLed *led, GError **error)
{
  GUdevDevice *dev = fbd_dev_led_get_device (led);
  const gchar *name, *path;
  guint max_brightness;

  name = g_udev_device_get_name (dev);
  if (!g_udev_device_get_sysfs_attr (dev, "flash_strobe") ||
      !g_udev_device_get_sysfs_attr (dev, "flash_brightness")) {
    g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_FAILED, "%s is no flash LED", name);
    return FALSE;
  }

  max_brightness = g_udev_device_get_sysfs_attr_as_int (dev, LED_MAX_BRIGHTNESS_ATTR);
  if (!max_brightness) {
    g_set_error (error, G_FILE_ERROR, G_FILE_ERROR_FAILED, "%s has no max_brightness", name);
    return FALSE;
  }

  fbd_dev_led_set_max_brightness (led, max_brightness);
  fbd_dev_led_set_supported_color (led, FBD_FEEDBACK_LED_COLOR_FLASH);

  path = g_udev_device_get_sysfs_path (dev);
  g_debug ("LED at '%s' usable as flash", path);

  return TRUE;
}


static void
fbd_dev_led_flash_class_init (FbdDevLedFlashClass *klass)
{
  FbdDevLedClass *fbd_dev_led_class = FBD_DEV_LED_CLASS (klass);

  fbd_dev_led_class->probe = fbd_dev_led_flash_probe;
}


static void
fbd_dev_led_flash_init (FbdDevLedFlash *self)
{
  fbd_dev_led_set_priority (FBD_DEV_LED (self), 5);
}


FbdDevLed *
fbd_dev_led_flash_new (GUdevDevice *dev, GError **err)
{
  return g_initable_new (FBD_TYPE_DEV_LED_FLASH, NULL, err, "dev", dev, NULL);
}
