/*
 * AtomOS: D-Bus API for Rust atomos-app-handler to drive Phosh home fold/unfold.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#include "phosh-atomos-home-dbus.h"
#include "home.h"

#include <glib-object.h>

#define PHOSH_TYPE_ATOMOS_PHOSH_HOME_DBUS (phosh_atomos_phosh_home_dbus_get_type ())

/* Parent MUST be PhoshDBusPhoshHomeSkeleton (the gdbus-codegen skeleton this
 * type derives from in atomos-phosh-home-dbus.c). G_DECLARE_FINAL_TYPE uses
 * this last argument to synthesize:
 *     typedef struct { ParentNameClass parent_class; } PhoshAtomosPhoshHomeDBusClass;
 * which G_DEFINE_TYPE passes to g_type_register_static as the class size. If it
 * is GObject here while the .c registers PHOSH_DBUS_TYPE_PHOSH_HOME_SKELETON,
 * the class buffer is sized for GObjectClass but the type system copies the far
 * larger PhoshDBusPhoshHomeSkeletonClass vtable into it -> heap overflow ->
 * the construction-time segfault that forced ATOMOS_PHOSH_ENABLE_HOME_DBUS off. */
G_DECLARE_FINAL_TYPE (PhoshAtomosPhoshHomeDBus, phosh_atomos_phosh_home_dbus,
                      PHOSH, ATOMOS_PHOSH_HOME_DBUS, PhoshDBusPhoshHomeSkeleton)

PhoshAtomosPhoshHomeDBus *phosh_atomos_phosh_home_dbus_new (PhoshHome *home);
void                      phosh_atomos_phosh_home_dbus_set_exported (PhoshAtomosPhoshHomeDBus *self,
                                                                     gboolean                  exported);
