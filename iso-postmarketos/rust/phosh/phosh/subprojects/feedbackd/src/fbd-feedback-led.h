/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0+
 */
#pragma once

#include "fbd-feedback-base.h"

G_BEGIN_DECLS

/**
 * FbdDevLedColor:
 * @FBD_FEEDBACK_LED_COLOR_WHITE: A white LED
 * @FBD_FEEDBACK_LED_COLOR_RED: A red LED
 * @FBD_FEEDBACK_LED_COLOR_GREEN: A green LED
 * @FBD_FEEDBACK_LED_COLOR_BLUE: A blue LED
 * @FBD_FEEDBACK_LED_COLOR_RGB: A multicolor LED that can display arbitrary RGB values
 * @FBD_FEEDBACK_LED_COLOR_FLASH: A flash (usually white)
 *
 * The color of a hardware LED.
 */
typedef enum _FbdFeedbackLedColor {
  FBD_FEEDBACK_LED_COLOR_WHITE = 0,
  FBD_FEEDBACK_LED_COLOR_RED = 1,
  FBD_FEEDBACK_LED_COLOR_GREEN = 2,
  FBD_FEEDBACK_LED_COLOR_BLUE = 3,
  FBD_FEEDBACK_LED_COLOR_RGB = 4,
  /* Keep this last in the list */
  FBD_FEEDBACK_LED_COLOR_FLASH = 5,
} FbdFeedbackLedColor;

typedef struct {
  guint r, g, b;
} FbdLedRgbColor;

#define FBD_TYPE_FEEDBACK_LED (fbd_feedback_led_get_type ())

G_DECLARE_FINAL_TYPE (FbdFeedbackLed, fbd_feedback_led, FBD, FEEDBACK_LED, FbdFeedbackBase);

G_END_DECLS
