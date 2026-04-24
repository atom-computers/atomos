/*
 * Copyright (C) 2022 Guido Günther
 *
 * SPDX-License-Identifier: GPL-3.0+
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-theme-expander"

#include "fbd.h"
#include "fbd-feedback-theme.h"
#include "fbd-theme-expander.h"

#define DEFAULT_THEME_NAME  "default"
#define DEVICE_THEME_NAME   "$device"

#define MAX_THEME_DEPTH 10

/**
 * SECTION:theme-expander
 * @short_description: Feedback theme expander
 * @Title: FbdThemeExpander
 *
 * The theme expander reads themes from disks and expands references
 * to other themes
 */

enum {
  PROP_0,
  PROP_THEME_NAME,
  PROP_THEME_FILE,
  PROP_COMPATIBLES,
  PROP_LAST_PROP
};
static GParamSpec *props[PROP_LAST_PROP];

struct _FbdThemeExpander {
  GObject    parent;

  char      *theme_name;
  char      *theme_file;
  gboolean   device_theme_loaded;
  GStrv      compatibles;
};
G_DEFINE_TYPE (FbdThemeExpander, fbd_theme_expander, G_TYPE_OBJECT)


static void
fbd_theme_expander_set_compatibles (FbdThemeExpander *self, const char * const * compatibles)
{
  g_return_if_fail (FBD_IS_THEME_EXPANDER (self));

  g_strfreev (self->compatibles);
  self->compatibles = g_strdupv ((GStrv)compatibles);

  /* Make sure we reload the device theme */
  self->device_theme_loaded = FALSE;
}

static void
fbd_theme_expander_set_theme_name (FbdThemeExpander *self, const char *theme_name)
{
  g_return_if_fail (FBD_IS_THEME_EXPANDER (self));

  g_free (self->theme_name);
  if (theme_name)
    self->theme_name = g_strdup (theme_name);
  else
    self->theme_name = g_strdup (DEFAULT_THEME_NAME);

  /* Make sure we reload the device theme */
  self->device_theme_loaded = FALSE;
}

static void
fbd_theme_expander_set_theme_file (FbdThemeExpander *self, const char *theme_file)
{
  g_return_if_fail (FBD_IS_THEME_EXPANDER (self));

  g_free (self->theme_file);
  self->theme_file = g_strdup (theme_file);

  /* Make sure we reload the device theme */
  self->device_theme_loaded = FALSE;
}


static char *
fbd_theme_expander_find_theme_in_xdg_data (const char *theme_name)
{
  const char * const *xdg_data_dirs = g_get_system_data_dirs ();
  g_autofree char *theme_file_name = g_strconcat (theme_name, ".json", NULL);

  for (int i = 0; xdg_data_dirs[i] != NULL; i++) {
    g_autofree char *theme_path = NULL;

    theme_path = g_build_filename (xdg_data_dirs[i], "feedbackd", "themes",
                                   theme_file_name, NULL);
    g_debug ("Looking for theme file at %s", theme_path);

    /* Check if file exist */
    if (g_file_test (theme_path, (G_FILE_TEST_EXISTS))) {
      g_info ("Loading theme file at '%s'", theme_path);
      return g_steal_pointer (&theme_path);
    }
  }
  return NULL;
}


static char *
fbd_theme_expander_find_device_theme_path (FbdThemeExpander *self, const char *theme_name)
{
  /* Device specific lookup only for default theme */
  if (g_str_equal (theme_name, DEVICE_THEME_NAME) == FALSE &&
      g_str_equal (theme_name, DEFAULT_THEME_NAME) == FALSE) {
    return NULL;
  }

  if (self->device_theme_loaded)
    return NULL;

  self->device_theme_loaded = TRUE;

  /* no compatibles found */
  if (self->compatibles == NULL)
    return NULL;

  for (int i = 0; i < g_strv_length (self->compatibles); i++) {
    const char *compatible = self->compatibles[i];
    g_autofree char *theme_path = NULL;

    theme_path = fbd_theme_expander_find_theme_in_xdg_data (compatible);
    if (theme_path) {
      g_debug ("Loading themefile for compatible '%s' at: %s", compatible, theme_path);
      return g_steal_pointer (&theme_path);
    }
  }

  g_debug ("No device theme found");
  return NULL;
}


static char *
fbd_theme_expander_find_user_theme_path (const char *theme_name)
{
  g_autofree char *filename = g_strdup_printf ("%s.json", theme_name);
  g_autofree char *user_config_path = NULL;

  user_config_path = g_build_filename (g_get_user_config_dir (), "feedbackd",
                                       "themes", filename, NULL);
  if (g_file_test (user_config_path, (G_FILE_TEST_EXISTS))) {
    g_info ("Found theme file at: %s", user_config_path);
    return g_steal_pointer (&user_config_path);
  }

  g_debug ("No user theme found for '%s'", theme_name);
  return NULL;
}


static char *
fbd_theme_expander_find_theme_path (FbdThemeExpander *self, const char *theme_name)
{
  g_autofree char *file_name = NULL;
  char *theme_path;

  g_assert (theme_name);

  theme_path = fbd_theme_expander_find_user_theme_path (theme_name);
  if (theme_path)
    return theme_path;

  theme_path = fbd_theme_expander_find_device_theme_path (self, theme_name);
  if (theme_path)
    return theme_path;

  if (g_str_equal (theme_name, DEFAULT_THEME_NAME) == FALSE)
    g_critical ("Theme '%s' not found, falling back to default theme", theme_name);

  theme_path = fbd_theme_expander_find_theme_in_xdg_data (DEFAULT_THEME_NAME);
  if (theme_path)
    return theme_path;

  /* Last resort is shipped default config */
  file_name = g_strdup_printf ("%s.json", theme_name);
  g_info ("Using theme_file: %s", file_name);
  return g_build_filename (FEEDBACKD_THEME_DIR, file_name, NULL);
}


static void
fbd_theme_expander_set_property (GObject      *object,
                                 guint         property_id,
                                 const GValue *value,
                                 GParamSpec   *pspec)
{
  FbdThemeExpander *self = FBD_THEME_EXPANDER (object);

  switch (property_id) {
  case PROP_THEME_NAME:
    fbd_theme_expander_set_theme_name (self, g_value_get_string (value));
    break;
  case PROP_THEME_FILE:
    fbd_theme_expander_set_theme_file (self, g_value_get_string (value));
    break;
  case PROP_COMPATIBLES:
    fbd_theme_expander_set_compatibles (self, g_value_get_boxed (value));
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
fbd_theme_expander_get_property (GObject    *object,
                                 guint       property_id,
                                 GValue     *value,
                                 GParamSpec *pspec)
{
  FbdThemeExpander *self = FBD_THEME_EXPANDER (object);

  switch (property_id) {
  case PROP_THEME_NAME:
    g_value_set_string (value, fbd_theme_expander_get_theme_name (self));
    break;
  case PROP_THEME_FILE:
    g_value_set_string (value, fbd_theme_expander_get_theme_file (self));
    break;
  case PROP_COMPATIBLES:
    g_value_set_boxed (value, fbd_theme_expander_get_compatibles (self));
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
fbd_theme_expander_finalize (GObject *object)
{
  FbdThemeExpander *self = FBD_THEME_EXPANDER(object);

  g_clear_pointer (&self->theme_name, g_free);
  g_clear_pointer (&self->theme_file, g_free);
  g_clear_pointer (&self->compatibles, g_strfreev);

  G_OBJECT_CLASS (fbd_theme_expander_parent_class)->finalize (object);
}


static void
fbd_theme_expander_class_init (FbdThemeExpanderClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->get_property = fbd_theme_expander_get_property;
  object_class->set_property = fbd_theme_expander_set_property;
  object_class->finalize = fbd_theme_expander_finalize;

  /**
   * FbdThemeExpander:theme-name:
   *
   * Specifies the theme to expand. Assumes `default` if unset.
   *
   * The `compatibles` defines which device specific theme bits are loaded.
   */
  props[PROP_THEME_NAME] =
    g_param_spec_string ("theme-name", "", "",
                         DEFAULT_THEME_NAME,
                         G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_EXPLICIT_NOTIFY |
                         G_PARAM_STATIC_STRINGS);
  /**
   * FbdThemeExpander:theme-file:
   *
   * Specifies the theme-file to load an expand. Takes preference over `theme`.
   */
  props[PROP_THEME_FILE] =
    g_param_spec_string ("theme-file", "", "",
                         NULL,
                         G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_EXPLICIT_NOTIFY |
                         G_PARAM_STATIC_STRINGS);
  /**
   * FbdThemeExpander:compatibles:
   *
   * Specifies the device types this device is compatible with.  The
   * device compatbiles to look for. When unset the value is retrieved
   * from /sysfs.
   *
   * The `compatibles` defines which device specific theme bits are loaded.
   */
  props[PROP_COMPATIBLES] =
    g_param_spec_boxed ("compatibles", "", "",
                        G_TYPE_STRV,
                        G_PARAM_CONSTRUCT_ONLY | G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);
}


static void
fbd_theme_expander_init (FbdThemeExpander *self)
{
}


FbdThemeExpander *
fbd_theme_expander_new (const char * const *compatibles,
                        const char *theme_name,
                        const char *theme_file)
{
  return FBD_THEME_EXPANDER (g_object_new (FBD_TYPE_THEME_EXPANDER,
                                           "theme-name", theme_name,
                                           "theme-file", theme_file,
                                           "compatibles", compatibles,
                                           NULL));
}


static void
update_theme (gpointer data, gpointer user_data)
{
  FbdFeedbackTheme *theme = FBD_FEEDBACK_THEME (data);
  FbdFeedbackTheme *merged = FBD_FEEDBACK_THEME (user_data);

  g_assert (FBD_IS_FEEDBACK_THEME (theme));
  g_assert (FBD_IS_FEEDBACK_THEME (merged));

  fbd_feedback_theme_update (merged, theme);
}


/**
 * fbd_theme_expander_load_theme_files:
 * @self: The theme expander
 * @err: return location for error or %NULL
 *
 * Parses a theme recursively taking the theme's `parent-name` relations into
 * account as well as the expander's list of `compatibles`.
 *
 * Returns: (transfer full)(allow-none): The parsed theme or %NULL on error
 */
FbdFeedbackTheme *
fbd_theme_expander_load_theme_files (FbdThemeExpander *self, GError **err)
{
  g_autoqueue (FbdFeedbackTheme) queue = g_queue_new ();
  g_autoptr (FbdFeedbackTheme) merged = fbd_feedback_theme_new ("merged-theme");
  g_autoptr (FbdFeedbackTheme) theme = NULL;
  g_autofree char *theme_file = NULL;
  guint len = 0;

  g_return_val_if_fail (FBD_IS_THEME_EXPANDER (self), NULL);
  g_return_val_if_fail (err == NULL || *err == NULL, NULL);

  if (self->theme_file) {
    theme_file = g_strdup (self->theme_file);
  } else {
    theme_file = fbd_theme_expander_find_theme_path (self, self->theme_name);
    if (g_strcmp0 (self->theme_file, theme_file)) {
      self->theme_file = g_steal_pointer (&theme_file);
      g_object_notify_by_pspec (G_OBJECT (self), props[PROP_THEME_FILE]);
    }
  }

  g_info ("Loading theme file at '%s'", self->theme_file);
  theme = fbd_feedback_theme_new_from_file (self->theme_file, err);
  if (theme == NULL)
      return NULL;

  /* Build a list of themes */
  while (TRUE) {
    g_autofree char *parent_path = NULL;
    const char *parent_name, *theme_name;

    if (len > MAX_THEME_DEPTH) {
      g_set_error (err, fbd_error_quark(), FBD_ERROR_THEME_EXPAND, "Theme depth exceeded");
      return NULL;
    }

    theme_name = fbd_feedback_theme_get_name (theme);
    if (theme_name == NULL || theme_name[0] == '\0') {
      g_set_error (err, fbd_error_quark(), FBD_ERROR_THEME_EXPAND,
                   "Theme name of %s can't be empty", self->theme_file);
      return NULL;
    }

    parent_name = fbd_feedback_theme_get_parent_name (theme);

    if (parent_name &&
        g_str_equal (fbd_feedback_theme_get_name (theme), DEFAULT_THEME_NAME)) {
      g_set_error (err, fbd_error_quark(), FBD_ERROR_THEME_EXPAND,
                   "Default theme can't specify a parent");
      return NULL;
    }

    parent_name = fbd_feedback_theme_get_parent_name (theme);

    g_queue_push_head (queue, g_steal_pointer (&theme));

    if (parent_name == NULL)
      break;

    parent_path = fbd_theme_expander_find_theme_path (self, parent_name);
    theme = fbd_feedback_theme_new_from_file (parent_path, err);
    if (theme == NULL)
      return NULL;

    len++;
  }

  /* Merge themes bottom to top */
  g_queue_foreach (queue, update_theme, merged);

  fbd_feedback_theme_set_name (merged, self->theme_name);
  return g_steal_pointer (&merged);
}

const char *
fbd_theme_expander_get_theme_name (FbdThemeExpander *self)
{
  g_return_val_if_fail (FBD_IS_THEME_EXPANDER (self), NULL);

  return self->theme_name;

}

const char *
fbd_theme_expander_get_theme_file (FbdThemeExpander *self)
{
  g_return_val_if_fail (FBD_IS_THEME_EXPANDER (self), NULL);

  return self->theme_file;
}

const char * const *
fbd_theme_expander_get_compatibles (FbdThemeExpander *self)
{
  g_return_val_if_fail (FBD_IS_THEME_EXPANDER (self), NULL);

  return (const char * const*)self->compatibles;
}
