/*
 * Copyright (C) 2020 Purism SPC
 *
 * SPDX-License-Identifier: LGPL-2.1+
 */

#pragma once

#include <gio/gio.h>
#include "lfb-gdbus.h"

G_BEGIN_DECLS

LfbGdbusFeedback *_lfb_get_proxy (void);
void              _lfb_active_add_id (guint id);
void              _lfb_active_remove_id (guint id);

G_END_DECLS
