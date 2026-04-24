/*
 * Copyright (C) 2024 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "fbd-haptic-manager"

#include "fbd-feedback-manager.h"
#include "fbd-haptic-manager.h"
#include "fbd-feedback-base.h"
#include "fbd-feedback-profile.h"
#include "fbd-feedback-vibra-pattern.h"

#include <glib.h>

#define MAX_ITEMS 10
#define MAX_LEN 10000

/**
 * FbdHapticManager:
 *
 * Handles the org.sigxcpu.Feedback.Haptic interface
 */

struct _FbdHapticManager {
  LfbGdbusFeedbackHapticSkeleton parent;

  FbdFeedbackVibraPattern       *vibra;
};

static void fbd_feedback_manager_feedback_haptic_iface_init (LfbGdbusFeedbackHapticIface *iface);

G_DEFINE_TYPE_WITH_CODE (FbdHapticManager,
                         fbd_haptic_manager,
                         LFB_GDBUS_TYPE_FEEDBACK_HAPTIC_SKELETON,
                         G_IMPLEMENT_INTERFACE (
                           LFB_GDBUS_TYPE_FEEDBACK_HAPTIC,
                           fbd_feedback_manager_feedback_haptic_iface_init));


/**
 * build_pattern:
 * @pattern: The pattern as GVariant
 * @out_magnitudes:(out): The magnitudes
 * @out_durations: The durations
 *
 * Parses the pattern (applying the limits) into an array of magnitudes
 * and durations.
 *
 * Returns: The `TRUE` if here were elements in the pattern, otherwise `FALSE`
 */
static gboolean
build_pattern (GVariant *pattern, GArray **out_magnitudes, GArray **out_durations)
{
  GVariantIter iter;
  GArray *durations, *magnitudes;
  double magnitude;
  guint duration, n_items;

  g_variant_iter_init (&iter, pattern);

  n_items = MIN (g_variant_iter_n_children (&iter), MAX_ITEMS);

  if (n_items == 0)
    return FALSE;

  durations = g_array_sized_new (FALSE, FALSE, sizeof (guint), n_items);
  magnitudes = g_array_sized_new (FALSE, FALSE, sizeof (double), n_items);

  for (guint pos = 0; pos < n_items; pos++) {
    g_variant_iter_next (&iter, "(du)", &magnitude, &duration);

    duration = MIN (duration, MAX_LEN);
    g_array_append_val (durations, duration);

    magnitude = MAX(0.0, MIN (magnitude, 1.0));
    g_array_append_val (magnitudes, magnitude);
  }

  *out_durations = durations;
  *out_magnitudes = magnitudes;

  return TRUE;
}


static gboolean
fbd_feedback_manager_handle_vibrate (LfbGdbusFeedbackHaptic *object,
                                     GDBusMethodInvocation  *invocation,
                                     const gchar            *app_id,
                                     GVariant               *pattern)
{
  FbdFeedbackManager *manager = fbd_feedback_manager_get_default ();
  FbdHapticManager *self = FBD_HAPTIC_MANAGER (object);
  FbdDevVibra *vibra_dev;
  FbdFeedbackProfileLevel level;
  gboolean non_empty;
  g_autoptr (FbdFeedbackVibraPattern) fb = NULL;
  g_autoptr (GArray) magnitudes = NULL, durations = NULL;

  g_debug ("Haptic triggered for %s", app_id);

  level = fbd_feedback_manager_get_effective_level (manager,
                                                    app_id,
                                                    FBD_FEEDBACK_PROFILE_LEVEL_QUIET,
                                                    FALSE);
  if (level < FBD_FEEDBACK_PROFILE_LEVEL_QUIET) {
    g_debug ("Feedback level too low for haptic");
    lfb_gdbus_feedback_haptic_complete_vibrate (object, invocation, FALSE);
    return TRUE;
  }

  vibra_dev = fbd_feedback_manager_get_dev_vibra (manager);
  if (!vibra_dev) {
    g_debug ("No haptic device");
    lfb_gdbus_feedback_haptic_complete_vibrate (object, invocation, FALSE);
    return TRUE;
  }

  non_empty = build_pattern (pattern, &magnitudes, &durations);
  if (!non_empty) {
    g_debug ("Empty pattern, ending feedback");
    fbd_haptic_manager_end_feedback (self);
    g_clear_object (&self->vibra);
    lfb_gdbus_feedback_haptic_complete_vibrate (object, invocation, TRUE);
    return TRUE;
  }

  if (self->vibra)
    fbd_feedback_end (FBD_FEEDBACK_BASE (self->vibra));
  if (fbd_dev_vibra_is_busy (vibra_dev)) {
    g_debug ("Haptic busy");
    /* If there's an event with haptic deny haptic pattern */
    lfb_gdbus_feedback_haptic_complete_vibrate (object, invocation, FALSE);
    return TRUE;
  }

  fb = fbd_feedback_vibra_pattern_new (magnitudes, durations);
  fbd_feedback_run (FBD_FEEDBACK_BASE (fb));
  self->vibra = g_steal_pointer (&fb);

  lfb_gdbus_feedback_haptic_complete_vibrate (object, invocation, TRUE);
  return TRUE;
}


static void
fbd_feedback_manager_feedback_haptic_iface_init (LfbGdbusFeedbackHapticIface *iface)
{
  iface->handle_vibrate = fbd_feedback_manager_handle_vibrate;
}


static void
fbd_haptic_manager_finalize (GObject *object)
{
  FbdHapticManager *self = FBD_HAPTIC_MANAGER (object);

  fbd_haptic_manager_end_feedback (self);

  G_OBJECT_CLASS (fbd_haptic_manager_parent_class)->finalize (object);
}


static void
fbd_haptic_manager_class_init (FbdHapticManagerClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->finalize = fbd_haptic_manager_finalize;
}


static void
fbd_haptic_manager_init (FbdHapticManager *self)
{
}


FbdHapticManager *
fbd_haptic_manager_new (void)
{
  return g_object_new (FBD_TYPE_HAPTIC_MANAGER, NULL);
}


void
fbd_haptic_manager_end_feedback (FbdHapticManager *self)
{
  g_return_if_fail (FBD_IS_HAPTIC_MANAGER (self));

  if (!self->vibra)
    return;

  fbd_feedback_end (FBD_FEEDBACK_BASE (self->vibra));
  g_clear_object (&self->vibra);
}
