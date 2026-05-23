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

G_DECLARE_FINAL_TYPE (PhoshAtomosPhoshHomeDBus, phosh_atomos_phosh_home_dbus,
                      PHOSH, ATOMOS_PHOSH_HOME_DBUS, GObject)

PhoshAtomosPhoshHomeDBus *phosh_atomos_phosh_home_dbus_new (PhoshHome *home);
void                      phosh_atomos_phosh_home_dbus_set_exported (PhoshAtomosPhoshHomeDBus *self,
                                                                     gboolean                  exported);
