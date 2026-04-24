/*
 * Copyright (C) 2020 Purism SPC
 *               2024-2025 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-feedback-manager"

#include "lfb-names.h"
#include "fbd.h"
#include "fbd-dev-vibra.h"
#include "fbd-dev-leds.h"
#include "fbd-event.h"
#include "fbd-feedback-vibra.h"
#include "fbd-feedback-vibra-pattern.h"
#include "fbd-feedback-manager.h"
#include "fbd-feedback-theme.h"
#include "fbd-haptic-manager.h"
#include "fbd-theme-expander.h"

#include <gmobile.h>

#include <gio/gio.h>
#include <glib-unix.h>
#include <gudev/gudev.h>

#define FEEDBACKD_KEY_PROFILE "profile"
#define FEEDBACKD_KEY_THEME "theme"
#define FEEDBACKD_KEY_ALLOW_IMPORTANT "allow-important"

#define APP_SCHEMA FEEDBACKD_SCHEMA_ID ".application"
#define APP_PREFIX "/org/sigxcpu/feedbackd/application/"

#define FEEDBACKD_THEME_VAR "FEEDBACK_THEME"

/**
 * SECTION:fbd-feedback-manager
 * @short_description: The manager processing incoming events
 * @Title: FbdFeedbackManager
 *
 * The #FbdFeedbackManager listens for DBus messages and triggers feedbacks
 * based on the incoming events.
 */

FbdDebugFlags fbd_debug_flags;


typedef struct _FbdFeedbackManager {
  LfbGdbusFeedbackSkeleton parent;

  GSettings               *settings;
  FbdFeedbackProfileLevel  level;
  FbdFeedbackTheme        *theme;
  guint                    next_id;
  GStrv                    allow_important;

  /* Key: event id, value: event */
  GHashTable              *events;
  /* Key: DBus name, value: watch_id */
  GHashTable              *clients;

  /* org.sigxcpu.Feedbackd.Haptic */
  FbdHapticManager        *haptic_manager;

  /* Hardware interaction */
  GUdevClient             *client;
  FbdDevVibra             *vibra;
  FbdDevSound             *sound;
  FbdDevLeds              *leds;
} FbdFeedbackManager;

static void fbd_feedback_manager_feedback_iface_init (LfbGdbusFeedbackIface *iface);

G_DEFINE_TYPE_WITH_CODE (FbdFeedbackManager,
                         fbd_feedback_manager,
                         LFB_GDBUS_TYPE_FEEDBACK_SKELETON,
                         G_IMPLEMENT_INTERFACE (
                           LFB_GDBUS_TYPE_FEEDBACK,
                           fbd_feedback_manager_feedback_iface_init));

static void
device_changes (FbdFeedbackManager *self, gchar *action, GUdevDevice *device,
                GUdevClient        *client)
{
  g_debug ("Device changes: action = %s, device = %s",
           action, g_udev_device_get_sysfs_path (device));

  if (g_strcmp0 (action, "remove") == 0 && self->vibra) {
    GUdevDevice *dev = fbd_dev_vibra_get_device (self->vibra);

    if (g_strcmp0 (g_udev_device_get_sysfs_path (dev),
                   g_udev_device_get_sysfs_path (device)) == 0) {
      g_debug ("Vibra device %s got removed", g_udev_device_get_sysfs_path (dev));
      g_clear_object (&self->vibra);
    }
  } else if (g_strcmp0 (action, "add") == 0) {
    if (!g_strcmp0 (g_udev_device_get_property (device, FEEDBACKD_UDEV_ATTR), "vibra")) {
      g_autoptr (GError) err = NULL;

      g_debug ("Found hotplugged vibra device at %s", g_udev_device_get_sysfs_path (device));
      g_clear_object (&self->vibra);
      self->vibra = fbd_dev_vibra_new (device, &err);
      if (!self->vibra)
        g_warning ("Failed to init vibra device: %s", err->message);
    }
  }
}

static gchar *
munge_app_id (const gchar *app_id)
{
  gchar *id = g_strdup (app_id);
  gint i;

  g_strcanon (id,
              "0123456789"
              "abcdefghijklmnopqrstuvwxyz"
              "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
              "-",
              '-');
  for (i = 0; id[i] != '\0'; i++)
    id[i] = g_ascii_tolower (id[i]);

  return id;
}

static FbdFeedbackProfileLevel
app_get_feedback_level (const gchar *app_id)
{
  g_autofree gchar *profile = NULL;
  g_autofree gchar *munged_app_id = munge_app_id (app_id);
  g_autofree gchar *path = g_strconcat (APP_PREFIX, munged_app_id, "/", NULL);
  g_autoptr (GSettings) setting =  g_settings_new_with_path (APP_SCHEMA, path);

  profile = g_settings_get_string (setting, FEEDBACKD_KEY_PROFILE);
  g_debug ("%s uses app profile %s", app_id, profile);
  return fbd_feedback_profile_level (profile);
}

static void
init_devices (FbdFeedbackManager *self)
{
  GList *l;
  g_autolist (GUdevClient) devices = NULL;
  g_autoptr(GError) err = NULL;

  devices = g_udev_client_query_by_subsystem (self->client, "input");

  for (l = devices; l != NULL; l = l->next) {
    GUdevDevice *dev = l->data;

    if (!g_strcmp0 (g_udev_device_get_property (dev, FEEDBACKD_UDEV_ATTR), "vibra")) {
      g_debug ("Found vibra device");
      self->vibra = fbd_dev_vibra_new (dev, &err);
      if (!self->vibra) {
        g_warning ("Failed to init vibra device: %s", err->message);
        g_clear_error (&err);
      }
    }
  }
  if (!self->vibra)
    g_debug ("No vibra capable device found");

  self->leds = fbd_dev_leds_new (&err);
  if (!self->leds) {
    g_debug ("Failed to init leds device: %s", err->message);
    g_clear_error (&err);
  }

  self->sound = fbd_dev_sound_new (&err);
  if (!self->sound) {
    g_warning ("Failed to init sound device: %s", err->message);
    g_clear_error (&err);
  }
}

static void
on_event_feedbacks_ended (FbdFeedbackManager *self, FbdEvent *event)
{
  guint event_id;

  g_return_if_fail (FBD_IS_FEEDBACK_MANAGER (self));
  g_return_if_fail (FBD_IS_EVENT (event));

  event_id = fbd_event_get_id (event);
  event = g_hash_table_lookup (self->events, GUINT_TO_POINTER (event_id));
  if (!event) {
    g_warning ("Feedback ended for unknown event %d", event_id);
    return;
  }

  g_return_if_fail (fbd_event_get_feedbacks_ended (event));

  lfb_gdbus_feedback_emit_feedback_ended (LFB_GDBUS_FEEDBACK (self), event_id,
                                          fbd_event_get_end_reason (event));

  g_debug ("All feedbacks for event %d finished", event_id);
  g_hash_table_remove (self->events, GUINT_TO_POINTER (event_id));
}

static void
on_profile_changed (FbdFeedbackManager *self, GParamSpec *psepc, gpointer unused)
{
  const gchar *pname;

  g_return_if_fail (FBD_IS_FEEDBACK_MANAGER (self));

  pname = lfb_gdbus_feedback_get_profile (LFB_GDBUS_FEEDBACK (self));

  if (!fbd_feedback_manager_set_profile (self, pname))
    g_warning ("Invalid profile '%s'", pname);
}

static void
on_feedbackd_setting_changed (FbdFeedbackManager *self,
                              const gchar        *key,
                              GSettings          *settings)
{
  g_autofree gchar *profile = NULL;

  g_return_if_fail (FBD_IS_FEEDBACK_MANAGER (self));
  g_return_if_fail (G_IS_SETTINGS (settings));

  if (g_str_equal (key, FEEDBACKD_KEY_PROFILE)) {
    profile = g_settings_get_string (settings, key);
    fbd_feedback_manager_set_profile (self, profile);
  } else if (g_str_equal (key, FEEDBACKD_KEY_THEME)) {
    fbd_feedback_manager_load_theme (self);
  } else {
    g_critical ("Unknown settings key '%s'", key);
  }
}


static gboolean
app_is_important (FbdFeedbackManager *self, const char *app_id)
{
  if (!self->allow_important)
    return FALSE;

  if (g_strv_contains ((const char *const *)self->allow_important, app_id))
    return TRUE;

  return FALSE;
}


static void
on_feedbackd_allow_important_changed (FbdFeedbackManager *self,
                                      const gchar        *key,
                                      GSettings          *settings)
{
  g_return_if_fail (FBD_IS_FEEDBACK_MANAGER (self));
  g_return_if_fail (G_IS_SETTINGS (settings));

  g_strfreev (self->allow_important);
  self->allow_important = g_settings_get_strv(self->settings, FEEDBACKD_KEY_ALLOW_IMPORTANT);
}


static void
on_client_vanished (GDBusConnection *connection,
		    const gchar     *name,
		    gpointer         user_data)
{
  FbdFeedbackManager *self = FBD_FEEDBACK_MANAGER (user_data);
  GHashTableIter iter;
  gpointer key, value;
  FbdEvent *event;
  GSList *l;
  g_autoptr (GSList) events = NULL;

  g_return_if_fail (name);

  g_debug ("Client %s vanished", name);

  /*
   * Prepare a list of events to end feedback for so we don't modify
   * the hash table in place when 'feedbacks-ended' fires.
   */
  g_hash_table_iter_init (&iter, self->events);
  while (g_hash_table_iter_next (&iter, &key, &value)) {
    event = FBD_EVENT (value);
    if (!g_strcmp0 (fbd_event_get_sender (event), name))
      events = g_slist_append (events, event);
  }

  for (l = events; l; l = l->next) {
    event = l->data;
    g_debug ("Ending event %s (%d) since %s vanished",
             fbd_event_get_event (event),
             fbd_event_get_id (event),
             name);
    fbd_event_end_feedbacks (event);
  }

  g_hash_table_remove (self->clients, name);
}

static void
watch_client (FbdFeedbackManager *self, GDBusMethodInvocation *invocation)
{
  guint watch_id;
  GDBusConnection *conn = g_dbus_method_invocation_get_connection (invocation);
  const char *sender = g_dbus_method_invocation_get_sender (invocation);

  watch_id = g_bus_watch_name_on_connection (conn,
					     sender,
					     G_BUS_NAME_WATCHER_FLAGS_NONE,
					     NULL,
					     on_client_vanished,
					     self,
					     NULL);
  g_hash_table_insert (self->clients, g_strdup (sender), GUINT_TO_POINTER (watch_id));
}

static void
free_client_watch (gpointer data)
{
  guint watch_id = GPOINTER_TO_UINT (data);

  if (watch_id == 0)
    return;
  g_bus_unwatch_name (watch_id);
}

static FbdFeedbackProfileLevel
get_max_level (FbdFeedbackProfileLevel global_level,
               FbdFeedbackProfileLevel app_level,
               FbdFeedbackProfileLevel event_level)
{
  FbdFeedbackProfileLevel level;

  /* Per app configuration can only select a *lower* feedback level */
  level = MIN (global_level, app_level);
  /* A hint in an event can only select a *lower* feedback level */
  level = MIN (level, event_level);

  return level;
}

static gboolean
parse_hints (GVariant                *hints,
             FbdFeedbackProfileLevel *level,
             gboolean                *hint_important,
             char                   **hint_sound_file)
{
  const gchar *profile, *sound_file;
  gboolean found, important;
  g_auto (GVariantDict) dict = G_VARIANT_DICT_INIT (NULL);

  g_variant_dict_init (&dict, hints);

  found = g_variant_dict_lookup (&dict, "profile", "&s", &profile);
  if (level && found)
    *level = fbd_feedback_profile_level (profile);

  found = g_variant_dict_lookup (&dict, "important", "b", &important);
  if (hint_important && found)
    *hint_important = important;

  found = g_variant_dict_lookup (&dict, "sound-file", "&s", &sound_file);
  if (hint_sound_file && found)
    *hint_sound_file = g_strdup (sound_file);

  return TRUE;
}

/**
 * add_event_feedbacks:
 *
 * Add the suitable feedbacks to the event.
 *
 * Returns: `TRUE` if at least on feedback was added.
 */
static gboolean
add_event_feedbacks (FbdFeedbackManager      *self,
                     FbdEvent                *event,
                     GSList                  *feedbacks,
                     FbdFeedbackProfileLevel  level,
                     const char              *sound_file)
{
  gboolean has_vibra = FALSE, has_sound = FALSE;

  /* Synthesize sound event for custom sound */
  if (sound_file && level >= FBD_FEEDBACK_PROFILE_LEVEL_FULL) {
    g_autoptr (FbdFeedbackSound) sound = NULL;

    g_debug ("Using custom sound event '%s'", sound_file);
    sound = fbd_feedback_sound_new_from_file_name (sound_file);

    fbd_event_add_feedback (event, FBD_FEEDBACK_BASE (sound));
    has_sound = TRUE;
  }

  for (GSList *l = feedbacks; l; l = l->next) {
    FbdFeedbackBase *fb = FBD_FEEDBACK_BASE (l->data);

    if (!fbd_feedback_is_available (FBD_FEEDBACK_BASE (fb)))
      continue;

    if (FBD_IS_FEEDBACK_SOUND (fb) && has_sound)
      continue;

    /* Handle one haptic feedback at a time. In practice haptics can handle multiple
     * patterns but none of the devices supports this atm */
    /* TODO: should respect priorities */
    if (FBD_IS_FEEDBACK_VIBRA (fb)) {
      if (fbd_dev_vibra_is_busy (self->vibra))
        continue;
      has_vibra = TRUE;
    }

    /* Events take priority over the haptic interface */
    if (has_vibra)
      fbd_haptic_manager_end_feedback (self->haptic_manager);

    fbd_event_add_feedback (event, fb);
  }

  return (fbd_event_get_feedbacks (event) != NULL);
}


static gboolean
fbd_feedback_manager_handle_trigger_feedback (LfbGdbusFeedback      *object,
                                              GDBusMethodInvocation *invocation,
                                              const gchar           *arg_app_id,
                                              const gchar           *arg_event,
                                              GVariant              *arg_hints,
                                              gint                   arg_timeout)
{
  FbdFeedbackManager *self;
  FbdEvent *event;
  GSList *feedbacks;
  guint event_id;
  const gchar *sender;
  FbdFeedbackProfileLevel level, hint_level = FBD_FEEDBACK_PROFILE_LEVEL_FULL;
  gboolean found_fb = FALSE;
  gboolean hint_important = FALSE;
  g_autofree char *sound_file = NULL;

  sender = g_dbus_method_invocation_get_sender (invocation);
  g_debug ("Event '%s' for '%s' from %s", arg_event, arg_app_id, sender);

  g_return_val_if_fail (FBD_IS_FEEDBACK_MANAGER (object), FALSE);
  g_return_val_if_fail (arg_app_id, FALSE);
  g_return_val_if_fail (arg_event, FALSE);

  self = FBD_FEEDBACK_MANAGER (object);
  if (!strlen (arg_app_id)) {
    g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                           G_DBUS_ERROR_INVALID_ARGS,
                                           "Invalid app id %s", arg_app_id);
    return TRUE;
  }

  if (!strlen (arg_event)) {
    g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                           G_DBUS_ERROR_INVALID_ARGS,
                                           "Invalid event %s", arg_event);
    return TRUE;
  }

  if (!parse_hints (arg_hints, &hint_level, &hint_important, &sound_file)) {
    g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                           G_DBUS_ERROR_INVALID_ARGS,
                                           "Invalid hints");
    return TRUE;
  }

  if (arg_timeout < -1)
    arg_timeout = -1;

  event_id = self->next_id++;

  event = fbd_event_new (event_id, arg_app_id, arg_event, arg_timeout, sender);
  g_hash_table_insert (self->events, GUINT_TO_POINTER (event_id), event);

  level = fbd_feedback_manager_get_effective_level (self, arg_app_id, hint_level, hint_important);

  feedbacks = fbd_feedback_theme_lookup_feedback (self->theme, level, event);
  found_fb = add_event_feedbacks (self, event, feedbacks, level, sound_file);
  if (feedbacks)
    g_slist_free_full (feedbacks, g_object_unref);

  lfb_gdbus_feedback_complete_trigger_feedback (object, invocation, event_id);

  if (found_fb) {
    g_signal_connect_object (event, "feedbacks-ended",
                             (GCallback) on_event_feedbacks_ended,
                             self,
                             G_CONNECT_SWAPPED);
    fbd_event_run_feedbacks (event);
    watch_client (self, invocation);
  } else {
    g_hash_table_remove (self->events, GUINT_TO_POINTER (event_id));
    lfb_gdbus_feedback_emit_feedback_ended (LFB_GDBUS_FEEDBACK (self), event_id,
                                            FBD_EVENT_END_REASON_NOT_FOUND);
  }

  return TRUE;
}

static gboolean
fbd_feedback_manager_handle_end_feedback (LfbGdbusFeedback      *object,
                                          GDBusMethodInvocation *invocation,
                                          guint                  event_id)
{
  FbdFeedbackManager *self;
  FbdEvent *event;

  g_debug ("Ending feedback for event '%d'", event_id);

  g_return_val_if_fail (FBD_IS_FEEDBACK_MANAGER (object), FALSE);
  g_return_val_if_fail (event_id, FALSE);

  self = FBD_FEEDBACK_MANAGER (object);

  event = g_hash_table_lookup (self->events, GUINT_TO_POINTER (event_id));
  if (event) {
    /* The last feedback ending will trigger event disposal via
       `on_fb_ended` */
    fbd_event_end_feedbacks (event);
  } else {
    g_warning ("Tried to end non-existing event %d", event_id);
  }

  lfb_gdbus_feedback_complete_end_feedback (object, invocation);
  return TRUE;
}


static void
fbd_feedback_manager_constructed (GObject *object)
{
  FbdFeedbackManager *self = FBD_FEEDBACK_MANAGER (object);

  G_OBJECT_CLASS (fbd_feedback_manager_parent_class)->constructed (object);

  g_signal_connect (self, "notify::profile", (GCallback)on_profile_changed, NULL);

  self->settings = g_settings_new (FEEDBACKD_SCHEMA_ID);
  g_signal_connect_swapped (self->settings, "changed::" FEEDBACKD_KEY_THEME,
                            G_CALLBACK (on_feedbackd_setting_changed), self);
  g_signal_connect_swapped (self->settings, "changed::" FEEDBACKD_KEY_PROFILE,
                            G_CALLBACK (on_feedbackd_setting_changed), self);
  on_feedbackd_setting_changed (self, FEEDBACKD_KEY_PROFILE, self->settings);

  g_signal_connect_swapped (self->settings, "changed::" FEEDBACKD_KEY_ALLOW_IMPORTANT,
                            G_CALLBACK (on_feedbackd_allow_important_changed), self);
  on_feedbackd_allow_important_changed (self, FEEDBACKD_KEY_ALLOW_IMPORTANT, self->settings);

  if (self->vibra || fbd_debug_flags & FBD_DEBUG_FLAG_FORCE_HAPTIC)
    self->haptic_manager = fbd_haptic_manager_new ();
}


static void
fbd_feedback_manager_dispose (GObject *object)
{
  FbdFeedbackManager *self = FBD_FEEDBACK_MANAGER (object);

  g_clear_object (&self->haptic_manager);

  g_clear_object (&self->settings);
  g_clear_object (&self->theme);
  g_clear_object (&self->sound);
  g_clear_object (&self->vibra);
  g_clear_object (&self->leds);
  g_clear_object (&self->client);

  g_clear_pointer (&self->allow_important, g_strfreev);
  g_clear_pointer (&self->events, g_hash_table_destroy);
  g_clear_pointer (&self->clients, g_hash_table_destroy);

  G_OBJECT_CLASS (fbd_feedback_manager_parent_class)->dispose (object);
}

static void
fbd_feedback_manager_feedback_iface_init (LfbGdbusFeedbackIface *iface)
{
  iface->handle_trigger_feedback = fbd_feedback_manager_handle_trigger_feedback;
  iface->handle_end_feedback = fbd_feedback_manager_handle_end_feedback;
}

static void
fbd_feedback_manager_class_init (FbdFeedbackManagerClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->constructed = fbd_feedback_manager_constructed;
  object_class->dispose = fbd_feedback_manager_dispose;
}

static void
fbd_feedback_manager_init (FbdFeedbackManager *self)
{
  const gchar * const subsystems[] = { "input", NULL };

  self->next_id = 1;
  self->level = FBD_FEEDBACK_PROFILE_LEVEL_UNKNOWN;

  self->client = g_udev_client_new (subsystems);
  g_signal_connect_swapped (G_OBJECT (self->client), "uevent",
                            G_CALLBACK (device_changes), self);
  init_devices (self);

  self->events = g_hash_table_new_full (g_direct_hash,
                                        g_direct_equal,
                                        NULL,
                                        (GDestroyNotify)g_object_unref);
  self->clients = g_hash_table_new_full (g_str_hash,
                                         g_str_equal,
                                         g_free,
                                         free_client_watch);
}

FbdFeedbackManager *
fbd_feedback_manager_get_default (void)
{
  static FbdFeedbackManager *instance;

  if (instance == NULL) {
    instance = g_object_new (FBD_TYPE_FEEDBACK_MANAGER, NULL);
    g_object_add_weak_pointer (G_OBJECT (instance), (gpointer *)&instance);
  }
  return instance;
}

FbdDevVibra *
fbd_feedback_manager_get_dev_vibra (FbdFeedbackManager *self)
{
  g_return_val_if_fail (FBD_IS_FEEDBACK_MANAGER (self), NULL);

  return self->vibra;
}

FbdDevSound *
fbd_feedback_manager_get_dev_sound (FbdFeedbackManager *self)
{
  g_return_val_if_fail (FBD_IS_FEEDBACK_MANAGER (self), NULL);

  return self->sound;
}

FbdDevLeds *
fbd_feedback_manager_get_dev_leds (FbdFeedbackManager *self)
{
  g_return_val_if_fail (FBD_IS_FEEDBACK_MANAGER (self), NULL);

  return self->leds;
}

void
fbd_feedback_manager_load_theme (FbdFeedbackManager *self)
{
  g_autoptr (FbdThemeExpander) expander = NULL;
  g_autoptr (FbdFeedbackTheme) theme = NULL;
  g_autoptr (GError) err = NULL;
  g_auto (GStrv) compatibles = NULL;
  g_autofree char *theme_name = NULL;
  const char *theme_file = g_getenv (FEEDBACKD_THEME_VAR);

  compatibles = gm_device_tree_get_compatibles (NULL, &err);
  if (compatibles == NULL && err) {
    g_debug ("Failed to get compatibles: %s", err->message);
    g_clear_error (&err);
  }

  if (theme_file == NULL)
    theme_name = g_settings_get_string (self->settings, FEEDBACKD_KEY_THEME);

  expander = fbd_theme_expander_new ((const char *const *)compatibles,
                                     theme_name, theme_file);
  theme = fbd_theme_expander_load_theme_files (expander, &err);
  if (theme) {
    g_set_object(&self->theme, theme);
  } else {
    if (self->theme)
      g_warning ("Failed to reload theme: %s", err->message);
    else
      g_error ("Failed to load any theme: %s", err->message); // No point to carry on
  }
}


static void
cancel_running (FbdFeedbackManager *self)
{
  g_autoptr (GList) running = g_hash_table_get_values (self->events);

  for (GList *l = running; l ; l = l->next) {
    FbdEvent *event = FBD_EVENT (l->data);

    fbd_event_end_feedbacks_by_level (event, self->level);
  }
}


gboolean
fbd_feedback_manager_set_profile (FbdFeedbackManager *self, const gchar *profile)
{
  FbdFeedbackProfileLevel level;

  g_return_val_if_fail (FBD_IS_FEEDBACK_MANAGER (self), FALSE);

  level = fbd_feedback_profile_level (profile);

  if (level == FBD_FEEDBACK_PROFILE_LEVEL_UNKNOWN)
    return FALSE;

  if (level == self->level)
    return TRUE;

  g_debug ("Switching profile to '%s'", profile);
  self->level = level;
  lfb_gdbus_feedback_set_profile (LFB_GDBUS_FEEDBACK (self), profile);
  g_settings_set_string (self->settings, FEEDBACKD_KEY_PROFILE, profile);

  cancel_running (self);

  return TRUE;
}


FbdHapticManager *
fbd_feedback_manager_get_haptic_manager (FbdFeedbackManager *self)
{
  g_assert (FBD_IS_FEEDBACK_MANAGER (self));

  return self->haptic_manager;
}

/**
 * fbd_feedback_manager_get_effective_level:
 * @self: The feedback manager
 * @app_id: The app-id of the app that triggered the feedback
 * @want_level: The wanted level
 * @important: Whether the important hint is set
 *
 * Calculates the effective feedback level taking the hints sent for the event
 * and the system configuration into account
 *
 * Returns: The effective feedback level
 */
FbdFeedbackProfileLevel
fbd_feedback_manager_get_effective_level (FbdFeedbackManager      *self,
                                          const char              *app_id,
                                          FbdFeedbackProfileLevel  want_level,
                                          gboolean                 important)
{
  gboolean can_important;
  FbdFeedbackProfileLevel app_level, level;

  app_level = app_get_feedback_level (app_id);
  can_important = app_is_important (self, app_id);

  if (important && can_important) {
    level = MIN (want_level, app_level);
  } else {
    level = get_max_level (self->level, app_level, want_level);
  }

  return level;
}
