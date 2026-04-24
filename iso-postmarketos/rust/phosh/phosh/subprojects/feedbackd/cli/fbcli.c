/*
 * Copyright (C) 2020 Purism SPC
 *               2023-2025 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 */
#define LIBFEEDBACK_USE_UNSTABLE_API
#include "libfeedback.h"

#include <glib.h>
#include <gio/gio.h>
#include <glib-unix.h>

#include <locale.h>

#define DEFAULT_EVENT "phone-incoming-call"

static GMainLoop *loop;

static gboolean
on_shutdown_signal (gpointer unused)
{
  /* End right away, lfb_uninit will end running feedback */
  g_main_loop_quit (loop);

  return FALSE;
}

static gboolean
on_watch_expired (gpointer unused)
{
  g_warning ("Watch expired waiting for all feedbacks to finish");
  g_main_loop_quit (loop);

  return G_SOURCE_REMOVE;
}

static void
on_feedback_ended (LfbEvent *event, int *data)
{
  g_return_if_fail (LFB_IS_EVENT (event));

  g_debug  ("Feedback ended for event");
  *data = TRUE;
  g_main_loop_quit (loop);
}

static gboolean
on_user_input (GIOChannel *channel, GIOCondition cond, LfbEvent *event)
{
  g_autoptr (GError) err = NULL;

  if (cond == G_IO_IN) {
    g_print ("Ending feedback\n");
    if (!lfb_event_end_feedback (event, &err))
      g_warning ("Failed to end feedback: %s", err->message);
  }
  return FALSE;
}

static gboolean
trigger_event (const char  *name,
               const char  *profile,
               gboolean     important,
               gint         timeout,
               const char  *sound_file)
{
  g_autoptr (GError) err = NULL;
  g_autoptr (LfbEvent) event = NULL;
  g_autoptr (GIOChannel) input = NULL;
  int success = FALSE;

  g_unix_signal_add (SIGTERM, on_shutdown_signal, NULL);
  g_unix_signal_add (SIGINT, on_shutdown_signal, NULL);

  g_print ("Triggering feedback for event '%s'\n", name);
  event = lfb_event_new (name);
  lfb_event_set_timeout (event, timeout);
  if (profile)
    lfb_event_set_feedback_profile (event, profile);

  if (important)
    lfb_event_set_important (event, TRUE);

  if (sound_file)
    lfb_event_set_sound_file(event, sound_file);

  g_signal_connect (event, "feedback-ended", (GCallback)on_feedback_ended, &success);
  if (!lfb_event_trigger_feedback (event, &err)) {
    g_print ("Failed to report event: %s\n", err->message);
    return FALSE;
  }

  input = g_io_channel_unix_new (STDIN_FILENO);
  g_io_add_watch (input, G_IO_IN, (GIOFunc)on_user_input, event);
  g_print ("Press <RETURN> to end feedback right away.\n");

  loop = g_main_loop_new (NULL, FALSE);
  g_main_loop_run (loop);
  g_main_loop_unref (loop);

  if (lfb_event_get_end_reason (event) == LFB_EVENT_END_REASON_NOT_FOUND)
    g_print ("No feedback found for '%s' at level '%s'\n", name, lfb_get_feedback_profile ());

  return success;
}

static void
on_profile_changed (LfbGdbusFeedback *proxy, GParamSpec *psepc, gpointer unused)
{
  g_print ("Set feedback profile to: '%s'\n",
           lfb_get_feedback_profile ());
  g_main_loop_quit (loop);
}

static gboolean
set_profile (const gchar *profile)
{
  LfbGdbusFeedback *proxy;
  const gchar *current;

  current = lfb_get_feedback_profile ();
  g_debug ("Current profile is %s", current);
  if (!g_strcmp0 (current, profile)) {
    g_print ("Profile is already set to %s\n", profile);
    return TRUE;
  }

  g_debug ("Setting profile to %s", profile);
  proxy = lfb_get_proxy ();

  /* Set profile and wait until we got notified about the profile change */
  loop = g_main_loop_new (NULL, FALSE);
  lfb_set_feedback_profile (profile);
  g_signal_connect (proxy, "notify::profile", (GCallback)on_profile_changed, NULL);
  g_main_loop_run (loop);
  g_print ("Current feedback profile is: '%s'\n",
           lfb_get_feedback_profile ());
  return TRUE;
}

int
main (int argc, char *argv[0])
{
  g_autoptr (GOptionContext) opt_context = NULL;
  g_autoptr (GError) err = NULL;
  g_autofree char *profile = NULL;
  g_autofree char *app_id = NULL;
  g_autofree char *sound_file = NULL;
  const char *name = NULL;
  gboolean success, important = FALSE;
  int watch = 30;
  int timeout = -1;
  const GOptionEntry options [] = {
    {"event", 'E', 0, G_OPTION_ARG_STRING, &name,
     "Event name. (default: " DEFAULT_EVENT ").", NULL},
    {"important", 'I', 0, G_OPTION_ARG_NONE, &important,
     "Whether to set the important hint", NULL},
    {"timeout", 't', 0, G_OPTION_ARG_INT, &timeout,
     "Run feedback for timeout seconds", NULL},
    {"profile", 'P', 0, G_OPTION_ARG_STRING, &profile,
     "Profile name to set", NULL},
    {"watch", 'w', 0, G_OPTION_ARG_INT, &watch,
     "How long to watch for feedback longest", NULL},
    {"app-id", 'A', 0, G_OPTION_ARG_STRING, &app_id,
     "Override used application id"},
    {"sound-file", 'S', 0, G_OPTION_ARG_STRING, &sound_file,
     "Override the sound effect used by a file"},
    { NULL, 0, 0, G_OPTION_ARG_NONE, NULL, NULL, NULL }
  };

  setlocale (LC_ALL, "");
  opt_context = g_option_context_new ("- A cli for feedbackd");
  g_option_context_add_main_entries (opt_context, options, NULL);
  if (!g_option_context_parse (opt_context, &argc, &argv, &err)) {
    g_warning ("%s", err->message);
    return 1;
  }

  if (!app_id)
    app_id = g_strdup ("org.sigxcpu.fbcli");

  if (!lfb_init (app_id, &err)) {
    g_print ("Failed to init libfeedback: %s\n", err->message);
    return 1;
  }

  if (profile && !name) {
    success = set_profile (profile);
  } else {
    if (!name)
      name = g_strdup (DEFAULT_EVENT);

    g_timeout_add_seconds (watch, (GSourceFunc)on_watch_expired, NULL);
    success = trigger_event (name, profile, important, timeout, sound_file);
  }

  lfb_uninit ();
  return !success;
}
