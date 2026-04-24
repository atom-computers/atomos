/*
 * Copyright (C) 2020 Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 *
 * See https://www.kernel.org/doc/html/latest/input/ff.html
 * and fftest.c from the joystick package.
 */

#define G_LOG_DOMAIN "fbd-dev-vibra"

#include "fbd-dev-vibra.h"

#include <gio/gio.h>

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>

/**
 * SECTION:fbd-dev-vibra
 * @short_description: Haptic motor device interface
 * @Title: FbdDevVibra
 *
 * The #FbdDevVibra is used to interface with haptic motor via the force
 * feedback interface. It currently only supports one id at a time.
 */

enum {
  PROP_0,
  PROP_DEVICE,
  PROP_LAST_PROP,
};
static GParamSpec *props[PROP_LAST_PROP];

typedef enum {
  FBD_DEV_VIBRA_FEATURE_RUMBLE,
  FBD_DEV_VIBRA_FEATURE_PERIODIC,
  FBD_DEV_VIBRA_FEATURE_GAIN,
} FbdDevVibraFeatureFlags;

typedef struct _FbdDevVibra {
  GObject parent;

  GUdevDevice *device;
  gint fd;
  gint id; /* currently used id */

  FbdDevVibraFeatureFlags features;
} FbdDevVibra;

static void initable_iface_init (GInitableIface *iface);

G_DEFINE_TYPE_WITH_CODE (FbdDevVibra, fbd_dev_vibra, G_TYPE_OBJECT,
                         G_IMPLEMENT_INTERFACE (G_TYPE_INITABLE, initable_iface_init));

static void
fbd_dev_vibra_set_property (GObject      *object,
                            guint         property_id,
                            const GValue *value,
                            GParamSpec   *pspec)
{
  FbdDevVibra *self = FBD_DEV_VIBRA (object);

  switch (property_id) {
  case PROP_DEVICE:
    g_clear_object (&self->device);
    self->device = g_value_dup_object (value);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
fbd_dev_vibra_get_property (GObject    *object,
                            guint       property_id,
                            GValue     *value,
                            GParamSpec *pspec)
{
  switch (property_id) {
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}

#define BITS_PER_LONG (8 * sizeof (long))

#define HAS_FEATURE(fbit, a) \
  (a[(fbit/BITS_PER_LONG)] >> ((fbit % BITS_PER_LONG)) & 1)

static gboolean
initable_init (GInitable     *initable,
               GCancellable  *cancellable,
               GError       **error)
{
  FbdDevVibra *self = FBD_DEV_VIBRA (initable);
  const char *filename = g_udev_device_get_device_file (self->device);
  gulong features[1 + FF_MAX/BITS_PER_LONG];
  struct input_event gain = { 0 };

  self->fd = open (filename, O_RDWR | O_NONBLOCK, O_RDWR);
  if (self->fd < 0) {
    g_set_error (error,
                 G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "Unable to open '%s': %s",
                 filename, g_strerror (errno));
    return FALSE;
  }

  if (ioctl (self->fd, EVIOCGBIT(EV_FF, sizeof (features)), features) == -1) {
    g_set_error (error,
                 G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "Unable to probe features of '%s': %s",
                 filename, g_strerror (errno));
    return FALSE;
  }

  if (HAS_FEATURE(FF_RUMBLE, features))
    self->features |= FBD_DEV_VIBRA_FEATURE_RUMBLE;
  else {
    g_set_error (error,
                 G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "No rumble capable vibra device “%s”: %s",
                 filename, g_strerror (errno));
    return FALSE;
  }

  if (HAS_FEATURE(FF_PERIODIC, features))
    self->features |= FBD_DEV_VIBRA_FEATURE_PERIODIC;
  else {
    g_set_error (error,
                 G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "No rumble capable vibra device “%s”: %s",
                 filename, g_strerror (errno));
    return FALSE;
  }

  /* Set gain to 75% if supported */
  if (HAS_FEATURE(FF_GAIN, features)) {
    self->features |= FBD_DEV_VIBRA_FEATURE_GAIN;
    memset(&gain, 0, sizeof(gain));
    gain.type = EV_FF;
    gain.code = FF_GAIN;
    gain.value = 0xC000; /* [0, 0xFFFF]) */

    g_debug("Setting master gain to 75%%");
    if (write(self->fd, &gain, sizeof(gain)) != sizeof(gain)) {
      g_set_error (error,
                 G_FILE_ERROR, G_FILE_ERROR_FAILED,
                 "Unable to set gain of '%s': %s",
                 filename, g_strerror (errno));
    }
  } else {
    g_debug ("Gain unsupported");
  }

  g_debug ("Vibra device at '%s' usable", filename);
  return TRUE;
}

static void
initable_iface_init (GInitableIface *iface)
{
    iface->init = initable_init;
}

static void
fbd_dev_vibra_dispose (GObject *object)
{
  FbdDevVibra *self = FBD_DEV_VIBRA (object);

  g_clear_object (&self->device);

  G_OBJECT_CLASS (fbd_dev_vibra_parent_class)->dispose (object);
}

static void
fbd_dev_vibra_finalize (GObject *object)
{
  FbdDevVibra *self = FBD_DEV_VIBRA (object);

  if (self->fd >= 0) {
    close (self->fd);
    self->fd = -1;
  }

  G_OBJECT_CLASS (fbd_dev_vibra_parent_class)->finalize (object);
}

static void
fbd_dev_vibra_class_init (FbdDevVibraClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->set_property = fbd_dev_vibra_set_property;
  object_class->get_property = fbd_dev_vibra_get_property;

  object_class->dispose = fbd_dev_vibra_dispose;
  object_class->finalize = fbd_dev_vibra_finalize;

  props[PROP_DEVICE] =
    g_param_spec_object (
      "device",
      "Device",
      "The udev device",
      G_UDEV_TYPE_DEVICE,
      G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);
}

static void
fbd_dev_vibra_init (FbdDevVibra *self)
{
  self->id = -1;
}

FbdDevVibra *
fbd_dev_vibra_new (GUdevDevice *device, GError **error)
{
  return FBD_DEV_VIBRA (g_initable_new (FBD_TYPE_DEV_VIBRA,
                                        NULL,
                                        error,
                                        "device", device,
                                        NULL));
}

gboolean
fbd_dev_vibra_rumble (FbdDevVibra *self, double magnitude, guint duration, gboolean upload)
{
  struct input_event event = { 0 };
  struct ff_effect effect = { 0 };

  g_return_val_if_fail (FBD_IS_DEV_VIBRA (self), FALSE);

  memset(&effect, 0, sizeof(effect));
  effect.type = FF_RUMBLE;
  effect.id = -1;
  effect.u.rumble.strong_magnitude = 0xFFFF * magnitude;
  effect.u.rumble.weak_magnitude = 0;
  effect.replay.length = duration;
  effect.replay.delay = 0;

  if (upload) {
    g_debug("Uploading rumbling vibra effect (%d)", self->fd);
    if (ioctl(self->fd, EVIOCSFF, &effect) == -1) {
      g_warning ("Failed to upload rumbling vibra effect: %s", g_strerror (errno));
      return FALSE;
    }
    self->id = effect.id;
  }

  g_debug("Playing rumbling vibra effect id %d", effect.id);
  event.type = EV_FF;
  event.value = 1;
  event.code = self->id;

  if (write (self->fd, (const void*) &event, sizeof (event)) < 0) {
    g_warning ("Failed to play rumbling vibra effect.");
    return FALSE;
  }

  return TRUE;
}

/* TODO: fall back to multiple rumbles when sine not supported */
gboolean
fbd_dev_vibra_periodic (FbdDevVibra *self,
                        guint        duration,
                        double       magnitude,
                        double       fade_in_level,
                        guint        fade_in_time)
{
  struct input_event event;
  struct ff_effect effect = { 0 };

  g_return_val_if_fail (FBD_IS_DEV_VIBRA (self), FALSE);

  effect.type = FF_PERIODIC;
  effect.id = -1;
  effect.u.periodic.waveform = FF_SINE;
  effect.u.periodic.period = 10;
  effect.u.periodic.magnitude = 0x7FFF * magnitude;
  effect.u.periodic.offset = 0;
  effect.u.periodic.phase = 0;
  effect.direction = 0x4000;
  effect.u.periodic.envelope.attack_length = fade_in_time;
  effect.u.periodic.envelope.attack_level = 0x7FFF * fade_in_level;
  effect.u.periodic.envelope.fade_length = 0;
  effect.u.periodic.envelope.fade_level = 0;
  effect.trigger.button = 0;
  effect.trigger.interval = 0;
  effect.replay.length = duration;
  effect.replay.delay = 200;

  g_debug("Uploading periodic effect (%d)", self->fd);
  if (ioctl(self->fd, EVIOCSFF, &effect) == -1) {
    g_warning ("Failed to upload periodic vibra effect: %s", g_strerror (errno));
    return FALSE;
  }

  g_debug("Playing periodic vibra effect id %d", effect.id);
  event.type = EV_FF;
  self->id = event.code = effect.id;
  event.value = 1;

  if (write (self->fd, (const void*) &event, sizeof (event)) < 0) {
    g_warning ("Failed to play rumbling effect.");
    return FALSE;
  }

  return TRUE;
}


gboolean
fbd_dev_vibra_remove_effect (FbdDevVibra *self)
{
  g_return_val_if_fail (FBD_IS_DEV_VIBRA (self), FALSE);

  if (self->id == -1)
    return TRUE;

  g_debug("Erasing vibra effect (%d)", self->fd);
  if (ioctl(self->fd, EVIOCRMFF, self->id) == -1) {
    g_warning  ("Failed to erase vibra effect with id %d: %s", self->id, strerror(errno));
    self->id = -1;
    return FALSE;
  }
  self->id = -1;
  return TRUE;
}


gboolean
fbd_dev_vibra_stop (FbdDevVibra *self)
{
  struct input_event stop = { 0 };

  g_return_val_if_fail (FBD_IS_DEV_VIBRA (self), FALSE);

  if (self->id == -1)
    return TRUE;

  stop.type = EV_FF;
  stop.code = self->id;
  stop.value = 0;

  if (write(self->fd, (const void*) &stop, sizeof(stop)) < 0) {
    g_warning  ("Failed to stop vibra effect with id %d: %s", self->id, strerror(errno));
    return FALSE;
  }

  return fbd_dev_vibra_remove_effect (self);
}

GUdevDevice *
fbd_dev_vibra_get_device (FbdDevVibra *self)
{
  g_return_val_if_fail (FBD_IS_DEV_VIBRA (self), FALSE);

  return self->device;
}

/**
 * fbd_dev_vibra_is_busy:
 * @self: The vibra device
 *
 * Check whether the device is currently in used
 *
 * Returns: `TRUE` when the device is in use, otherwise `FALSE`
 */
gboolean
fbd_dev_vibra_is_busy (FbdDevVibra *self)
{
  if (self == NULL)
    return FALSE;

  g_return_val_if_fail (FBD_IS_DEV_VIBRA (self), TRUE);

  return self->id != -1;
}
