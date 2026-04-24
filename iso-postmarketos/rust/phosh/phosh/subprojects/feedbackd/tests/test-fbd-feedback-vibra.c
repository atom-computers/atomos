/*
 * Copyright (C) 2025 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define GMOBILE_USE_UNSTABLE_API
#include "fbd-feedback-manager.h"
#include "fbd-feedback-vibra-pattern.h"
#include "fbd-feedback-vibra-periodic.h"
#include "fbd-feedback-vibra-rumble.h"

#include <json-glib/json-glib.h>


static void
test_fbd_feedback_vibra_rumble (void)
{
  /* Create manager upfront so we can dispose it, otherwise creating
   * any feedback would create it implicitly */
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  g_autoptr (GError) err = NULL;
  g_autoptr (JsonNode) node = NULL;
  GObject *object;
  double magnitude;
  guint count, duration;

  node = json_from_string("{"
                          " \"event-name\" : \"button-pressed\","
                          " \"type\"       : \"VibraRumble\","
                          " \"magnitude\"  : 0.7,"
                          " \"duration\"   : 100,"
                          " \"count\"      : 2"
                          "}", &err);
  g_assert_no_error (err);

  object = json_gobject_deserialize (FBD_TYPE_FEEDBACK_VIBRA_RUMBLE, node);
  g_test_assert_expected_messages ();

  g_object_get (object,
                "magnitude", &magnitude,
                "duration", &duration,
                "count", &count,
                NULL);

  g_assert_cmpfloat_with_epsilon (magnitude, 0.7, FLT_EPSILON);
  g_assert_cmpint (duration, ==, 100);
  g_assert_cmpint (count, ==, 2);

  g_assert_finalize_object (object);
  g_assert_finalize_object (manager);
}


static void
test_fbd_feedback_vibra_pattern (void)
{
  /* Create manager upfront so we can dispose it, otherwise creating
   * any feedback would create it implicitly */
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  g_autoptr (GError) err = NULL;
  g_autoptr (JsonNode) node = NULL;
  g_autoptr (GArray) durations = NULL, magnitudes = NULL;
  GObject *object;
  guint *duration;
  double *magnitude;

  node = json_from_string("{"
                          " \"event-name\" : \"button-pressed\","
                          " \"type\"       : \"VibraPattern\","
                          " \"magnitudes\" : [ 0.2, 1.0 ],"
                          " \"durations\"  : [ 7, 3 ]"
                          "}", &err);
  g_assert_no_error (err);

  object = json_gobject_deserialize (FBD_TYPE_FEEDBACK_VIBRA_PATTERN, node);
  g_object_get (object, "durations", &durations, "magnitudes", &magnitudes, NULL);

  g_assert_nonnull(durations);
  g_assert_nonnull(magnitudes);

  duration = &g_array_index (durations, guint, 0);
  g_assert_cmpint (*duration, ==, 7);
  duration = &g_array_index (durations, guint, 1);
  g_assert_cmpint (*duration, ==, 3);

  magnitude = &g_array_index (magnitudes, double, 0);
  g_assert_cmpfloat (*magnitude, ==, 0.2);
  magnitude = &g_array_index (magnitudes, double, 1);
  g_assert_cmpfloat (*magnitude, ==, 1.0);

  g_assert_finalize_object (object);
  g_assert_finalize_object (manager);
}


static void
test_fbd_feedback_vibra_periodic (void)
{
  /* Create manager upfront so we can dispose it, otherwise creating
   * any feedback would create it implicitly */
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  g_autoptr (GError) err = NULL;
  g_autoptr (JsonNode) node = NULL;
  GObject *object;
  double magnitude, fade_in_level;
  guint fade_in_time;

  node = json_from_string("{"
                          " \"event-name\"    : \"button-pressed\","
                          " \"type\"          : \"VibraPeriodic\","
                          " \"magnitude\"     : 0.7,"
                          " \"fade-in-level\" : 0.3"
                          "}", &err);
  g_assert_no_error (err);

  object = json_gobject_deserialize (FBD_TYPE_FEEDBACK_VIBRA_PERIODIC, node);
  g_object_get (object,
                "magnitude", &magnitude,
                "fade-in-level", &fade_in_level,
                "fade-in-time", &fade_in_time,
                NULL);

  g_assert_cmpfloat_with_epsilon (magnitude, 0.7, FLT_EPSILON);
  g_assert_cmpfloat_with_epsilon (fade_in_level, 0.3, FLT_EPSILON);
  g_assert_cmpint (fade_in_time, ==, 500);

  g_assert_finalize_object (object);
  g_assert_finalize_object (manager);
}


static void
test_fbd_feedback_vibra_periodic_fallback (void)
{
  /* Create manager upfront so we can dispose it, otherwise creating
   * any feedback would create it implicitly */
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  g_autoptr (GError) err = NULL;
  g_autoptr (JsonNode) node = NULL;
  GObject *object;
  double magnitude, fade_in_level;
  guint fade_in_time;

  node = json_from_string("{"
                          " \"event-name\"    : \"button-pressed\","
                          " \"type\"          : \"VibraPeriodic\","
                          " \"magnitude\"     : 65535,"
                          " \"fade-in-level\" : 13107"
                          "}", &err);
  g_assert_no_error (err);

  g_test_expect_message ("fbd-feedback-vibra-periodic",
                         G_LOG_LEVEL_WARNING,
                         "Too large magnitude 65535.00 detected*");
  g_test_expect_message ("fbd-feedback-vibra-periodic",
                         G_LOG_LEVEL_WARNING,
                         "Too large fade-in-level 13107.00 detected*");
  object = json_gobject_deserialize (FBD_TYPE_FEEDBACK_VIBRA_PERIODIC, node);
  g_test_assert_expected_messages ();

  g_object_get (object,
                "magnitude", &magnitude,
                "fade-in-level", &fade_in_level,
                "fade-in-time", &fade_in_time,
                NULL);

  g_assert_cmpfloat_with_epsilon (magnitude, 1.0, FLT_EPSILON);
  g_assert_cmpfloat_with_epsilon (fade_in_level, 0.2, FLT_EPSILON);
  g_assert_cmpint (fade_in_time, ==, 500);

  g_assert_finalize_object (object);
  g_assert_finalize_object (manager);
}


gint
main (gint argc, gchar *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func("/feedbackd/fbd/feedback-vibra/rumble", test_fbd_feedback_vibra_rumble);
  g_test_add_func("/feedbackd/fbd/feedback-vibra/pattern", test_fbd_feedback_vibra_pattern);
  g_test_add_func("/feedbackd/fbd/feedback-vibra/periodic", test_fbd_feedback_vibra_periodic);
  g_test_add_func("/feedbackd/fbd/feedback-vibra/periodic/fallback",
                  test_fbd_feedback_vibra_periodic_fallback);

  return g_test_run();
}
