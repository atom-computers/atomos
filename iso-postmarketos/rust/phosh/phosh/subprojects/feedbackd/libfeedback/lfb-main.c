/*
 * Copyright (C) 2020 Purism SPC
 *               2025 The Phosh Developers
 *
 * SPDX-License-Identifier: LGPL-2.1+
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */
#include "lfb-main.h"
#include "lfb-gdbus.h"
#include "lfb-priv.h"

#include "lfb-names.h"

static LfbGdbusFeedback *_proxy;
static char             *_app_id;
static gboolean          _initted;
static GHashTable       *_active_ids;

static void
lfb_cancel_feedbacks (void)
{
  gpointer key, value;
  GHashTableIter iter;

  g_hash_table_iter_init (&iter, _active_ids);

  while (g_hash_table_iter_next (&iter, &key, &value)) {
    guint id = GPOINTER_TO_UINT(key);
    g_hash_table_iter_remove (&iter);
    g_debug ("Cancelling feedback on shutdown %d", id);
    /* Need to use a sync call here since there might not be a main loop anymore */
    lfb_gdbus_feedback_call_end_feedback_sync (_proxy, id, NULL, NULL);
  }
}

void
_lfb_active_add_id (guint id)
{
  g_return_if_fail (id > 0);

  if (!_initted)
    return;

  g_hash_table_add (_active_ids, GUINT_TO_POINTER (id));
}

void
_lfb_active_remove_id (guint id)
{
  gboolean success;

  g_return_if_fail (id > 0);

  if (!_initted)
    return;

  success = g_hash_table_remove (_active_ids, GUINT_TO_POINTER(id));
  if (!success)
    g_warning ("Event id %d not known", id);
}


LfbGdbusFeedback *
_lfb_get_proxy (void)
{
  /* Caller needs to check since the proxy might be gone when
     the last event gets finalized */
  return _proxy;
}

/**
 * lfb_init:
 * @app_id: The application id
 * @error: Error information
 *
 * Initialize libfeedback. This must be called before any other of libfeedback's functions.
 *
 * Returns: %TRUE if successful, or %FALSE on error.
 */
gboolean
lfb_init (const gchar *app_id, GError **error)
{
  g_return_val_if_fail (app_id != NULL, FALSE);
  g_return_val_if_fail (*app_id != '\0', FALSE);

  if (_initted)
    return TRUE;

  lfb_set_app_id (app_id);
  _proxy = lfb_gdbus_feedback_proxy_new_for_bus_sync(
      FB_DBUS_TYPE, 0, FB_DBUS_NAME, FB_DBUS_PATH, NULL, error);
  if (!_proxy)
    return FALSE;

  _active_ids = g_hash_table_new (g_direct_hash, g_direct_equal);
  g_object_add_weak_pointer (G_OBJECT (_proxy), (gpointer *) &_proxy);

  _initted = TRUE;
  return TRUE;
}

/**
 * lfb_uninit:
 *
 * Uninitialize the library when no longer used. Usually called
 * on program shutdown.
 */
void
lfb_uninit (void)
{
  _initted = FALSE;

  /* Cancel all feedbacks that the client forgot to clean up */
  if (_active_ids)
    lfb_cancel_feedbacks ();
  g_clear_pointer (&_active_ids, g_hash_table_destroy);
  g_clear_pointer (&_app_id, g_free);
  g_clear_object (&_proxy);
}

/**
 * lfb_set_app_id:
 * @app_id: The application id
 *
 * Sets the application id.
 */
void
lfb_set_app_id (const char *app_id)
{
  g_free (_app_id);
  _app_id = g_strdup (app_id);
}

/**
 * lfb_get_app_id:
 *
 * Get the application id set via [func@Lfb.set_app_id].
 *
 * Returns:  the application id.
 */
const gchar *
lfb_get_app_id (void)
{
  return _app_id;
}

/**
 * lfb_is_initted:
 *
 * Gets whether or not libfeedback is initialized.
 *
 * Returns: %TRUE if libfeedback is initialized, or %FALSE otherwise.
 */
gboolean
lfb_is_initted (void)
{
  return _initted;
}

/**
 * lfb_get_feedback_profile:
 *
 * Gets the currently set feedback profile.
 *
 * Returns: The current profile or %NULL on error.
 */
const char *
lfb_get_feedback_profile (void)
{
  LfbGdbusFeedback *proxy;

  if (!lfb_is_initted ())
    g_error ("You must call lfb_init() before ending events.");

  proxy = _lfb_get_proxy ();
  g_return_val_if_fail (LFB_GDBUS_IS_FEEDBACK (proxy), NULL);

  return lfb_gdbus_feedback_get_profile (LFB_GDBUS_FEEDBACK (proxy));
}


/**
 * lfb_set_feedback_profile:
 * @profile: The profile to set
 *
 * Sets the active feedback profile to #profile. It is up to the feedback
 * daemon to ignore this request. The new profile might not become active
 * immediately. You can listen to changes #LfbGdbusFeedback's ::profile
 * property to get notified when it takes effect.
 */
void
lfb_set_feedback_profile (const gchar *profile)
{
  LfbGdbusFeedback *proxy;

  if (!lfb_is_initted ())
    g_error ("You must call lfb_init() before ending events.");

  proxy = _lfb_get_proxy ();
  g_return_if_fail (LFB_GDBUS_IS_FEEDBACK (proxy));

  lfb_gdbus_feedback_set_profile (LFB_GDBUS_FEEDBACK (proxy), profile);
}

/**
 * lfb_get_proxy:
 *
 * This can be used to access the lower level API e.g. to listen to
 * property changes. The object is not owned by the caller. Don't
 * unref it after use.
 *
 * Returns: (transfer none): The DBus proxy.
 */
LfbGdbusFeedback *
lfb_get_proxy (void)
{
  LfbGdbusFeedback *proxy = _lfb_get_proxy ();

  g_return_val_if_fail (LFB_GDBUS_IS_FEEDBACK (proxy), NULL);
  return proxy;
}
