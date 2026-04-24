/*
 * Copyright (C) 2022 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3-or-later
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

/* This examples launches phosh and phoc emulating the display
   of the given device tree compatible */

#define GMOBILE_USE_UNSTABLE_API
#include "gmobile.h"

#include <glib-unix.h>
#include <glib/gstdio.h>

#include <gio/gio.h>
#include <glib/gprintf.h>

#include <math.h>

#define PHOC_BIN "phoc"
#define PHOSH_BIN LIBEXECDIR "/phosh"

GMainLoop   *loop;
GSubprocess *phoc;
GDBusProxy  *proxy;

G_NORETURN static void
print_version (void)
{
  g_printf ("gm-emu-device--panel %s\n", GM_VERSION);
  exit (0);
}


static void
quit(void)
{
  g_autoptr (GError) err = NULL;
  gboolean success;

  g_subprocess_send_signal (phoc, SIGTERM);

  success = g_subprocess_wait (phoc, NULL, &err);
  if (!success)
    g_warning ("Failed to terminate phoc: %s", err->message);

  g_main_loop_quit (loop);
}


static gboolean
on_shutdown_signal (gpointer unused)
{
  quit();

  return G_SOURCE_REMOVE;
}


static char *
write_phoc_ini (GmDisplayPanel *panel, gdouble scale, gboolean headless)
{
  g_autoptr (GError) err = NULL;
  g_autoptr (GString) content = g_string_new ("");
  g_autofree char *phoc_ini = NULL;
  int xres = gm_display_panel_get_x_res (panel);
  int yres = gm_display_panel_get_y_res (panel);
  const char *output = headless ? "HEADLESS" : "WL";
  int fd;

  g_string_append_printf (content, "[output:%s-1]\n", output);
  g_string_append_printf (content, "mode = %dx%d\n", xres, yres);
  g_string_append_printf (content, "scale = %.2f\n", scale);
  fd = g_file_open_tmp ("phoc_XXXXXX.ini", &phoc_ini, &err);
  if (fd < 0) {
    g_critical ("Failed to open %s: %s", phoc_ini, err->message);
    return NULL;
  }

  if (write (fd, content->str, strlen (content->str)) < 0) {
    g_critical ("Failed to write %s", strerror (errno));
    return NULL;
  }

  return g_steal_pointer (&phoc_ini);
}


/* Auto scale calculation copied verbatim from phoc */

#define MIN_WIDTH       360.0
#define MIN_HEIGHT      540.0
#define MAX_DPI_TARGET  180.0
#define INCH_IN_MM      25.4

static float
phoc_utils_compute_scale (int32_t phys_width, int32_t phys_height,
                          int32_t width, int32_t height)
{
  float dpi, max_scale, scale;

  /* Ensure scaled resolution won't be inferior to minimum values */
  max_scale = fminf (height / MIN_HEIGHT, width / MIN_WIDTH);

  /*
   * Round the maximum scale to a sensible value:
   *   - never use a scaling factor < 1
   *   - round to the lower 0.25 step below 2
   *   - round to the lower 0.5 step between 2 and 3
   *   - round to the lower integer value over 3
   */
  if (max_scale < 1) {
    max_scale = 1;
  } else if (max_scale < 2) {
    max_scale = 0.25 * floorf (max_scale / 0.25);
  } else if (max_scale < 3) {
    max_scale = 0.5 * floorf (max_scale / 0.5);
  } else {
    max_scale = floorf (max_scale);
  }

  dpi = (float) height / (float) phys_height * INCH_IN_MM;
  scale = fminf (ceilf (dpi / MAX_DPI_TARGET), max_scale);

  return scale;
}


static void
on_screenshot_proxy_ready (GObject *source_object, GAsyncResult *res, gpointer user_data)
{
  g_autoptr (GError) err = NULL;
  g_autoptr (GVariant) result = NULL;
  const char *filename, *template = user_data;
  gboolean success;

  g_assert (template);
  proxy = g_dbus_proxy_new_for_bus_finish (res, &err);
  if (!proxy) {
    g_critical ("Failed to get screensaver proxy: %s", err->message);
    if (!g_error_matches (err, G_IO_ERROR, G_IO_ERROR_CANCELLED))
      quit ();
    return;
  }

  result = g_dbus_proxy_call_sync (proxy, "Screenshot",
                                   g_variant_new ("(bbs)",
                                                  FALSE,
                                                  FALSE,
                                                  template),
                                   G_DBUS_CALL_FLAGS_NONE,
                                   -1,
                                   NULL,
                                   &err);
  if (!result) {
    g_warning ("Failed to take screenshot: %s", err->message);
  } else {
    g_variant_get (result, "(b&s)", &success, &filename);
    g_print ("Took screenshot '%s'", filename);
  }

  quit ();
}


static void
on_timeout (gpointer user_data)
{
  char *template = user_data;

  g_dbus_proxy_new_for_bus (G_BUS_TYPE_SESSION,
                            G_DBUS_PROXY_FLAGS_NONE,
                            NULL,
                            "org.gnome.Shell.Screenshot",
                            "/org/gnome/Shell/Screenshot",
                            "org.gnome.Shell.Screenshot",
                            NULL,
                            on_screenshot_proxy_ready,
                            template);
}



int
main (int argc, char **argv)
{
  g_autoptr (GOptionContext) opt_context = NULL;
  gboolean version = FALSE, headless = FALSE;
  g_autoptr (GError) err = NULL;
  g_autoptr (GmDeviceInfo) info = NULL;
  g_auto (GStrv) compatibles = NULL;
  GmDisplayPanel *panel = NULL;
  GStrv compatibles_opt = NULL;
  char *screenshot_name = NULL;
  g_autofree char *phoc_ini = NULL;
  g_autoptr (GSubprocessLauncher) phoc_launcher = NULL;
  double scale_opt = -1.0;
  const char *phosh_bin, *phoc_bin, *backend;

  const GOptionEntry options [] = {
    {"compatible", 'c', 0, G_OPTION_ARG_STRING_ARRAY, &compatibles_opt,
     "Device tree compatibles to use for panel lookup ", NULL},
    {"scale", 's', 0, G_OPTION_ARG_DOUBLE, &scale_opt,
     "The display scale", NULL },
    {"headless", 'H', 0, G_OPTION_ARG_NONE, &headless,
     "Use headless backend", NULL },
    {"screenshot", 'S', 0, G_OPTION_ARG_FILENAME, &screenshot_name,
     "Take screenshot with the given name", NULL},
    {"version", 0, 0, G_OPTION_ARG_NONE, &version,
     "Show version information", NULL},
    { NULL, 0, 0, G_OPTION_ARG_NONE, NULL, NULL, NULL }
  };

  opt_context = g_option_context_new ("- emulate display panel");
  g_option_context_add_main_entries (opt_context, options, NULL);
  if (!g_option_context_parse (opt_context, &argc, &argv, &err)) {
    g_warning ("%s", err->message);
    g_clear_error (&err);
    return EXIT_FAILURE;
  }

  if (version)
    print_version ();

  if (compatibles_opt && compatibles_opt[0]) {
    compatibles = g_strdupv (compatibles_opt);
  } else {
    compatibles = gm_device_tree_get_compatibles (NULL, &err);
    if (compatibles == NULL) {
      g_critical ("Failed to get compatibles: %s", err->message);
      return EXIT_FAILURE;
    }
  }

  info = gm_device_info_new ((const char *const *)compatibles);
  panel = gm_device_info_get_display_panel (info);
  if (panel == NULL) {
    g_critical ("Failed to find any panel");
    return EXIT_FAILURE;
  }

  if (scale_opt < 0) {
    scale_opt = phoc_utils_compute_scale (gm_display_panel_get_width (panel),
                                          gm_display_panel_get_height (panel),
                                          gm_display_panel_get_x_res (panel),
                                          gm_display_panel_get_y_res (panel));
    g_message ("Using scale %f", scale_opt);
  }

  phoc_ini = write_phoc_ini (panel, scale_opt, headless);
  if (!phoc_ini)
    return EXIT_FAILURE;

  g_message ("Using %s as phoc config", phoc_ini);

  backend = headless ? "headless" : "wayland";
  phosh_bin = g_getenv ("PHOSH_BIN") ?: PHOSH_BIN;
  phoc_bin = g_getenv ("PHOC_BIN") ?: PHOC_BIN;
  phoc_launcher = g_subprocess_launcher_new (G_SUBPROCESS_FLAGS_SEARCH_PATH_FROM_ENVP);
  g_subprocess_launcher_set_environ (phoc_launcher, NULL);
  g_subprocess_launcher_setenv (phoc_launcher, "GSETTINGS_BACKEND", "memory", TRUE);
  g_subprocess_launcher_setenv (phoc_launcher, "PHOC_DEBUG", "cutouts,fake-builtin", TRUE);
  g_subprocess_launcher_setenv (phoc_launcher, "PHOSH_DEBUG", "fake-builtin", TRUE);
  g_subprocess_launcher_setenv (phoc_launcher, "G_MESSAGES_DEBUG", "phosh-layout-manager", TRUE);
  if (compatibles_opt && compatibles_opt[0]) {
    g_autofree char *opt = g_strjoinv (",", compatibles_opt);
    g_subprocess_launcher_setenv (phoc_launcher, "GMOBILE_DT_COMPATIBLES", opt, TRUE);
  }
  g_subprocess_launcher_setenv (phoc_launcher, "WLR_BACKENDS", backend, TRUE);

  phoc = g_subprocess_launcher_spawnv (phoc_launcher,
                                       (const char * const [])
                                       { phoc_bin, "-C", phoc_ini,
                                         "-E", phosh_bin, NULL },
                                       &err);
  g_unix_signal_add (SIGTERM, on_shutdown_signal, NULL);
  g_unix_signal_add (SIGINT, on_shutdown_signal, NULL);

  if (screenshot_name)
    g_timeout_add_seconds_once (2, on_timeout, screenshot_name);

  loop = g_main_loop_new (NULL, FALSE);

  g_message  ("Launching phosh and phoc, hit CTRL-C to quit");
  g_main_loop_run (loop);

  g_unlink (phoc_ini);

  g_clear_object (&phoc);
  g_main_loop_unref (loop);

  return EXIT_SUCCESS;
}
