/*
 * Copyright (C) 2025 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define GMOBILE_USE_UNSTABLE_API
#include "fbd-feedback-manager.h"
#include "fbd-feedback-sound.h"

#include <json-glib/json-glib.h>


static void
test_fbd_feedback_sound_event (void)
{
  /* Create manager upfront so we can dispose it, otherwise creating
   * any feedback would create it implicitly */
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  g_autoptr (GError) err = NULL;
  g_autoptr (JsonNode) node = NULL;
  GObject *object;
  g_autofree char *event_name = NULL, *file_name = NULL, *effect = NULL, *media_role = NULL;

  node = json_from_string ("{"
                           " \"event-name\" : \"message-new-cellbroadcast\","
                           " \"type\"       : \"Sound\","
                           " \"effect\"     : \"cellbroadcast\","
                           " \"media-role\" : \"emergency\""
                           "}", &err);
  g_assert_no_error (err);

  object = json_gobject_deserialize (FBD_TYPE_FEEDBACK_SOUND, node);
  g_test_assert_expected_messages ();

  g_object_get (object,
                "event-name", &event_name,
                "file-name", &file_name,
                "effect", &effect,
                "media-role", &media_role,
                NULL);

  g_assert_cmpstr (event_name, ==, "message-new-cellbroadcast");
  g_assert_cmpstr (effect, ==, "cellbroadcast");
  g_assert_null (file_name);
  g_assert_cmpstr (media_role, ==, "emergency");

  g_assert_finalize_object (object);
  g_assert_finalize_object (manager);
}


gint
main (gint argc, gchar *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func ("/feedbackd/fbd/feedback-sound/event", test_fbd_feedback_sound_event);

  return g_test_run ();
}
