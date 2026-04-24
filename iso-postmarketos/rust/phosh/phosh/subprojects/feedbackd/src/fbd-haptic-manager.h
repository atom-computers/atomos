/*
 * Copyright (C) 2024 The Phosh Developers
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#include "lfb-gdbus.h"
#include <glib-object.h>

G_BEGIN_DECLS

#define FBD_TYPE_HAPTIC_MANAGER (fbd_haptic_manager_get_type ())

G_DECLARE_FINAL_TYPE (FbdHapticManager, fbd_haptic_manager, FBD, HAPTIC_MANAGER,
                      LfbGdbusFeedbackHapticSkeleton)

FbdHapticManager *fbd_haptic_manager_new          (void);
void              fbd_haptic_manager_end_feedback (FbdHapticManager *self);


G_END_DECLS
