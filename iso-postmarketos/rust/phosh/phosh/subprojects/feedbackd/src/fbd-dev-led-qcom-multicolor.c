/*
 * Copyright (C) 2023 Dylan Van Assche <me@dylanvanassche.be>
 * SPDX-License-Identifier: GPL-3.0+
 */

#define G_LOG_DOMAIN "fbd-dev-led-qcom-multicolor"

#include "fbd-dev-led-priv.h"
#include "fbd-dev-led.h"
#include "fbd-dev-led-qcom.h"
#include "fbd-dev-led-qcom-priv.h"
#include "fbd-dev-led-qcom-multicolor.h"
#include "fbd-enums.h"
#include "fbd-udev.h"

#include <gio/gio.h>


typedef struct _FbdDevLedQcomMulticolor {
  FbdDevLedMulticolor parent;

  FbdDevLedQcom *qcom_led;
} FbdDevLedQcomMulticolor;


G_DEFINE_TYPE (FbdDevLedQcomMulticolor, fbd_dev_led_qcom_multicolor, FBD_TYPE_DEV_LED_MULTICOLOR)


static gboolean
fbd_dev_led_qcom_multicolor_probe (FbdDevLed *led, GError **error)
{
  FbdDevLedQcomMulticolor *self = FBD_DEV_LED_QCOM_MULTICOLOR (led);
  GUdevDevice *dev = fbd_dev_led_get_device (FBD_DEV_LED (led));

  self->qcom_led = FBD_DEV_LED_QCOM (fbd_dev_led_qcom_new (dev, error));
  if (!self->qcom_led)
    return FALSE;

  return FBD_DEV_LED_CLASS (fbd_dev_led_qcom_multicolor_parent_class)->probe(led, error);
}

static gboolean
fbd_dev_led_qcom_multicolor_start_periodic (FbdDevLed *led,
		                            guint      max_brightness_percentage,
					    guint      freq)
{
  FbdDevLedQcomMulticolor *self = FBD_DEV_LED_QCOM_MULTICOLOR (led);

  return fbd_dev_led_start_periodic (FBD_DEV_LED (self->qcom_led), max_brightness_percentage, freq);
}

static void
fbd_dev_led_qcom_multicolor_finalize (GObject *object)
{
  FbdDevLedQcomMulticolor *self = FBD_DEV_LED_QCOM_MULTICOLOR (object);

  g_clear_object (&self->qcom_led);

  G_OBJECT_CLASS (fbd_dev_led_qcom_multicolor_parent_class)->finalize (object);
}

static void
fbd_dev_led_qcom_multicolor_class_init (FbdDevLedQcomMulticolorClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  FbdDevLedClass *fbd_dev_led_class = FBD_DEV_LED_CLASS (klass);

  object_class->finalize = fbd_dev_led_qcom_multicolor_finalize;

  fbd_dev_led_class->probe = fbd_dev_led_qcom_multicolor_probe;
  fbd_dev_led_class->start_periodic = fbd_dev_led_qcom_multicolor_start_periodic;
}


static void
fbd_dev_led_qcom_multicolor_init (FbdDevLedQcomMulticolor *self)
{
  fbd_dev_led_set_priority (FBD_DEV_LED (self), 60);
}


FbdDevLed *
fbd_dev_led_qcom_multicolor_new (GUdevDevice *dev, GError **err)
{
  return g_initable_new (FBD_TYPE_DEV_LED_QCOM_MULTICOLOR, NULL, err, "dev", dev, NULL);
}
