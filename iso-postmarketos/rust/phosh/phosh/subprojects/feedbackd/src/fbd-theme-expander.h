/*
 * Copyright (C) 2022 Guido Günther
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#pragma once

#include "fbd-feedback-theme.h"

#include <glib-object.h>

G_BEGIN_DECLS

#define FBD_TYPE_THEME_EXPANDER (fbd_theme_expander_get_type ())

G_DECLARE_FINAL_TYPE (FbdThemeExpander, fbd_theme_expander, FBD, THEME_EXPANDER, GObject)


FbdThemeExpander   *fbd_theme_expander_new (const char * const *compatibles,
                                            const char *theme_name,
                                            const char *theme_file);
FbdFeedbackTheme   *fbd_theme_expander_load_theme_files (FbdThemeExpander  *self,
                                                         GError           **err);
const char         *fbd_theme_expander_get_theme_name (FbdThemeExpander *self);
const char         *fbd_theme_expander_get_theme_file (FbdThemeExpander *self);
const char * const *fbd_theme_expander_get_compatibles (FbdThemeExpander *self);

G_END_DECLS
