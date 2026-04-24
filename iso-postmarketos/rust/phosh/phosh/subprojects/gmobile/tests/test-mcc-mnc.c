/*
 * Copyright (C) 2022 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3-or-later
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#include "gio/gio.h"
#define GMOBILE_USE_UNSTABLE_API
#include "gmobile.h"


static void
test_country_code (void)
{
  const char *country_code;
  g_autoptr (GError) err = NULL;

  country_code = gm_mcc_to_iso ("228", &err);
  g_assert_no_error (err);
  g_assert_cmpstr (country_code, ==, "CH");

  country_code = gm_mcc_to_iso ("", &err);
  g_assert_null (country_code);
  g_assert_error (err, GM_ERROR, G_IO_ERROR_NOT_FOUND);

  g_clear_error (&err);
  country_code = gm_mcc_to_iso (NULL, &err);
  g_assert_null (country_code);
  g_assert_error (err, GM_ERROR, G_IO_ERROR_NOT_FOUND);

  g_clear_error (&err);
  country_code = gm_mcc_to_iso ("abc", &err);
  g_assert_null (country_code);
  g_assert_error (err, GM_ERROR, G_IO_ERROR_NOT_FOUND);
}


gint
main (gint argc, gchar *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/Gm/mcc-mnc/country-code", test_country_code);

  return g_test_run ();
}
