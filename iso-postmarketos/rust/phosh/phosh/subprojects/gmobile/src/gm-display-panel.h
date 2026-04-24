/*
 * Copyright (C) 2022-2023 The Phosh Developers
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#pragma once

#include <glib-object.h>
#include <gio/gio.h>

G_BEGIN_DECLS

typedef enum {
  GM_CORNER_POSITION_TOP_LEFT = 0,
  GM_CORNER_POSITION_TOP_RIGHT = 1,
  GM_CORNER_POSITION_BOTTOM_RIGHT = 2,
  GM_CORNER_POSITION_BOTTOM_LEFT = 3,
} GmCornerPosition;

#define GM_TYPE_DISPLAY_PANEL (gm_display_panel_get_type ())

G_DECLARE_FINAL_TYPE (GmDisplayPanel, gm_display_panel, GM, DISPLAY_PANEL, GObject)

GmDisplayPanel     *gm_display_panel_new (void);
GmDisplayPanel     *gm_display_panel_new_from_data (const gchar *data, GError **error);
GmDisplayPanel     *gm_display_panel_new_from_resource (const char *resource_name, GError **error);
const char         *gm_display_panel_get_name (GmDisplayPanel *self);
GListModel         *gm_display_panel_get_cutouts (GmDisplayPanel *self);
int                 gm_display_panel_get_x_res (GmDisplayPanel *self);
int                 gm_display_panel_get_y_res (GmDisplayPanel *self);
GLIB_DEPRECATED
int                 gm_display_panel_get_border_radius (GmDisplayPanel *self);
const int *         gm_display_panel_get_corner_radii_array (GmDisplayPanel *self);
GArray *            gm_display_panel_get_corner_radii (GmDisplayPanel *self);
int                 gm_display_panel_get_width (GmDisplayPanel *self);
int                 gm_display_panel_get_height (GmDisplayPanel *self);

G_END_DECLS
