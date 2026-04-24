/*
 * Copyright (C) 2024 The Phosh Developers
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <glib.h>
#include <umockdev.h>

#pragma once

G_BEGIN_DECLS

typedef struct _FbdUdevMockFixture {
  UMockdevTestbed *testbed;
} FbdUmockdevFixture;


void fbd_test_umockdev_setup (FbdUmockdevFixture *fixture, gconstpointer mockname);
void fbd_test_umockdev_teardown (FbdUmockdevFixture *fixture, gconstpointer unused);

#define FBD_UMOCKDEV_TEST_ADD(name, func, f) g_test_add ((name), FbdUmockdevFixture, (f),  \
                                                         (gpointer)fbd_test_umockdev_setup, \
                                                         (gpointer)(func),                  \
                                                         (gpointer)fbd_test_umockdev_teardown)
G_END_DECLS
