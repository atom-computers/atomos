/*
 * Copyright (C) 2022 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3-or-later
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define GMOBILE_USE_UNSTABLE_API
#include "gmobile.h"

#include <json-glib/json-glib.h>

static void
test_gm_display_panel_parse (void)
{
  const char *json = "                                "
                     "{                                                "
                     " \"name\": \"Oneplus 6T\",                       "
                     " \"x-res\": 1080,                                "
                     " \"y-res\": 2340,                                "
                     " \"border-radius\": 10,                          "
                     " \"width\": 68,                                  "
                     " \"height\": 145,                                "
                     " \"cutouts\" : [                                 "
                     "     {                                           "
                     "        \"name\": \"notch\",                     "
                     "        \"path\": \"M 455 0 V 79 H 625 V 0 Z\"   "
                     "     }                                           "
                     "  ]                                              "
                     "}                                                ";
  g_autoptr (GError) err = NULL;
  g_autoptr (GmDisplayPanel) panel = NULL;
  g_autoptr (GmCutout) cutout = NULL;
  g_autoptr (GArray) radii = NULL;
  g_autofree char *out = NULL;
  GListModel *cutouts;
  const GmRect *bounds;

  panel = gm_display_panel_new_from_data (json, &err);
  g_assert_no_error (err);
  g_assert_nonnull (panel);

  cutouts = gm_display_panel_get_cutouts (panel);
  g_assert_cmpint (g_list_model_get_n_items (cutouts), ==, 1);
  cutout = g_list_model_get_item (cutouts, 0);
  g_assert_nonnull (cutout);
  g_assert_cmpstr (gm_cutout_get_name (cutout), ==, "notch");
  g_assert_cmpstr (gm_cutout_get_path (cutout), ==, "M 455 0 V 79 H 625 V 0 Z");
  bounds = gm_cutout_get_bounds (cutout);
  g_assert_cmpint (bounds->x, ==, 455);
  g_assert_cmpint (bounds->y, ==, 0);
  g_assert_cmpint (bounds->width, ==, 170);
  g_assert_cmpint (bounds->height, ==, 79);

  g_assert_cmpint (gm_display_panel_get_x_res (panel), ==, 1080);
  g_assert_cmpint (gm_display_panel_get_y_res (panel), ==, 2340);
G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  g_assert_cmpint (gm_display_panel_get_border_radius (panel), ==, 10);
G_GNUC_END_IGNORE_DEPRECATIONS
  radii = gm_display_panel_get_corner_radii (panel);
  g_assert_cmpint (radii->len, ==, 4);
  g_assert_cmpint (g_array_index (radii, int, 0), ==, 10);

  g_assert_cmpint (gm_display_panel_get_width (panel), ==, 68);
  g_assert_cmpint (gm_display_panel_get_height (panel), ==, 145);
}


static void
test_gm_display_panel_corner_radii (void)
{
  const char *json = "                                "
                     "{                                                "
                     " \"name\": \"Oneplus 6T\",                       "
                     " \"x-res\": 1080,                                "
                     " \"y-res\": 2340,                                "
                     " \"corner-radii\": [ 10, 11, 12, 13 ],           "
                     " \"width\": 68,                                  "
                     " \"height\": 145                                 "
                     "}                                                ";
  g_autoptr (GError) err = NULL;
  g_autoptr (GmDisplayPanel) panel = NULL;
  g_autoptr (GArray) radii1 = NULL, radii2 = NULL;
  const int *radii;
  g_autofree char *out = NULL;

  panel = gm_display_panel_new_from_data (json, &err);
  g_assert_no_error (err);
  g_assert_nonnull (panel);

  g_assert_cmpint (gm_display_panel_get_x_res (panel), ==, 1080);
  g_assert_cmpint (gm_display_panel_get_y_res (panel), ==, 2340);

G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  g_assert_cmpint (gm_display_panel_get_border_radius (panel), ==, 10);
G_GNUC_END_IGNORE_DEPRECATIONS

  radii = gm_display_panel_get_corner_radii_array (panel);
  g_assert_cmpint (radii[GM_CORNER_POSITION_TOP_LEFT], ==, 10);
  g_assert_cmpint (radii[GM_CORNER_POSITION_TOP_RIGHT], ==, 11);
  g_assert_cmpint (radii[GM_CORNER_POSITION_BOTTOM_RIGHT], ==, 12);
  g_assert_cmpint (radii[GM_CORNER_POSITION_BOTTOM_LEFT], ==, 13);

  radii1 = gm_display_panel_get_corner_radii (panel);
  g_assert_cmpint (g_array_index (radii1, int, GM_CORNER_POSITION_TOP_LEFT), ==, 10);
  g_assert_cmpint (g_array_index (radii1, int, GM_CORNER_POSITION_TOP_RIGHT), ==, 11);
  g_assert_cmpint (g_array_index (radii1, int, GM_CORNER_POSITION_BOTTOM_RIGHT), ==, 12);
  g_assert_cmpint (g_array_index (radii1, int, GM_CORNER_POSITION_BOTTOM_LEFT), ==, 13);

  g_object_get (panel, "corner-radii", &radii2, NULL);
  g_assert_cmpint (g_array_index (radii1, int, GM_CORNER_POSITION_TOP_LEFT), ==, 10);
  g_assert_cmpint (g_array_index (radii1, int, GM_CORNER_POSITION_TOP_RIGHT), ==, 11);
  g_assert_cmpint (g_array_index (radii1, int, GM_CORNER_POSITION_BOTTOM_RIGHT), ==, 12);
  g_assert_cmpint (g_array_index (radii1, int, GM_CORNER_POSITION_BOTTOM_LEFT), ==, 13);

  g_assert_cmpint (gm_display_panel_get_width (panel), ==, 68);
  g_assert_cmpint (gm_display_panel_get_height (panel), ==, 145);

  out = json_gobject_to_data (G_OBJECT (panel), NULL);
  g_assert_nonnull (out);
  g_test_message ("Out: %s", out);
}


gint
main (gint argc, gchar *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/Gm/display-panel/parse", test_gm_display_panel_parse);
  g_test_add_func ("/Gm/display-panel/corner_radii", test_gm_display_panel_corner_radii);

  return g_test_run ();
}
