/*
 * Copyright (C) 2022 Guido Günther <agx@sigxcpu.org>
 *
 * SPDX-License-Identifier: GPL-3.0+
 */

#include "fbd-feedback-dummy.h"
#include "fbd-theme-expander.h"

#include <json-glib/json-glib.h>


static void
test_fbd_theme_expander_object (void)
{
  g_autoptr (FbdThemeExpander) expander = g_object_new (FBD_TYPE_THEME_EXPANDER, NULL);

  g_assert_cmpstr ("default", ==, fbd_theme_expander_get_theme_name (expander));
  g_assert_null (fbd_theme_expander_get_theme_file (expander));
  g_assert_null (fbd_theme_expander_get_compatibles (expander));
}

static void
test_fbd_theme_expander_device (void)
{
  g_autoptr (GError) err = NULL;
  const char *compatibles[] = { NULL, NULL };
  FbdFeedbackProfile *profile;
  FbdThemeExpander *expander;
  FbdFeedbackTheme *theme;
  FbdFeedbackBase *fb;
  const char *const *compatibles2;

  /* just the default profile */
  compatibles[0] = "doesnotexist";
  expander = fbd_theme_expander_new (compatibles, NULL, NULL);
  g_assert_cmpstr ("default", ==, fbd_theme_expander_get_theme_name (expander));

  theme = fbd_theme_expander_load_theme_files (expander, &err);
  compatibles2 = fbd_theme_expander_get_compatibles (expander);
#if GLIB_CHECK_VERSION(2, 68, 0)
  g_assert_cmpstrv (compatibles2, compatibles);
#endif
  g_assert_no_error (err);
  profile = fbd_feedback_theme_get_profile (theme, "silent");
  g_assert_null (profile);
  profile = fbd_feedback_theme_get_profile (theme, "quiet");
  g_assert_true (FBD_IS_FEEDBACK_PROFILE(profile));
  profile = fbd_feedback_theme_get_profile (theme, "full");
  g_assert_true (FBD_IS_FEEDBACK_PROFILE(profile));
  g_assert_finalize_object (theme);
  g_assert_finalize_object (expander);

  /* Empty device theme that just chains up */
  compatibles[0] = "chainup";
  expander = fbd_theme_expander_new (compatibles, NULL, NULL);
  compatibles2 = fbd_theme_expander_get_compatibles (expander);
#if GLIB_CHECK_VERSION(2, 68, 0)
  g_assert_cmpstrv (compatibles2, compatibles);
#endif
  theme = fbd_theme_expander_load_theme_files (expander, &err);
  g_assert_no_error (err);
  profile = fbd_feedback_theme_get_profile (theme, "silent");
  g_assert_null (profile);
  profile = fbd_feedback_theme_get_profile (theme, "quiet");
  g_assert_true (FBD_IS_FEEDBACK_PROFILE(profile));
  profile = fbd_feedback_theme_get_profile (theme, "full");
  g_assert_true (FBD_IS_FEEDBACK_PROFILE(profile));
  g_assert_finalize_object (theme);
  g_assert_finalize_object (expander);

  /* Replace an existing event */
  compatibles[0] = "replace";
  expander = fbd_theme_expander_new (compatibles, NULL, NULL);
  compatibles2 = fbd_theme_expander_get_compatibles (expander);
#if GLIB_CHECK_VERSION(2, 68, 0)
  g_assert_cmpstrv (compatibles2, compatibles);
#endif
  theme = fbd_theme_expander_load_theme_files (expander, &err);
  g_assert_no_error (err);
  profile = fbd_feedback_theme_get_profile (theme, "full");
  g_assert_true (FBD_IS_FEEDBACK_PROFILE(profile));
  fb = fbd_feedback_profile_get_feedback (profile, "test-dummy-0");
  g_assert_cmpstr ("test-dummy-0", ==, fbd_feedback_get_event_name (fb));
  g_assert_cmpint (fbd_feedback_dummy_get_duration (FBD_FEEDBACK_DUMMY (fb)), ==, 0x10);
  g_assert_true (FBD_IS_FEEDBACK_PROFILE(profile));
  fb = fbd_feedback_profile_get_feedback (profile, "test-dummy-2");
  g_assert_cmpstr ("test-dummy-2", ==, fbd_feedback_get_event_name (fb));
  g_assert_cmpint (fbd_feedback_dummy_get_duration (FBD_FEEDBACK_DUMMY (fb)), ==, 0x20);
  g_assert_finalize_object (theme);
  g_assert_finalize_object (expander);
}

static void
test_fbd_theme_expander_custom (void)
{
  g_autoptr (GError) err = NULL;
  const char *compatibles[] = { NULL, NULL };
  FbdFeedbackProfile *profile;
  FbdThemeExpander *expander;
  FbdFeedbackTheme *theme;
  FbdFeedbackBase *fb;

  /* Load a custom theme that overrides a single event on top of the `replace` from above */
  compatibles[0] = "replace";
  expander = fbd_theme_expander_new (compatibles, "custom", NULL);
  theme = fbd_theme_expander_load_theme_files (expander, &err);
  g_assert_no_error (err);
  profile = fbd_feedback_theme_get_profile (theme, "full");
  g_assert_true (FBD_IS_FEEDBACK_PROFILE(profile));
  fb = fbd_feedback_profile_get_feedback (profile, "test-dummy-0");
  g_assert_cmpstr ("test-dummy-0", ==, fbd_feedback_get_event_name (fb));
  g_assert_cmpint (fbd_feedback_dummy_get_duration (FBD_FEEDBACK_DUMMY (fb)), ==, 0x10);
  g_assert_true (FBD_IS_FEEDBACK_PROFILE(profile));
  fb = fbd_feedback_profile_get_feedback (profile, "test-dummy-2");
  g_assert_cmpstr ("test-dummy-2", ==, fbd_feedback_get_event_name (fb));
  g_assert_cmpint (fbd_feedback_dummy_get_duration (FBD_FEEDBACK_DUMMY (fb)), ==, 0x30);
  g_assert_finalize_object (theme);
  g_assert_finalize_object (expander);
}

gint
main (int argc, char *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func("/feedbackd/fbd/theme-expander/object", test_fbd_theme_expander_object);
  g_test_add_func("/feedbackd/fbd/theme-expander/device", test_fbd_theme_expander_device);
  g_test_add_func("/feedbackd/fbd/theme-expander/custom", test_fbd_theme_expander_custom);

  return g_test_run();
}
