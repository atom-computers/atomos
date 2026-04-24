/*
 * Copyright (C) 2020 Purism SPC
 * SPDX-License-Identifier: GPL-3.0+
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#include "libfeedback.h"
#include <gio/gio.h>

typedef struct {
  GTestDBus *dbus;

} TestFixture;

GMainLoop *mainloop;

static void
fixture_setup (TestFixture *fixture, gconstpointer unused)
{
  g_autoptr (GError) err = NULL;
  gchar *relative, *servicesdir;
  gint success;

  fixture->dbus = g_test_dbus_new (G_TEST_DBUS_NONE);
  relative = g_test_build_filename (G_TEST_BUILT, "services", NULL);
  servicesdir = g_canonicalize_filename (relative, NULL);
  g_free (relative);

  g_test_dbus_add_service_dir (fixture->dbus, servicesdir);
  g_free (servicesdir);
  g_setenv ("FEEDBACK_THEME", TEST_DATA_DIR "/test.json", TRUE);
  g_setenv ("GSETTINGS_BACKEND", "memory", TRUE);
  g_test_dbus_up (fixture->dbus);

  g_assert_null (mainloop);
  mainloop = g_main_loop_new (NULL, FALSE);

  success = lfb_init (TEST_APP_ID, &err);
  g_assert_no_error (err);
  g_assert_true (success);
}

static void
fixture_teardown (TestFixture *fixture, gconstpointer unused)
{
  g_clear_pointer (&mainloop, g_main_loop_unref);
  lfb_uninit ();

  g_test_dbus_down (fixture->dbus);
  g_object_unref (fixture->dbus);
}

static void
on_feedback_ended (LfbEvent *event, LfbEvent **cmp)
{
  g_assert_true (LFB_IS_EVENT (event));
  g_assert_null (*cmp);

  g_debug ("Feedback ended for %s: %d",
	   lfb_event_get_event (event),
	   lfb_event_get_end_reason (event));

  g_assert_cmpint (lfb_event_get_state (event), ==, LFB_EVENT_STATE_ENDED);

  /* "Return" event */
  *cmp = event;
}

static void
test_lfb_integration_event_sync (void)
{
  g_autoptr(LfbEvent) event0 = NULL;
  g_autoptr(LfbEvent) event10 = NULL;
  g_autoptr (GError) err = NULL;
  LfbEvent *cmp = NULL;
  gboolean success;

  event0 = lfb_event_new ("test-dummy-0");
  success = lfb_event_trigger_feedback (event0, &err);
  g_assert_no_error (err);
  g_assert_true (success);

  event10 = lfb_event_new ("test-dummy-10");
  g_signal_connect (event10, "feedback-ended", (GCallback)on_feedback_ended, &cmp);
  g_signal_connect_swapped (event10, "feedback-ended", (GCallback)g_main_loop_quit, mainloop);
  success = lfb_event_trigger_feedback (event10, &err);
  g_assert_no_error (err);
  g_assert_true (success);

  success = lfb_event_end_feedback (event10, &err);
  g_assert_no_error (err);
  g_assert_true (success);

  g_main_loop_run (mainloop);

  /* If the signal fired cmp will match event */
  g_assert_true (event10 == cmp);
  g_assert_cmpint (lfb_event_get_state (event10), ==, LFB_EVENT_STATE_ENDED);
  g_assert_cmpint (lfb_event_get_end_reason (event10), ==, LFB_EVENT_END_REASON_EXPLICIT);
}

static void
test_lfb_integration_event_not_found (void)
{
  g_autoptr(LfbEvent) event0 = NULL;
  g_autoptr (GError) err = NULL;
  LfbEvent *cmp = NULL;
  gboolean success;

  event0 = lfb_event_new ("test-does-not-exist");
  g_signal_connect (event0, "feedback-ended", (GCallback)on_feedback_ended, &cmp);
  g_signal_connect_swapped (event0, "feedback-ended", (GCallback)g_main_loop_quit, mainloop);
  success = lfb_event_trigger_feedback (event0, &err);
  g_assert_no_error (err);
  g_assert_true (success);

  g_main_loop_run (mainloop);

  /* If the signal fired cmp will match event */
  g_assert_true (event0 == cmp);
  g_assert_cmpint (lfb_event_get_state (event0), ==, LFB_EVENT_STATE_ENDED);
  g_assert_cmpint (lfb_event_get_end_reason (event0), ==, LFB_EVENT_END_REASON_NOT_FOUND);
}

static void
on_event_triggered (LfbEvent      *event,
                    GAsyncResult  *res,
                    LfbEvent     **cmp)
{
  g_autoptr (GError) err = NULL;
  gboolean success;

  g_assert_true (LFB_IS_EVENT (event));
  g_assert_null (*cmp);

  g_debug ("%s: %p, %s", __func__, event, lfb_event_get_event (event));
  success = lfb_event_trigger_feedback_finish (event, res, &err);
  g_assert_no_error (err);
  g_assert_true (success);

  g_assert_cmpint (lfb_event_get_state (event), ==, LFB_EVENT_STATE_RUNNING);

  /* "Return" event */
  *cmp = event;
}

static void
on_event_triggered_quit (LfbEvent      *event,
                         GAsyncResult  *res,
                         LfbEvent     **cmp)
{
  g_autoptr (GError) err = NULL;
  gboolean success;

  g_assert_true (LFB_IS_EVENT (event));
  g_assert_null (*cmp);

  g_debug ("%s: %p, %s", __func__, event, lfb_event_get_event (event));
  success = lfb_event_trigger_feedback_finish (event, res, &err);
  g_assert_no_error (err);
  g_assert_true (success);

  g_assert_cmpint (lfb_event_get_state (event), ==, LFB_EVENT_STATE_RUNNING);

  /* "Return" event */
  *cmp = event;
  g_main_loop_quit (mainloop);
}

static void
on_event_end_finished (LfbEvent      *event,
                       GAsyncResult  *res,
                       LfbEvent     **cmp)
{
  g_autoptr (GError) err = NULL;
  gboolean success;

  g_debug ("%s: %p, %s", __func__, event, lfb_event_get_event (event));
  g_assert_true (LFB_IS_EVENT (event));
  g_assert_null (*cmp);

  success = lfb_event_end_feedback_finish (event, res, &err);
  g_assert_no_error (err);
  g_assert_true (success);

  /* This is not guaranteed for all types of feedback, see `feedback-ended` */
  g_assert_cmpint (lfb_event_get_state (event), ==, LFB_EVENT_STATE_ENDED);

  /* "Return" event */
  *cmp = event;
  g_main_loop_quit (mainloop);
}

static void
test_lfb_integration_event_not_found_async (void)
{
  g_autoptr(LfbEvent) event0 = NULL;
  LfbEvent *cmp = NULL;
  LfbEvent *cmp2 = NULL;

  event0 = lfb_event_new ("test-does-not-exist");
  g_signal_connect (event0, "feedback-ended", (GCallback)on_feedback_ended, &cmp2);

  /* The main loop will only quit if the "feedback-ended" signal actually gets emitted */
  g_signal_connect_swapped (event0, "feedback-ended", (GCallback)g_main_loop_quit, mainloop);

  lfb_event_trigger_feedback_async (event0,
                                    NULL,
                                    (GAsyncReadyCallback)on_event_triggered,
                                    &cmp);
  g_main_loop_run (mainloop);

  /* If the signal fired cmp will match event */
  g_assert_true (event0 == cmp);
  g_assert_true (event0 == cmp2);
  g_assert_cmpint (lfb_event_get_state (event0), ==, LFB_EVENT_STATE_ENDED);
  g_assert_cmpint (lfb_event_get_end_reason (event0), ==, LFB_EVENT_END_REASON_NOT_FOUND);
}

static void
test_lfb_integration_event_async (void)
{
  g_autoptr(LfbEvent) event0 = NULL;
  g_autoptr(LfbEvent) event10 = NULL;
  LfbEvent *cmp1 = NULL, *cmp2 = NULL, *cmp3 = NULL;

  event0 = lfb_event_new ("test-dummy-0");
  lfb_event_trigger_feedback_async (event0,
                                    NULL,
                                    (GAsyncReadyCallback)on_event_triggered_quit,
                                    &cmp1);
  g_main_loop_run (mainloop);
  /* The async finish callback saw the right event */
  g_assert_true (event0 == cmp1);
  cmp1 = NULL;

  event10 = lfb_event_new ("test-dummy-10");
  lfb_event_set_timeout (event10, 1);
  g_assert_cmpint (lfb_event_get_timeout (event10), ==, 1);
  lfb_event_set_feedback_profile (event10, "quiet");
  lfb_event_set_important (event10, FALSE);
  g_signal_connect (event10, "feedback-ended", (GCallback)on_feedback_ended, &cmp1);

  /* The async callback ends the main loop */
  lfb_event_trigger_feedback_async (event10,
                                    NULL,
                                    (GAsyncReadyCallback)on_event_triggered_quit,
                                    &cmp2);
  g_main_loop_run (mainloop);

  /* The async callback ends the main loop */
  lfb_event_end_feedback_async (event10,
                                NULL,
                                (GAsyncReadyCallback)on_event_end_finished,
                                &cmp3);
  g_main_loop_run (mainloop);

  /* Check if callbacks saw the right event */
  g_assert_true (event10 == cmp1);
  g_assert_true (event10 == cmp2);
  g_assert_true (event10 == cmp3);
  g_assert_cmpint (lfb_event_get_state (event10), ==, LFB_EVENT_STATE_ENDED);
  g_assert_cmpint (lfb_event_get_end_reason (event10), ==, LFB_EVENT_END_REASON_EXPLICIT);
}


static void
on_event_with_error_triggered (LfbEvent      *event,
			       GAsyncResult  *res,
			       LfbEvent     **cmp)
{
  g_autoptr (GError) err = NULL;
  gboolean success;

  g_debug ("%s: %p, %s", __func__, event, lfb_event_get_event (event));
  g_assert_true (LFB_IS_EVENT (event));
  g_assert_null (*cmp);

  success = lfb_event_end_feedback_finish (event, res, &err);
  g_assert_false (success);
  g_assert_error (err, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS);

  /* "Return" event */
  *cmp = event;
  g_main_loop_quit (mainloop);
}


static void
test_lfb_integration_event_async_error (void)
{
  g_autoptr(LfbEvent) event0 = NULL;
  LfbEvent *cmp1 = NULL;

  /* Empty event names are invalid */
  event0 = lfb_event_new ("");
  lfb_event_trigger_feedback_async (event0,
                                    NULL,
                                    (GAsyncReadyCallback)on_event_with_error_triggered,
                                    &cmp1);
  g_main_loop_run (mainloop);
  /* The async finish callback saw the right event */
  g_assert_true (event0 == cmp1);
}


static void
on_profile_changed (LfbGdbusFeedback *proxy, GParamSpec *psepc, const gchar **profile)
{
  g_assert_null (*profile);
  *profile = lfb_get_feedback_profile();
  g_debug("Set feedback profile to: '%s'", *profile);

  g_main_loop_quit (mainloop);
}

static void
test_lfb_integration_profile (void)
{
  LfbGdbusFeedback *proxy;
  gchar *cmp = NULL;

  g_assert_cmpstr (lfb_get_feedback_profile (), ==, "full");
  proxy = lfb_get_proxy ();
  g_assert_nonnull (proxy);

  lfb_set_feedback_profile ("quiet");
  g_signal_connect (proxy, "notify::profile", (GCallback)on_profile_changed, &cmp);
  g_main_loop_run (mainloop);
  g_assert_cmpstr (lfb_get_feedback_profile (), ==, "quiet");
  g_assert_cmpstr (cmp, ==, "quiet");
}

gint
main (gint argc, gchar *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add("/feedbackd/lfb-integration/event_sync", TestFixture, NULL,
             (gpointer)fixture_setup,
             (gpointer)test_lfb_integration_event_sync,
             (gpointer)fixture_teardown);

  g_test_add("/feedbackd/lfb-integration/event_async/success", TestFixture, NULL,
             (gpointer)fixture_setup,
             (gpointer)test_lfb_integration_event_async,
             (gpointer)fixture_teardown);

  g_test_add("/feedbackd/lfb-integration/event_async/error", TestFixture, NULL,
             (gpointer)fixture_setup,
             (gpointer)test_lfb_integration_event_async_error,
             (gpointer)fixture_teardown);

  g_test_add("/feedbackd/lfb-integration/event_not_found", TestFixture, NULL,
             (gpointer)fixture_setup,
             (gpointer)test_lfb_integration_event_not_found,
             (gpointer)fixture_teardown);

  g_test_add("/feedbackd/lfb-integration/event_not_found_async", TestFixture, NULL,
             (gpointer)fixture_setup,
             (gpointer)test_lfb_integration_event_not_found_async,
             (gpointer)fixture_teardown);

  g_test_add("/feedbackd/lfb-integration/profile", TestFixture, NULL,
             (gpointer)fixture_setup,
             (gpointer)test_lfb_integration_profile,
             (gpointer)fixture_teardown);

  return g_test_run();
}
