/*
 * Copyright (C) 2024 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0+
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define GMOBILE_USE_UNSTABLE_API
#include "fbd-feedback-led.c"


static void
test_fbd_feedback_led_parse_color (void)
{
  FbdLedRgbColor rgb = { 0 };

  g_assert_true (parse_hex_color ("#11aaBB", &rgb));
  g_assert_cmpint (rgb.r, ==, 0x11);
  g_assert_cmpint (rgb.g, ==, 0xaa);
  g_assert_cmpint (rgb.b, ==, 0xbb);

  g_assert_true (parse_hex_color ("#000000", &rgb));
  g_assert_cmpint (rgb.r, ==, 0x00);
  g_assert_cmpint (rgb.g, ==, 0x00);
  g_assert_cmpint (rgb.b, ==, 0x00);

  g_assert_false (parse_hex_color ("#1bc", &rgb));
  g_assert_false (parse_hex_color ("11aaBB", &rgb));
  g_assert_false (parse_hex_color ("", &rgb));
  g_assert_false (parse_hex_color ("#", &rgb));
  g_assert_false (parse_hex_color ("#QWERTY", &rgb));
}


static void
test_fbd_feedback_led_color_string_to_color (void)
{
  FbdLedRgbColor rgb = { 0 };

  g_assert_cmpint (color_string_to_color ("red", FALSE, NULL), ==, FBD_FEEDBACK_LED_COLOR_RED);

  g_assert_cmpint (color_string_to_color ("#11aaBB", FALSE, &rgb), ==, FBD_FEEDBACK_LED_COLOR_RGB);
  g_assert_cmpint (rgb.r, ==, 0x11);
  g_assert_cmpint (rgb.g, ==, 0xaa);
  g_assert_cmpint (rgb.b, ==, 0xbb);

  g_assert_cmpint (color_string_to_color ("#00FF00", FALSE, &rgb), ==, FBD_FEEDBACK_LED_COLOR_RGB);
  g_assert_cmpint (rgb.r, ==, 0x00);
  g_assert_cmpint (rgb.g, ==, 0xFF);
  g_assert_cmpint (rgb.b, ==, 0x00);

  g_assert_cmpint (color_string_to_color ("#00FF00", TRUE, &rgb), ==, FBD_FEEDBACK_LED_COLOR_FLASH);
  g_assert_cmpint (rgb.r, ==, 0x00);
  g_assert_cmpint (rgb.g, ==, 0xFF);
  g_assert_cmpint (rgb.b, ==, 0x00);
}


gint
main (gint argc, gchar *argv[])
{
  g_test_init (&argc, &argv, NULL);

  g_test_add_func("/feedbackd/fbd/feedback-led/parse-color", test_fbd_feedback_led_parse_color);
  g_test_add_func("/feedbackd/fbd/feedback-led/color-string-to-color",
                  test_fbd_feedback_led_color_string_to_color);

  return g_test_run();
}
