/*
 * Copyright (C) 2023 The Phosh Developers
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#include "gm-resources.h"
#include "gm-util.h"

#include <glib.h>

/**
 * gm_str_is_null_or_empty:
 * @x:(nullable): A null terminated string
 *
 * Convenience macro to check if a given string is `NULL` or empty.
 * Evaluates to a truth value if `x` is `NULL` or `x` is the empty string
 * otherwise `FALSE`.
 *
 * Since: 0.0.5
 */

/**
 * gm_strv_is_null_or_empty:
 * @x:(nullable): A `NULL` terminated `GStrv`
 *
 * Convenience macro to check if a given `GStrv` is `NULL` or empty.
 * Evaluates to a truth value if `x` is `NULL` or `x` has no elements otherwise
 * `FALSE`.
 *
 * Since: 0.0.5
 */

/**
 * gm_list_devices:
 *
 * List device tree names of known devices.
 *
 * Returns:(nullable)(transfer full):The devices
 *
 * Since: 0.2.2
 */
GStrv
gm_list_devices (void)
{
  g_autoptr (GError) err = NULL;
  GResource *resource = gm_get_resource ();
  g_auto (GStrv) children = NULL;
  g_autoptr (GStrvBuilder) builder = g_strv_builder_new ();

  children = g_resource_enumerate_children (resource,
                                            "/mobi/phosh/gmobile/devices/display-panels/",
                                            G_RESOURCE_LOOKUP_FLAGS_NONE,
                                            &err);

  if (!children) {
    g_critical ("Failed to enumerate known devices: %s", err->message);
    return NULL;
  }

  for (int i = 0; children[i]; i++) {
    if (!g_str_has_suffix (children[i], ".json"))
      continue;

    g_strv_builder_take (builder, g_strndup (children[i], strlen (children[i]) - 5));
  }

  return g_strv_builder_end (builder);
}
