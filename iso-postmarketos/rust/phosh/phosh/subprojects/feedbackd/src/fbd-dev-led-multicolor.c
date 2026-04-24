/*
 * Copyright (C) 2023  Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 *
 * See Documentation/ABI/testing/sysfs-class-led-trigger-pattern
 */

#define G_LOG_DOMAIN "fbd-dev-led-multicolor"

#include "fbd-dev-led-priv.h"
#include "fbd-dev-led-multicolor.h"
#include "fbd-enums.h"
#include "fbd-udev.h"

#include <gio/gio.h>

#include <math.h>

#define LED_MULTI_INDEX_ATTR     "multi_index"
#define LED_MULTI_INDEX_RED      "red"
#define LED_MULTI_INDEX_GREEN    "green"
#define LED_MULTI_INDEX_BLUE     "blue"
#define LED_MULTI_INTENSITY_ATTR "multi_intensity"

/**
 * fbd-dev-led-multicolor:
 *
 * A multicolor led using the `multi_intensitiy` sysfs attribute
 */
typedef struct _FbdDevLedMulticolorPrivate {
  guint               red_index;
  guint               green_index;
  guint               blue_index;
} FbdDevLedMulticolorPrivate;


G_DEFINE_TYPE_WITH_PRIVATE (FbdDevLedMulticolor, fbd_dev_led_multicolor, FBD_TYPE_DEV_LED)


static gboolean
fbd_dev_led_multicolor_probe (FbdDevLed *led, GError **error)
{
  FbdDevLedMulticolor *self = FBD_DEV_LED_MULTICOLOR (led);
  FbdDevLedMulticolorPrivate *priv = fbd_dev_led_multicolor_get_instance_private (self);
  GUdevDevice *dev = fbd_dev_led_get_device (led);
  const gchar *name, *path;
  const gchar * const *index;
  guint counter = 0;
  guint max_brightness;

  name = g_udev_device_get_name (dev);

  index = g_udev_device_get_sysfs_attr_as_strv (dev, LED_MULTI_INDEX_ATTR);
  if (index == NULL) {
    g_set_error (error,
                 G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "%s is no multicolor LED", name);
    return FALSE;
  }

  if (g_strv_length ((GStrv)index) != 3) {
    g_set_error (error,
                 G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "%s is no multicolor RGB LED", name);
    return FALSE;
  }

  max_brightness = g_udev_device_get_sysfs_attr_as_int (dev, LED_MAX_BRIGHTNESS_ATTR);
  if (!max_brightness) {
    g_set_error (error,
                 G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "%s has no max_brightness", name);
    return FALSE;
  }
  fbd_dev_led_set_max_brightness (led, max_brightness);
  fbd_dev_led_set_supported_color (led, FBD_FEEDBACK_LED_COLOR_RGB);

  for (int i = 0; index[i] != NULL; i++) {
    g_debug ("Index: %s", index[i]);
    if (g_strcmp0 (index[i], LED_MULTI_INDEX_RED) == 0) {
      priv->red_index = counter;
      counter++;
    } else if (g_strcmp0 (index[i], LED_MULTI_INDEX_GREEN) == 0) {
      priv->green_index = counter;
      counter++;
    } else if (g_strcmp0 (index[i], LED_MULTI_INDEX_BLUE) == 0) {
      priv->blue_index = counter;
      counter++;
    } else {
      g_warning ("Unsupported LED color index: %d %s", counter, index[i]);
    }
  }

  path = g_udev_device_get_sysfs_path (dev);
  g_debug ("LED at '%s' usable as multicolor", path);
  return TRUE;
}


static gboolean
fbd_dev_led_multicolor_set_color (FbdDevLed           *led,
                                  FbdFeedbackLedColor  color,
                                  FbdLedRgbColor      *rgb)
{
  FbdDevLedMulticolor *self = FBD_DEV_LED_MULTICOLOR (led);
  FbdDevLedMulticolorPrivate *priv = fbd_dev_led_multicolor_get_instance_private (self);
  GUdevDevice *dev = fbd_dev_led_get_device (led);
  g_autofree char *intensity = NULL;
  g_autoptr (GError) err = NULL;
  gboolean success = FALSE;
  guint max_brightness;
  guint colors[] = { 0, 0, 0 };

  max_brightness = fbd_dev_led_get_max_brightness (led);
  switch (color) {
  case FBD_FEEDBACK_LED_COLOR_WHITE:
    colors[priv->red_index] = max_brightness;
    colors[priv->green_index] = max_brightness;
    colors[priv->blue_index] = max_brightness;
    break;
  case FBD_FEEDBACK_LED_COLOR_RED:
    colors[priv->red_index] = max_brightness;
    colors[priv->green_index] = 0;
    colors[priv->blue_index] = 0;
    break;
  case FBD_FEEDBACK_LED_COLOR_GREEN:
    colors[priv->red_index] = 0;
    colors[priv->green_index] = max_brightness;
    colors[priv->blue_index] = 0;
    break;
  case FBD_FEEDBACK_LED_COLOR_BLUE:
    colors[priv->red_index] = 0;
    colors[priv->green_index] = 0;
    colors[priv->blue_index] = max_brightness;
    break;
  case FBD_FEEDBACK_LED_COLOR_RGB: {
    float scale = max_brightness / 255.0;
    /* RGB colors are 0..255 so we need to scale to 0..max_brightness */
    colors[priv->red_index] = MIN (max_brightness, roundf (rgb->r * scale));
    colors[priv->green_index] = MIN (max_brightness, roundf (rgb->g * scale));
    colors[priv->blue_index] = MIN (max_brightness, roundf (rgb->b * scale));
    break;
  }
  default:
    g_warning("Unhandled color: %d\n", color);
    return FALSE;
  }

  intensity = g_strdup_printf ("%u %u %u\n", colors[0], colors[1], colors[2]);
  g_debug ("Multicolor intensity: %s", intensity);

  fbd_dev_led_set_brightness (led, max_brightness);
  success = fbd_udev_set_sysfs_path_attr_as_string (dev,
                                                    LED_MULTI_INTENSITY_ATTR,
                                                    intensity,
                                                    &err);
  if (!success) {
    g_warning ("Failed to set multi intensity: %s", err->message);
    return FALSE;
  }

  return TRUE;
}


static gboolean
fbd_dev_led_multicolor_supports_color (FbdDevLed           *led,
                                       FbdFeedbackLedColor  color)
{
  switch(color) {
    case FBD_FEEDBACK_LED_COLOR_WHITE:
      return TRUE;
    case FBD_FEEDBACK_LED_COLOR_RED:
      return TRUE;
    case FBD_FEEDBACK_LED_COLOR_GREEN:
      return TRUE;
    case FBD_FEEDBACK_LED_COLOR_BLUE:
      return TRUE;
    case FBD_FEEDBACK_LED_COLOR_RGB:
      return TRUE;
    default:
      g_warning ("Color unsupported: %d", color);
      return FALSE;
  }
}


static void
fbd_dev_led_multicolor_class_init (FbdDevLedMulticolorClass *klass)
{
  FbdDevLedClass *fbd_dev_led_class = FBD_DEV_LED_CLASS (klass);

  fbd_dev_led_class->probe = fbd_dev_led_multicolor_probe;
  fbd_dev_led_class->set_color = fbd_dev_led_multicolor_set_color;
  fbd_dev_led_class->supports_color = fbd_dev_led_multicolor_supports_color;
}


static void
fbd_dev_led_multicolor_init (FbdDevLedMulticolor *self)
{
  fbd_dev_led_set_priority (FBD_DEV_LED (self), 50);
}


FbdDevLed *
fbd_dev_led_multicolor_new (GUdevDevice *dev, GError **err)
{
  return g_initable_new (FBD_TYPE_DEV_LED_MULTICOLOR, NULL, err, "dev", dev, NULL);
}
