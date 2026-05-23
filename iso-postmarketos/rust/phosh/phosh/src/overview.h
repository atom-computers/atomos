/*
 * Copyright (C) 2018 Purism SPC
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#include "app-grid.h"

#include <gtk/gtk.h>

G_BEGIN_DECLS

#define PHOSH_TYPE_OVERVIEW (phosh_overview_get_type ())

G_DECLARE_FINAL_TYPE (PhoshOverview, phosh_overview, PHOSH, OVERVIEW, GtkBox)


GtkWidget *phosh_overview_new (void);
void       phosh_overview_refresh (PhoshOverview *self);
void       phosh_overview_reset (PhoshOverview *self);
void       phosh_overview_focus_app_search (PhoshOverview *self);
gboolean   phosh_overview_has_running_activities (PhoshOverview *self);
gboolean   phosh_overview_handle_search (PhoshOverview *self, GdkEvent *event);
PhoshAppGrid *phosh_overview_get_app_grid (PhoshOverview *self);

/* AtomOS: hide just the running-activities carousel without affecting the
 * app grid. Used when the rust atomos-app-switcher overlay owns the
 * running-app switcher surface but PhoshOverview still needs to render its
 * launcher half (app grid + search). Sticky: subsequent has_activities
 * recalculations honour the force-hidden state instead of re-showing the
 * carousel when toplevel count flips 0 -> 1. */
void       phosh_overview_set_running_activities_visible (PhoshOverview *self,
                                                          gboolean       visible);

G_END_DECLS
