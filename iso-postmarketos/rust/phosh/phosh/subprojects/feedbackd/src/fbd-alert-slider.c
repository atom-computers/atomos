/*
 * Copyright (C) 2024-2025 Phosh.mobi e.V.
 *
 * SPDX-License-Identifier: GPL-3.0+
 *
 * Heavily based on a shell script posted to the phosh matrix channel
 * by isyourbrain foss
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-alert-slider"

#define LIBFEEDBACK_USE_UNSTABLE_API
#include "libfeedback.h"

#include "fbd.h"

#include <gudev/gudev.h>

#include <glib.h>
#include <gio/gio.h>

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/ioctl.h>

#include <linux/input.h>

#define BITS_PER_LONG (sizeof(long) * 8)
#define NBITS(x) ((((x) - 1) / BITS_PER_LONG) + 1)
#define OFF(x)  ((x) % BITS_PER_LONG)
#define BIT(x)  (1UL << OFF (x))
#define LONG(x) ((x) / BITS_PER_LONG)
#define test_bit(bit, array)    ((array[LONG (bit)] >> OFF (bit)) & 1)

typedef enum {
  FBD_ALERT_SLIDER_STATE_SILENT = 0,
  FBD_ALERT_SLIDER_STATE_QUIET = 1,
  FBD_ALERT_SLIDER_STATE_FULL = 2,
} FbdAlertSliderState;

GSettings *settings = NULL;

static void
set_level (FbdAlertSliderState state, gboolean silent)
{
  const char *profile;

  switch (state) {
  case FBD_ALERT_SLIDER_STATE_SILENT:
    profile = "silent";
    break;
  case FBD_ALERT_SLIDER_STATE_QUIET:
    profile = "quiet";
    break;
  case FBD_ALERT_SLIDER_STATE_FULL:
    profile = "full";
    break;
  default:
    g_return_if_reached ();
  }

  g_debug ("Setting profile to %s", profile);
  lfb_set_feedback_profile (profile);

  if (!silent) {
    g_autoptr (LfbEvent) event = lfb_event_new ("button-pressed");

    lfb_event_set_important (event, TRUE);
    lfb_event_set_feedback_profile (event, "quiet");
    lfb_event_trigger_feedback (event, NULL);
  }
}


static int
get_initial_value (int fd, int axis)
{
  int abs[6] = {0};

  ioctl (fd, EVIOCGABS (axis), abs);
  return abs[0];
}


static int
probe (FbdAlertSliderState *initial)
{
  GList *l;
  g_autolist (GUdevClient) devices = NULL;
  g_autoptr (GUdevClient) client = NULL;
  unsigned int code;
  int version, fd, value = 0;
  char name[256] = "Unknown";
  unsigned long bit[EV_MAX][NBITS (KEY_MAX)];
  const char *device_file = NULL;
  const char * const subsystems[] = { "input", NULL };

  client = g_udev_client_new (subsystems);
  devices = g_udev_client_query_by_subsystem (client, "input");

  for (l = devices; l != NULL; l = l->next) {
    GUdevDevice *dev = l->data;

    if (!g_strcmp0 (g_udev_device_get_property (dev, FEEDBACKD_UDEV_ATTR), "alert-slider")) {
      device_file = g_udev_device_get_device_file (dev);
      g_debug ("Found alert slider device: %s", device_file);
      break;
    }
  }

  if (!device_file) {
    g_debug ("No matching device found");
    return -ENOENT;
  }

  if ((fd = open (device_file, O_RDONLY)) < 0) {
    g_warning ("Failed to open alert slider device: %s", strerror (errno));
    return -1;
  }

  if (ioctl (fd, EVIOCGVERSION, &version)) {
    g_warning ("Can't get version %s", strerror (errno));
    return -1;
  }
  g_debug ("Input driver version: %d.%d.%d", version >> 16, (version >> 8) & 0xff, version & 0xff);

  ioctl (fd, EVIOCGNAME (sizeof(name)), name);
  g_debug ("Input device name: '%s'", name);
  if (g_strcmp0 (name, "Alert slider")) {
    g_critical ("Not an alert slider but '%s'", name);
    return -1;
  }

  memset (bit, 0, sizeof(bit));
  ioctl (fd, EVIOCGBIT (0, EV_MAX), bit[0]);

  if (test_bit (EV_ABS, bit[0])) {
    ioctl (fd, EVIOCGBIT (EV_ABS, KEY_MAX), bit[EV_ABS]);
    for (code = 0; code < KEY_MAX; code++) {
      if (test_bit (code, bit[EV_ABS])) {
        value = get_initial_value (fd, code);
        break;
      }
    }
  } else {
    g_critical ("Device doesn't support EV_ABS");
    return -1;
  }

  if (fd >= 0) {
    g_debug ("Initial value: %d", value);
    *initial = value;
  }
  return fd;
}


static gboolean
on_input_ready (GIOChannel *source, GIOCondition cond, gpointer unused)
{
  GIOError status;
  struct input_event ev[64];
  gsize rd;

  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    status = g_io_channel_read (source, (char *)ev, sizeof(ev), &rd /*, &err */);
  G_GNUC_END_IGNORE_DEPRECATIONS
  if (status != G_IO_ERROR_NONE ) {
    g_warning ("Failed to read event: %d", status);
    return TRUE;
  }

  if (rd < sizeof(struct input_event)) {
    g_warning ("Expected %d bytes, got %zd", (int) sizeof(struct input_event), rd);
    return TRUE;
  }

  for (int i = 0; i < rd / sizeof(struct input_event); i++) {
    unsigned int type, code;

    type = ev[i].type;
    code = ev[i].code;

    if (type == EV_SYN)
      continue;

    if (type != EV_ABS || code != 34) {
      g_warning ("Unexpected event %d / %d", type, code);
      continue;
    }

    g_debug ("Event: time %ld.%06ld, value: %d",
             ev[i].input_event_sec,
             ev[i].input_event_usec,
             ev[i].value);
    set_level (ev[i].value, FALSE);
  }

  return TRUE;
}


int
main (int argc, char *argv[])
{
  g_autoptr (GError) err = NULL;
  g_autoptr (GOptionContext) opt_context = NULL;
  g_autoptr (GIOChannel) input = NULL;
  g_autoptr (GMainLoop) loop = NULL;
  FbdAlertSliderState state = 0;
  int fd;
  const GOptionEntry options [] = {
    { NULL, 0, 0, G_OPTION_ARG_NONE, NULL, NULL, NULL }
  };

  opt_context = g_option_context_new ("- support alert slider on OnePlus 6(T)");
  g_option_context_add_main_entries (opt_context, options, NULL);
  if (!g_option_context_parse (opt_context, &argc, &argv, &err)) {
    g_print ("%s", err->message);
    return 1;
  }

  fd = probe (&state);
  if (fd < 0) {
    if (fd == -ENOENT)
      return EXIT_SUCCESS;
    else
      return EXIT_FAILURE;
  }

  if (!lfb_init ("org.sigxcpu.FbdAlertSlider", &err)) {
    g_print ("Failed to init libfeedback: %s\n", err->message);
    return 1;
  }

  set_level (state, TRUE);

  input = g_io_channel_unix_new (fd);
  g_io_channel_set_encoding (input, NULL, NULL);
  g_io_add_watch (input, G_IO_IN | G_IO_ERR | G_IO_HUP, on_input_ready, NULL);

  loop = g_main_loop_new (NULL, FALSE);
  g_main_loop_run (loop);

  g_clear_object (&settings);

  return 0;
}
