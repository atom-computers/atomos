/*
 * Copyright (C) 2020 Purism SPC
 *               2025 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 *
 * See Documentation/ABI/testing/sysfs-class-led-trigger-pattern
 */

#define G_LOG_DOMAIN "fbd-dev-led"

#include "fbd-dev-led.h"
#include "fbd-dev-led-priv.h"
#include "fbd-enums.h"
#include "fbd-udev.h"

#include <gio/gio.h>

#define LED_BRIGHTNESS_ATTR      "brightness"
#define LED_PATTERN_ATTR         "pattern"

enum {
  PROP_0,
  PROP_DEV,
  PROP_LAST_PROP
};
static GParamSpec *props[PROP_LAST_PROP];

/**
 * FbdDevLed:
 *
 * A single color LED driven by Linux sysfs
 */
typedef struct _FbdDevLedPrivate {
  GUdevDevice        *dev;
  guint               max_brightness;

  int                 priority;
  FbdFeedbackLedColor color;
} FbdDevLedPrivate;


static void initable_iface_init (GInitableIface *iface);

G_DEFINE_TYPE_WITH_CODE (FbdDevLed, fbd_dev_led, G_TYPE_OBJECT,
                         G_ADD_PRIVATE (FbdDevLed)
                         G_IMPLEMENT_INTERFACE (G_TYPE_INITABLE, initable_iface_init))

static gboolean
fbd_dev_led_probe_default (FbdDevLed *led, GError **error)
{
  FbdDevLedPrivate *priv = fbd_dev_led_get_instance_private (led);
  const gchar *name, *path, *hint;
  gboolean success = FALSE;
  const char *pattern;

  name = g_udev_device_get_name (priv->dev);
  hint = g_udev_device_get_property (priv->dev, "FEEDBACKD_LED_COLOR");
  pattern = g_udev_device_get_sysfs_attr (priv->dev, LED_PATTERN_ATTR);
  if (!pattern) {
    g_set_error (error,
                 G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "LED %s can't use patterns", name);
    return FALSE;
  }

  for (int i = 0; i <= FBD_FEEDBACK_LED_COLOR_RGB; i++) {
    g_autofree char *color = NULL;
    g_autofree char *enum_name = NULL;
    gchar *c;

    enum_name = g_enum_to_string (FBD_TYPE_FEEDBACK_LED_COLOR, i);
    c = strrchr (enum_name, '_');
    color = g_ascii_strdown (c+1, -1);
    if (g_strstr_len (name, -1, color) || !g_strcmp0 (hint, color)) {
      guint brightness = g_udev_device_get_sysfs_attr_as_int (priv->dev, LED_MAX_BRIGHTNESS_ATTR);

      if (!brightness)
        continue;

      priv->color = i;
      fbd_dev_led_set_max_brightness (led, brightness);

      path = g_udev_device_get_sysfs_path (priv->dev);
      g_debug ("LED at '%s' usable for %s", path, color);
      success = TRUE;
      break;
    }
  }

  if (!success) {
    g_set_error (error,
                 G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "%s not usable as RGB LED", name);
  }

  return success;
}


static gboolean
fbd_dev_led_set_color_default (FbdDevLed           *led,
                               FbdFeedbackLedColor  color,
                               FbdLedRgbColor      *rgb)
{
  /* Ignore setting color as we have a single color only */
  return TRUE;
}


static gboolean
fbd_dev_led_supports_color_default (FbdDevLed           *led,
                                    FbdFeedbackLedColor  color)
{
  FbdDevLedPrivate *priv;

  g_return_val_if_fail (FBD_IS_DEV_LED (led), FALSE);
  priv = fbd_dev_led_get_instance_private (led);

  return priv->color == color;
}


static gboolean
fbd_dev_led_start_periodic_default (FbdDevLed *led,
                                    guint      max_brightness_percentage,
                                    guint      freq)
{
  FbdDevLedPrivate *priv;
  gboolean success = FALSE;
  gdouble max;

  g_return_val_if_fail (FBD_IS_DEV_LED (led), FALSE);
  g_return_val_if_fail (max_brightness_percentage <= 100, FALSE);
  priv = fbd_dev_led_get_instance_private (led);

  max =  priv->max_brightness * (max_brightness_percentage / 100.0);
  if (freq) {
    g_autofree gchar *str = NULL;
    g_autoptr (GError) err = NULL;
    gdouble t;

    /*  ms     mHz           T/2 */
    t = 1000.0 * 1000.0 / freq / 2.0;
    str = g_strdup_printf ("0 %d %d %d\n", (gint)t, (gint)max, (gint)t);
    g_debug ("Freq %d mHz, Brightness: %d%%, Blink pattern: %s", freq, max_brightness_percentage,
             str);
    success = fbd_udev_set_sysfs_path_attr_as_string (priv->dev, LED_PATTERN_ATTR, str, &err);
    if (!success)
      g_warning ("Failed to set led pattern: %s", err->message);
  } else {
    g_debug ("Constant light, Brightness: %d%%", max_brightness_percentage);
    success = fbd_dev_led_set_brightness (led, (gint)max);
  }

  return success;
}


static void
fbd_dev_led_set_property (GObject      *object,
                          guint         property_id,
                          const GValue *value,
                          GParamSpec   *pspec)
{
  FbdDevLed *led = FBD_DEV_LED (object);
  FbdDevLedPrivate *priv = fbd_dev_led_get_instance_private (led);

  switch (property_id) {
  case PROP_DEV:
    priv->dev = g_value_dup_object (value);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
fbd_dev_led_get_property (GObject    *object,
                          guint       property_id,
                          GValue     *value,
                          GParamSpec *pspec)
{
  FbdDevLed *led = FBD_DEV_LED (object);
  FbdDevLedPrivate *priv = fbd_dev_led_get_instance_private (led);

  switch (property_id) {
  case PROP_DEV:
    g_value_set_object (value, priv->dev);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
fbd_dev_led_finalize (GObject *object)
{
  FbdDevLed *self = FBD_DEV_LED (object);
  FbdDevLedPrivate *priv = fbd_dev_led_get_instance_private (self);

  g_clear_object (&priv->dev);

  G_OBJECT_CLASS (fbd_dev_led_parent_class)->finalize (object);
}


static gboolean
initable_init (GInitable    *initable,
               GCancellable *cancellable,
               GError      **error)
{
  FbdDevLedClass *fbd_dev_led_class = FBD_DEV_LED_GET_CLASS (initable);

  return fbd_dev_led_class->probe (FBD_DEV_LED (initable), error);
}


static void
initable_iface_init (GInitableIface *iface)
{
  iface->init = initable_init;
}


static void
fbd_dev_led_class_init (FbdDevLedClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  FbdDevLedClass *fbd_dev_led_class = FBD_DEV_LED_CLASS (klass);

  object_class->get_property = fbd_dev_led_get_property;
  object_class->set_property = fbd_dev_led_set_property;
  object_class->finalize = fbd_dev_led_finalize;

  fbd_dev_led_class->probe = fbd_dev_led_probe_default;
  fbd_dev_led_class->start_periodic = fbd_dev_led_start_periodic_default;
  fbd_dev_led_class->set_color = fbd_dev_led_set_color_default;
  fbd_dev_led_class->supports_color = fbd_dev_led_supports_color_default;

  props[PROP_DEV] =
    g_param_spec_object ("dev", "", "",
                         G_UDEV_TYPE_DEVICE,
                         G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);
}


static void
fbd_dev_led_init (FbdDevLed *self)
{
  fbd_dev_led_set_priority (self, 10);
}


FbdDevLed *
fbd_dev_led_new (GUdevDevice *dev, GError **err)
{
  return g_initable_new (FBD_TYPE_DEV_LED, NULL, err, "dev", dev, NULL);
}


gboolean
fbd_dev_led_set_brightness (FbdDevLed *led, guint brightness)
{
  FbdDevLedPrivate *priv;
  g_autoptr (GError) err = NULL;

  g_return_val_if_fail (FBD_IS_DEV_LED (led), FALSE);
  priv = fbd_dev_led_get_instance_private (led);

  if (!fbd_udev_set_sysfs_path_attr_as_int (priv->dev, LED_BRIGHTNESS_ATTR, brightness, &err)) {
    g_warning ("Failed to setup brightness: %s", err->message);
    return FALSE;
  }

  return TRUE;
}


gboolean
fbd_dev_led_start_periodic (FbdDevLed *led,
                            guint      max_brightness_percentage,
                            guint      freq)
{
  FbdDevLedClass *fbd_dev_led_class = FBD_DEV_LED_GET_CLASS (led);

  g_return_val_if_fail (FBD_IS_DEV_LED (led), FALSE);

  return fbd_dev_led_class->start_periodic (led, max_brightness_percentage, freq);
}


gboolean
fbd_dev_led_set_color (FbdDevLed           *led,
                       FbdFeedbackLedColor  color,
                       FbdLedRgbColor      *rgb)
{
  FbdDevLedClass *fbd_dev_led_class = FBD_DEV_LED_GET_CLASS (led);

  g_return_val_if_fail (FBD_IS_DEV_LED (led), FALSE);

  return fbd_dev_led_class->set_color (led, color, rgb);
}


gboolean
fbd_dev_led_supports_color (FbdDevLed *led, FbdFeedbackLedColor color)
{
  FbdDevLedClass *fbd_dev_led_class = FBD_DEV_LED_GET_CLASS (led);

  g_return_val_if_fail (FBD_IS_DEV_LED (led), FALSE);

  return fbd_dev_led_class->supports_color (led, color);
}


guint
fbd_dev_led_get_max_brightness (FbdDevLed *led)
{
  FbdDevLedPrivate *priv;

  g_return_val_if_fail (FBD_IS_DEV_LED (led), 0);
  priv = fbd_dev_led_get_instance_private (led);

  return priv->max_brightness;
}

/* Functions for derived classes */

GUdevDevice *
fbd_dev_led_get_device (FbdDevLed *led)
{
  FbdDevLedPrivate *priv;

  g_return_val_if_fail (FBD_IS_DEV_LED (led), NULL);
  priv = fbd_dev_led_get_instance_private (led);

  return priv->dev;
}


void
fbd_dev_led_set_supported_color (FbdDevLed *led, FbdFeedbackLedColor color)
{
  FbdDevLedPrivate *priv;

  g_return_if_fail (FBD_IS_DEV_LED (led));
  priv = fbd_dev_led_get_instance_private (led);

  priv->color = color;
}


void
fbd_dev_led_set_max_brightness (FbdDevLed *led, guint max_brightness)
{
  FbdDevLedPrivate *priv;

  g_return_if_fail (FBD_IS_DEV_LED (led));
  priv = fbd_dev_led_get_instance_private (led);

  priv->max_brightness = max_brightness;
}


int
fbd_dev_led_get_priority (FbdDevLed *self)
{
  FbdDevLedPrivate *priv;

  g_return_val_if_fail (FBD_IS_DEV_LED (self), 0);
  priv = fbd_dev_led_get_instance_private (self);

  return priv->priority;
}


void
fbd_dev_led_set_priority (FbdDevLed *self, int priority)
{
  FbdDevLedPrivate *priv;

  g_return_if_fail (FBD_IS_DEV_LED (self));
  priv = fbd_dev_led_get_instance_private (self);

  priv->priority = priority;
}
