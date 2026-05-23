/*
 * AtomOS: D-Bus API for Rust atomos-app-handler to drive Phosh home fold/unfold.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#define G_LOG_DOMAIN "phosh-atomos-phosh-home-dbus"

#include "phosh-config.h"

#include "atomos-phosh-home-dbus.h"
#include "home.h"

#define ATOMOS_PHOSH_HOME_DBUS_PATH "/org/atomos/PhoshHome"
#define ATOMOS_PHOSH_HOME_DBUS_NAME "org.atomos.PhoshHome"

struct _PhoshAtomosPhoshHomeDBus {
  PhoshDBusPhoshHomeSkeleton parent;

  PhoshHome *home;
  guint      dbus_name_id;
  gboolean   exported;
};

static void phosh_dbus_phosh_home_iface_init (PhoshDBusPhoshHomeIface *iface);

G_DEFINE_TYPE_WITH_CODE (PhoshAtomosPhoshHomeDBus, phosh_atomos_phosh_home_dbus,
                         PHOSH_DBUS_TYPE_PHOSH_HOME_SKELETON,
                         G_IMPLEMENT_INTERFACE (PHOSH_DBUS_TYPE_PHOSH_HOME,
                                                phosh_dbus_phosh_home_iface_init))

static gboolean
handle_set_folded (PhoshDBusPhoshHome     *object,
                   GDBusMethodInvocation *invocation)
{
  PhoshAtomosPhoshHomeDBus *self = PHOSH_ATOMOS_PHOSH_HOME_DBUS (object);

  g_return_val_if_fail (PHOSH_IS_ATOMOS_PHOSH_HOME_DBUS (self), FALSE);

  if (PHOSH_IS_HOME (self->home))
    phosh_home_set_state (self->home, PHOSH_HOME_STATE_FOLDED);

  phosh_dbus_phosh_home_complete_set_folded (object, invocation);
  return TRUE;
}

static gboolean
handle_set_unfolded (PhoshDBusPhoshHome     *object,
                     GDBusMethodInvocation *invocation)
{
  PhoshAtomosPhoshHomeDBus *self = PHOSH_ATOMOS_PHOSH_HOME_DBUS (object);

  g_return_val_if_fail (PHOSH_IS_ATOMOS_PHOSH_HOME_DBUS (self), FALSE);

  if (PHOSH_IS_HOME (self->home))
    phosh_home_set_state (self->home, PHOSH_HOME_STATE_UNFOLDED);

  phosh_dbus_phosh_home_complete_set_unfolded (object, invocation);
  return TRUE;
}

static gboolean
handle_get_state (PhoshDBusPhoshHome     *object,
                  GDBusMethodInvocation *invocation)
{
  PhoshAtomosPhoshHomeDBus *self = PHOSH_ATOMOS_PHOSH_HOME_DBUS (object);
  const char *state = "unknown";

  g_return_val_if_fail (PHOSH_IS_ATOMOS_PHOSH_HOME_DBUS (self), FALSE);

  if (PHOSH_IS_HOME (self->home)) {
    switch (phosh_home_get_state (self->home)) {
    case PHOSH_HOME_STATE_FOLDED:
      state = "folded";
      break;
    case PHOSH_HOME_STATE_UNFOLDED:
      state = "unfolded";
      break;
    case PHOSH_HOME_STATE_TRANSITION:
      state = "transition";
      break;
    default:
      break;
    }
  }

  phosh_dbus_phosh_home_complete_get_state (object, invocation, state);
  return TRUE;
}

static void
phosh_dbus_phosh_home_iface_init (PhoshDBusPhoshHomeIface *iface)
{
  iface->handle_set_folded = handle_set_folded;
  iface->handle_set_unfolded = handle_set_unfolded;
  iface->handle_get_state = handle_get_state;
}

static void
on_bus_acquired (GDBusConnection *connection, const char *name, gpointer user_data)
{
  PhoshAtomosPhoshHomeDBus *self = user_data;
  g_autoptr (GError) err = NULL;

  (void) name;
  if (g_dbus_interface_skeleton_export (G_DBUS_INTERFACE_SKELETON (self),
                                        connection,
                                        ATOMOS_PHOSH_HOME_DBUS_PATH,
                                        &err)) {
    self->exported = TRUE;
    g_debug ("AtomOS PhoshHome D-Bus exported on '%s'", ATOMOS_PHOSH_HOME_DBUS_NAME);
  } else {
    g_warning ("Failed to export %s: %s", ATOMOS_PHOSH_HOME_DBUS_NAME, err->message);
  }
}

static void
phosh_atomos_phosh_home_dbus_dispose (GObject *object)
{
  PhoshAtomosPhoshHomeDBus *self = PHOSH_ATOMOS_PHOSH_HOME_DBUS (object);

  if (self->exported) {
    g_dbus_interface_skeleton_unexport (G_DBUS_INTERFACE_SKELETON (self));
    self->exported = FALSE;
  }
  g_clear_handle_id (&self->dbus_name_id, g_bus_unown_name);
  g_clear_object (&self->home);

  G_OBJECT_CLASS (phosh_atomos_phosh_home_dbus_parent_class)->dispose (object);
}

static void
phosh_atomos_phosh_home_dbus_class_init (PhoshAtomosPhoshHomeDBusClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->dispose = phosh_atomos_phosh_home_dbus_dispose;
}

static void
phosh_atomos_phosh_home_dbus_init (PhoshAtomosPhoshHomeDBus *self)
{
}

PhoshAtomosPhoshHomeDBus *
phosh_atomos_phosh_home_dbus_new (PhoshHome *home)
{
  PhoshAtomosPhoshHomeDBus *self;

  g_return_val_if_fail (PHOSH_IS_HOME (home), NULL);

  self = g_object_new (PHOSH_TYPE_ATOMOS_PHOSH_HOME_DBUS, NULL);
  self->home = g_object_ref (home);
  return self;
}

void
phosh_atomos_phosh_home_dbus_set_exported (PhoshAtomosPhoshHomeDBus *self, gboolean exported)
{
  g_return_if_fail (PHOSH_IS_ATOMOS_PHOSH_HOME_DBUS (self));

  if (self->exported == exported)
    return;

  if (exported) {
    self->dbus_name_id = g_bus_own_name (G_BUS_TYPE_SESSION,
                                         ATOMOS_PHOSH_HOME_DBUS_NAME,
                                         G_BUS_NAME_OWNER_FLAGS_ALLOW_REPLACEMENT |
                                         G_BUS_NAME_OWNER_FLAGS_REPLACE,
                                         on_bus_acquired,
                                         NULL,
                                         NULL,
                                         self,
                                         NULL);
  } else {
    g_clear_handle_id (&self->dbus_name_id, g_bus_unown_name);
    if (self->exported) {
      g_dbus_interface_skeleton_unexport (G_DBUS_INTERFACE_SKELETON (self));
      self->exported = FALSE;
    }
  }
}
