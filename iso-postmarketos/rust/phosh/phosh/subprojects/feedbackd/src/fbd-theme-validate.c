/*
 * Copyright (C) 2022 Guido Günther
 *
 * SPDX-License-Identifier: GPL-3.0+
 */

#define G_LOG_DOMAIN "fbd"

#include "fbd-theme-expander.h"

#include <gio/gio.h>

#define BLURP "- A validator for feedback themes"

G_NORETURN
static void
print_version (void)
{
  g_print ("%s %s " BLURP "\n", g_get_prgname(), FBD_VERSION);
  exit (0);
}

static void
log_handler (const gchar   *log_domain,
             GLogLevelFlags log_level,
             const gchar   *message,
             gpointer       user_data)
{
  g_print ("%s\n", message);
}


int main(int argc, char *argv[])
{
  g_autoptr (GError) err = NULL;
  g_autoptr (GOptionContext) opt_context = NULL;
  g_autoptr (FbdThemeExpander) expander = NULL;
  g_autoptr (FbdFeedbackTheme) theme = NULL;
  g_autofree char *theme_file = NULL;
  const char *compatible = NULL;
  gboolean version = FALSE;
  GStrv args = NULL;
  const char *compatibles[] = { NULL, NULL };
  int ret = EXIT_FAILURE;

  const GOptionEntry options [] = {
    {"version", 0, 0, G_OPTION_ARG_NONE, &version,
     "Show version information", NULL},
    {"compatible", 0, 0, G_OPTION_ARG_STRING, &compatible,
     "The device compatible", NULL},
    { G_OPTION_REMAINING, 0, 0, G_OPTION_ARG_FILENAME_ARRAY, &args, NULL, NULL },
    G_OPTION_ENTRY_NULL,
  };

  opt_context = g_option_context_new ("THEME-FILE " BLURP);
  g_option_context_add_main_entries (opt_context, options, NULL);
  if (!g_option_context_parse (opt_context, &argc, &argv, &err)) {
    g_warning ("%s", err->message);
    g_clear_error (&err);
    return 1;
  }

  if (version) {
    print_version ();
  }

  g_log_set_handler ("fbd-theme-expander", G_LOG_LEVEL_INFO | G_LOG_FLAG_RECURSION,
                     log_handler, NULL);

  if (!args) {
    g_printerr ("%s: No theme file given\n", g_get_prgname ());
    g_printerr ("Try \"%s --help\" for more information.", g_get_prgname ());
    g_printerr ("\n");
    return 1;
  }

  compatibles[0] = compatible;
  theme_file = *args;
  expander = fbd_theme_expander_new (compatibles, NULL, theme_file);
  theme = fbd_theme_expander_load_theme_files (expander, &err);
  if (theme == NULL) {
    g_printerr ("Validation of '%s' failed \n\n", theme_file);
    g_printerr ("error: %s\n\n", err->message);
  } else {
    g_print ("Validation successful.\n");
    ret = EXIT_SUCCESS;
  }

  return ret;
}
