/*
 * Copyright (C) 2020 Purism SPC
 *               2025 The Phosh Developers
 *
 * SPDX-License-Identifier: LGPL-2.1+
 */
#pragma once

#include <glib.h>

G_BEGIN_DECLS

#define __LIBFEEDBACK_H_INSIDE__

#ifndef LIBFEEDBACK_USE_UNSTABLE_API
#error    LIBFEEDBACK is unstable API. You must define LIBFEEDBACK_USE_UNSTABLE_API before including libfeedback.h
#endif

#include "lfb-enums.h"
#include "lfb-event.h"
#include "lfb-gdbus.h"
#include "lfb-main.h"

G_END_DECLS
