/*
 * Copyright (C) 2025 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#include "libfeedback.h"
#include <gio/gio.h>

/* unpaired uninit not raise any criticals */
static void
test_lfb_main_uninit (void)
{
  g_assert_false (lfb_is_initted ());
  lfb_uninit ();
  g_assert_false (lfb_is_initted ());
}

gint
main (gint argc, gchar *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_autoptr(GTestDBus) bus = g_test_dbus_new (G_TEST_DBUS_NONE);
  g_test_dbus_up (bus);

  g_test_add_func ("/feedbackd/libfeedback/lfb-main/uninit", test_lfb_main_uninit);

  return g_test_run();
}
