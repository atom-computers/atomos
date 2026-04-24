/*
 * Copyright (C) 2025 The Phosh Developers
 *
 * SPDX-License-Identifier: LGPL-2.1+
 */
#pragma once

#include "lfb-gdbus.h"

#include <glib.h>

#if !defined (__LIBFEEDBACK_H_INSIDE__) && !defined (LIBFEEDBACK_COMPILATION)
#error "Only <libfeedback.h> can be included directly."
#endif

G_BEGIN_DECLS

gboolean    lfb_init (const gchar *app_id, GError **error);
void        lfb_uninit (void);
void        lfb_set_app_id (const char *app_id);
const char *lfb_get_app_id (void);
gboolean    lfb_is_initted (void);
void        lfb_set_feedback_profile (const char *profile);
const char *lfb_get_feedback_profile (void);
LfbGdbusFeedback *lfb_get_proxy (void);

G_END_DECLS
