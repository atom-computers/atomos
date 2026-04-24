/*
 * Copyright (C) 2024 The Phosh Developers
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#include "testlib.h"

void
fbd_test_umockdev_setup (FbdUmockdevFixture *fixture, gconstpointer mockname)
{
  g_autofree char *path = NULL;
  g_autoptr (GError) err = NULL;
  gboolean success;

  fixture->testbed = umockdev_testbed_new ();
  path = g_strdup_printf("%s/umockdev/%s.umockdev", TEST_DATA_DIR, (const char *)mockname);

  success = umockdev_testbed_add_from_file (fixture->testbed, path, &err);
  g_assert_no_error (err);
  g_assert_true (success);

  umockdev_testbed_enable (fixture->testbed);
}


void
fbd_test_umockdev_teardown (FbdUmockdevFixture *fixture, gconstpointer unused)
{
  umockdev_testbed_clear (fixture->testbed);
  umockdev_testbed_disable (fixture->testbed);
}
