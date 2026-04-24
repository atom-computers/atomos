/*
 * Copyright (C) 2023 Dylan Van Assche <me@dylanvanassche.be>
 *
 * SPDX-License-Identifier: GPL-3.0+
 */

#define G_LOG_DOMAIN "fbd-dev-led-qcom"

#include "fbd-dev-led-priv.h"
#include "fbd-dev-led-qcom.h"
#include "fbd-dev-led-qcom-priv.h"
#include "fbd-enums.h"
#include "fbd-udev.h"

#include <gio/gio.h>

#define LED_HW_PATTERN_ATTR   "hw_pattern"
#define LED_REPEAT_ATTR       "repeat"
#define LED_REPEAT_INFINITY   "-1"
#define QCOM_LPG_MAX_PAUSE_MS 511
#define LED_DRIVER_PROP       "DRIVER"
#define QCOM_LED_DRIVER       "qcom-spmi-lpg"

typedef struct _FbdDevLedQcom {
  FbdDevLed parent;
} FbdDevLedQcom;


G_DEFINE_TYPE (FbdDevLedQcom, fbd_dev_led_qcom, FBD_TYPE_DEV_LED)


static gboolean
fbd_dev_led_qcom_check_driver (FbdDevLedQcom *self, const char *name)
{
  g_autoptr (GUdevDevice) dev = NULL;
  gboolean found = FALSE;

  dev = g_object_ref (fbd_dev_led_get_device (FBD_DEV_LED (self)));
  do {
    g_autoptr (GUdevDevice) parent = NULL;
    const char *driver = g_udev_device_get_property (dev, LED_DRIVER_PROP);

    if (g_strcmp0 (driver, QCOM_LED_DRIVER) == 0) {
      found = TRUE;
      break;
    }

    parent = g_udev_device_get_parent (dev);
    g_set_object (&dev, parent);
  } while (dev);

  return found;
}


static gboolean
fbd_dev_led_qcom_probe (FbdDevLed *led, GError **error)
{
  GUdevDevice *dev = fbd_dev_led_get_device (led);
  const char *name;
  const char * const *index;

  name = g_udev_device_get_name (dev);

  index = g_udev_device_get_sysfs_attr_as_strv (dev, LED_HW_PATTERN_ATTR);
  if (index == NULL) {
    g_set_error (error,
               G_FILE_ERROR, G_FILE_ERROR_FAILED,
               "%s is no LED with HW support", name);
    return FALSE;
  }

  if (!fbd_dev_led_qcom_check_driver (FBD_DEV_LED_QCOM (led), QCOM_LED_DRIVER)) {
    g_set_error (error,
                 G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "%s is no QCOM LED with HW support", name);
    return FALSE;
  }

  return FBD_DEV_LED_CLASS (fbd_dev_led_qcom_parent_class)->probe(led, error);
}


static gboolean
fbd_dev_led_qcom_start_periodic (FbdDevLed *led,
                                 guint      max_brightness_percentage,
                                 guint      freq)
{
  GUdevDevice *dev = fbd_dev_led_get_device (led);
  gdouble max;
  gdouble t;
  g_autofree char *str = NULL;
  g_autoptr (GError) err = NULL;
  gboolean success;

  g_return_val_if_fail (max_brightness_percentage <= 100.0, FALSE);
  max = fbd_dev_led_get_max_brightness (led) * (max_brightness_percentage / 100.0);

  g_debug ("Using hw_pattern interface for QCOM LPG LED");

  /* QCOM LPG LEDs can only pause up to 511ms */
  /*  ms     mHz           T/2 */
  t = 1000.0 * 1000.0 / freq / 2.0;
  if (t > QCOM_LPG_MAX_PAUSE_MS)
    t = QCOM_LPG_MAX_PAUSE_MS;

  str = g_strdup_printf ("0 %d 0 0 %d %d %d 0\n", (gint)t, (gint)max, (gint)t, (gint)max);

  success = fbd_udev_set_sysfs_path_attr_as_string (dev, LED_REPEAT_ATTR, LED_REPEAT_INFINITY, &err);
  if (!success) {
    g_warning ("Failed to set LED repeat: %s", err->message);
    goto failure;
  }

  success = fbd_udev_set_sysfs_path_attr_as_string (dev, LED_HW_PATTERN_ATTR, str, &err);
  if (!success) {
    g_warning ("Failed to set LED hw_pattern: %s", err->message);
    goto failure;
  }

  g_debug ("Freq %d mHz, Brightness: %d%%, Blink pattern: %s, HW: yes", freq, max_brightness_percentage, str);
  return TRUE;

failure:
  g_warning("Falling back to software pattern");
  return FBD_DEV_LED_CLASS (fbd_dev_led_qcom_parent_class)->start_periodic (
    led, max_brightness_percentage, freq);
}


static void
fbd_dev_led_qcom_class_init (FbdDevLedQcomClass *klass)
{
  FbdDevLedClass *fbd_dev_led_class = FBD_DEV_LED_CLASS (klass);

  fbd_dev_led_class->probe = fbd_dev_led_qcom_probe;
  fbd_dev_led_class->start_periodic = fbd_dev_led_qcom_start_periodic;
}


static void
fbd_dev_led_qcom_init (FbdDevLedQcom *self)
{
  fbd_dev_led_set_priority (FBD_DEV_LED (self), 20);
}


FbdDevLed *
fbd_dev_led_qcom_new (GUdevDevice *dev, GError **err)
{
  return g_initable_new (FBD_TYPE_DEV_LED_QCOM, NULL, err, "dev", dev, NULL);
}
