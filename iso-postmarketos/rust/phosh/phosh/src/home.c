/*
 * Copyright (C) 2018-2022 Purism SPC
 *               2023-2024 Guido Günther
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Author: Guido Günther <agx@sigxcpu.org>
 */

#define G_LOG_DOMAIN "phosh-home"

#include "phosh-config.h"
#include "layersurface-priv.h"
#include "overview.h"
#include "home.h"
#include "shell-priv.h"
#include "phosh-enums.h"
#include "osk-manager.h"
#include "style-manager.h"
#include "feedback-manager.h"
#include "util.h"

#include <handy.h>

#define KEYBINDINGS_SCHEMA_ID "org.gnome.shell.keybindings"
#define KEYBINDING_KEY_TOGGLE_OVERVIEW "toggle-overview"
#define KEYBINDING_KEY_TOGGLE_APPLICATION_VIEW "toggle-application-view"

#define PHOSH_SETTINGS "sm.puri.phosh"

#define PHOSH_HOME_DRAG_THRESHOLD 0.3

#define POWERBAR_ACTIVE_CLASS "p-active"
#define POWERBAR_FAILED_CLASS "p-failed"
#define ATOMOS_CHAT_SUBMIT_PATH "/usr/libexec/atomos-overview-chat-submit"
#define ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS_ENV "ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS"
#define ATOMOS_PHOSH_HOME_TRACE_ENV "ATOMOS_PHOSH_HOME_TRACE"
#define ATOMOS_PHOSH_ENABLE_APP_GRID_TOGGLE_ENV "ATOMOS_PHOSH_ENABLE_APP_GRID_TOGGLE"

/* Chat strip matches atomos-overview-chat-ui. */
#define ATOMOS_OVERVIEW_CHAT_UI_CSS                               \
  "box.atomos-chat-wrap {\n"                                      \
  "  padding: 12px;\n"                                            \
  "}\n"                                                           \
  "entry.atomos-chat-input {\n"                                   \
  "  border-radius: 16px;\n"                                      \
  "  background: alpha(#151923, 0.58);\n"                         \
  "  color: #ffffff;\n"                                           \
  "  border: 1px solid alpha(#ffffff, 0.22);\n"                  \
  "  box-shadow: none;\n"                                         \
  "  padding: 10px 14px;\n"                                       \
  "}\n"                                                           \
  "entry.atomos-chat-input:focus {\n"                             \
  "  box-shadow: none;\n"                                         \
  "}\n"                                                           \
  "phosh-home box.atomos-app-grid-row {\n"                        \
  "  padding: 8px 12px 0 12px;\n"                                 \
  "}\n"                                                           \
  "phosh-home button.atomos-dock-btn {\n"                         \
  "  min-width: 42px;\n"                                          \
  "  min-height: 42px;\n"                                         \
  "  border-radius: 9999px;\n"                                    \
  "  padding: 0;\n"                                               \
  "  border: 1px solid #303132;\n"                                \
  "}\n"                                                           \
  "phosh-home button.atomos-dock-btn image {\n"                   \
  "  -gtk-icon-size: 22px;\n"                                     \
  "}\n"                                                           \
  "phosh-home.atomos-dark button.atomos-dock-btn {\n"             \
  "  background: #121212;\n"                                      \
  "  color: #ffffff;\n"                                           \
  "}\n"                                                           \
  "phosh-home.atomos-light button.atomos-dock-btn {\n"           \
  "  background: #f2f2f2;\n"                                      \
  "  color: #121212;\n"                                           \
  "}\n"                                                           \
  "phosh-home .atomos-app-sheet-wrap {\n"                         \
  "  margin: 18px 0 0 0;\n"                                       \
  "  border-radius: 40px;\n"                                      \
  "  border: 1px solid #303132;\n"                                \
  "}\n"                                                           \
  "phosh-home.atomos-dark .atomos-app-sheet-wrap,\n"              \
  "phosh-home.atomos-dark .atomos-app-sheet {\n"                  \
  "  background-image: none;\n"                                   \
  "  background-color: #121212;\n"                                \
  "}\n"                                                           \
  "phosh-home.atomos-light .atomos-app-sheet-wrap,\n"             \
  "phosh-home.atomos-light .atomos-app-sheet {\n"                 \
  "  background-image: none;\n"                                   \
  "  background-color: #f2f2f2;\n"                                \
  "}\n"                                                           \
  "phosh-home .atomos-app-sheet {\n"                              \
  "  border-radius: 40px;\n"                                      \
  "}\n"                                                           \
  "phosh-home button.atomos-app-tile {\n"                         \
  "  min-width: 0;\n"                                             \
  "  min-height: 0;\n"                                            \
  "  padding: 0;\n"                                               \
  "  background: transparent;\n"                                  \
  "  color: inherit;\n"                                           \
  "  border: none;\n"                                             \
  "  box-shadow: none;\n"                                         \
  "}\n"                                                           \
  "phosh-home button.atomos-app-tile:hover,\n"                    \
  "phosh-home button.atomos-app-tile:active {\n"                  \
  "  background: transparent;\n"                                  \
  "  box-shadow: none;\n"                                         \
  "}\n"                                                           \
  "phosh-home label.atomos-app-label {\n"                         \
  "  color: inherit;\n"                                           \
  "  font-size: 10px;\n"                                          \
  "}\n"

/**
 * PhoshHome:
 *
 * The home surface contains the overview and the home bar to fold and unfold the overview.
 *
 * #PhoshHome contains the #PhoshOverview that manages running
 * applications and the app grid. It also manages a bar at the
 * bottom of the screen to fold and unfold the #PhoshOverview and a
 * pill in the center (powerbar) that toggles the OSK.
 */

enum {
  PROP_0,
  PROP_HOME_STATE,
  PROP_OSK_ENABLED,
  PROP_LAST_PROP,
};
static GParamSpec *props[PROP_LAST_PROP];


struct _PhoshHome
{
  PhoshDragSurface parent;

  GtkWidget *overview;
  GtkWidget *home_bar;
  GtkWidget *rev_powerbar;
  GtkWidget *powerbar;
  GtkWidget *evbox_home_bar;
  GtkWidget *app_grid_toggle_button;
  GtkWidget *app_grid_toggle_icon;
  GtkWidget *chat_entry;

  guint      debounce_handle;
  gboolean   focus_app_search;

  PhoshHomeState state;

  /* Keybinding */
  GStrv           action_names;
  GSettings      *settings;

  /* osk button */
  gboolean        osk_enabled;

  GtkGesture     *click_gesture; /* needed so that the gesture isn't destroyed immediately */
  GtkGesture     *osk_toggle_long_press; /* to toggle osk from the home bar itself */
  GtkGesture     *chat_dismiss_tap; /* clears entry focus when tapping outside input */
  GSettings      *phosh_settings;

  PhoshMonitor    *monitor;
  PhoshBackground *background;
  gboolean         use_background;
  gint             last_reference_height;
  gboolean         app_grid_toggle_queued;
  gboolean         ui_stable_for_popups;
  guint            unfold_stable_source;
};
G_DEFINE_TYPE(PhoshHome, phosh_home, PHOSH_TYPE_DRAG_SURFACE);

static gboolean
phosh_home_trace_enabled (void)
{
  static gsize once = 0;
  static gboolean enabled = FALSE;

  if (g_once_init_enter (&once)) {
    enabled = g_strcmp0 (g_getenv (ATOMOS_PHOSH_HOME_TRACE_ENV), "1") == 0;
    g_once_init_leave (&once, 1);
  }
  return enabled;
}

#define HOME_TRACE(...) \
  G_STMT_START { \
    if (phosh_home_trace_enabled ()) \
      g_message ("atomos-phosh-home-trace: " __VA_ARGS__); \
  } G_STMT_END

static gboolean
app_grid_toggle_enabled (void)
{
  static gsize once = 0;
  static gboolean enabled = TRUE;

  if (g_once_init_enter (&once)) {
    const char *env = g_getenv (ATOMOS_PHOSH_ENABLE_APP_GRID_TOGGLE_ENV);
    /* Enabled by default; allow explicit opt-out with env=0. */
    enabled = g_strcmp0 (env, "0") != 0;
    g_once_init_leave (&once, 1);
  }
  return enabled;
}


static void
phosh_home_update_atomos_visual_theme (PhoshHome *self);
static void phosh_home_sync_chat_strip_visibility (PhoshHome *self);
static void phosh_home_enforce_safe_widget_state (PhoshHome *self);
static void phosh_home_style_app_grid_widgets (PhoshHome *self);
static void update_drag_handle (PhoshHome *self, gboolean queue_draw);
static gboolean apply_queued_app_grid_toggle_idle (gpointer data);

static gboolean
mark_ui_stable_for_popups_timeout (gpointer data)
{
  PhoshHome *self = PHOSH_HOME (data);

  if (!PHOSH_IS_HOME (self))
    return G_SOURCE_REMOVE;

  self->unfold_stable_source = 0;
  if (self->state != PHOSH_HOME_STATE_UNFOLDED)
    return G_SOURCE_REMOVE;
  if (!gtk_widget_get_mapped (GTK_WIDGET (self->overview)))
    return G_SOURCE_REMOVE;

  self->ui_stable_for_popups = TRUE;
  HOME_TRACE ("ui marked stable for popup-producing actions");

  if (self->app_grid_toggle_queued)
    g_idle_add (apply_queued_app_grid_toggle_idle, self);

  return G_SOURCE_REMOVE;
}

static void
schedule_ui_stable_gate (PhoshHome *self)
{
  if (self->unfold_stable_source != 0)
    g_clear_handle_id (&self->unfold_stable_source, g_source_remove);
  self->ui_stable_for_popups = FALSE;
  self->unfold_stable_source = g_timeout_add (160, mark_ui_stable_for_popups_timeout, self);
  g_source_set_name_by_id (self->unfold_stable_source, "[phosh] mark_ui_stable_for_popups");
}

static void
on_gtk_settings_atomos_theme (GtkSettings *settings, GParamSpec *pspec, PhoshHome *self)
{
  phosh_home_update_atomos_visual_theme (self);
}


static void
install_atomos_overview_chat_ui_css_once (void)
{
  static gsize once = 0;

  if (g_once_init_enter (&once)) {
    if (g_strcmp0 (g_getenv (ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS_ENV), "1") == 0) {
      g_debug ("atomos-overview-chat-ui: custom CSS disabled by env");
    } else {
      g_autoptr (GtkCssProvider) provider = gtk_css_provider_new ();

      gtk_css_provider_load_from_data (provider, ATOMOS_OVERVIEW_CHAT_UI_CSS, -1, NULL);
      gtk_style_context_add_provider_for_screen (gdk_screen_get_default (),
                                                 GTK_STYLE_PROVIDER (provider),
                                                 GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 20);
    }
    g_once_init_leave (&once, 1);
  }
}


static void
phosh_home_update_atomos_visual_theme (PhoshHome *self)
{
  gboolean prefer_dark = TRUE;
  gboolean use_light_variant = FALSE;
  GtkSettings *gtk_settings = gtk_settings_get_default ();
  PhoshShell *shell = phosh_shell_get_default ();
  PhoshStyleManager *sm = phosh_shell_get_style_manager (shell);
  const char *tn = phosh_style_manager_get_theme_name (sm);

  g_return_if_fail (PHOSH_IS_HOME (self));

  g_object_get (gtk_settings, "gtk-application-prefer-dark-theme", &prefer_dark, NULL);

  use_light_variant = phosh_style_manager_is_high_contrast (sm) || !prefer_dark;
  if (tn) {
    if (g_strstr_len (tn, -1, "dark") != NULL || g_strstr_len (tn, -1, "Dark") != NULL)
      use_light_variant = FALSE;
    if (g_strstr_len (tn, -1, "Inverse") != NULL)
      use_light_variant = FALSE;
  }

  phosh_util_toggle_style_class (GTK_WIDGET (self), "atomos-dark", !use_light_variant);
  phosh_util_toggle_style_class (GTK_WIDGET (self), "atomos-light", use_light_variant);
}


static void
phosh_home_sync_chat_strip_visibility (PhoshHome *self)
{
  GtkWidget *wrap;
  gboolean show = FALSE;
  PhoshAppGrid *app_grid;

  if (!self->chat_entry)
    return;

  wrap = gtk_widget_get_parent (self->chat_entry);
  if (!wrap)
    return;

  if (self->state == PHOSH_HOME_STATE_UNFOLDED) {
    app_grid = phosh_overview_get_app_grid (PHOSH_OVERVIEW (self->overview));
    show = !gtk_widget_get_visible (GTK_WIDGET (app_grid));
  }

  gtk_widget_set_visible (wrap, show);
  gtk_widget_set_visible (self->chat_entry, show);
}


static void
phosh_home_enforce_safe_widget_state (PhoshHome *self)
{
  PhoshAppGrid *app_grid;
  gboolean safe_for_popup_actions;

  safe_for_popup_actions = self->state == PHOSH_HOME_STATE_UNFOLDED &&
                           self->ui_stable_for_popups &&
                           gtk_widget_get_mapped (GTK_WIDGET (self->overview));
  if (safe_for_popup_actions)
    return;

  app_grid = phosh_overview_get_app_grid (PHOSH_OVERVIEW (self->overview));
  if (gtk_widget_get_visible (GTK_WIDGET (app_grid))) {
    gtk_widget_set_visible (GTK_WIDGET (app_grid), FALSE);
    HOME_TRACE ("forcing app-grid hidden while state=%d stable=%d mapped=%d",
                self->state,
                self->ui_stable_for_popups,
                gtk_widget_get_mapped (GTK_WIDGET (self->overview)));
    update_drag_handle (self, TRUE);
  }

  if (self->app_grid_toggle_icon) {
    gtk_image_set_from_icon_name (GTK_IMAGE (self->app_grid_toggle_icon),
                                  "view-app-grid-symbolic",
                                  GTK_ICON_SIZE_BUTTON);
  }
}


static void
style_app_grid_children_cb (GtkWidget *child, gpointer user_data)
{
  (void) user_data;

  if (GTK_IS_BUTTON (child)) {
    gtk_style_context_add_class (gtk_widget_get_style_context (child), "atomos-app-tile");
  } else if (GTK_IS_LABEL (child)) {
    gtk_style_context_add_class (gtk_widget_get_style_context (child), "atomos-app-label");
  }

  if (GTK_IS_CONTAINER (child))
    gtk_container_forall (GTK_CONTAINER (child), style_app_grid_children_cb, NULL);
}


static void
phosh_home_style_app_grid_widgets (PhoshHome *self)
{
  PhoshAppGrid *app_grid;
  GtkWidget *app_grid_widget;
  GtkWidget *app_grid_parent;

  g_return_if_fail (PHOSH_IS_HOME (self));

  app_grid = phosh_overview_get_app_grid (PHOSH_OVERVIEW (self->overview));
  app_grid_widget = GTK_WIDGET (app_grid);
  app_grid_parent = gtk_widget_get_parent (app_grid_widget);

  gtk_style_context_add_class (gtk_widget_get_style_context (app_grid_widget), "atomos-app-sheet");
  if (app_grid_parent)
    gtk_style_context_add_class (gtk_widget_get_style_context (app_grid_parent), "atomos-app-sheet-wrap");

  if (GTK_IS_CONTAINER (app_grid_widget))
    gtk_container_forall (GTK_CONTAINER (app_grid_widget), style_app_grid_children_cb, NULL);
}


static void
on_chat_dismiss_tap_pressed (GtkGestureMultiPress *gesture,
                             gint                  n_press,
                             gdouble               x,
                             gdouble               y,
                             PhoshHome            *self)
{
  GtkAllocation alloc;
  gint ex = 0, ey = 0;
  gboolean inside_entry;

  (void) gesture;
  (void) n_press;

  g_return_if_fail (PHOSH_IS_HOME (self));

  if (!self->chat_entry || !gtk_widget_get_visible (self->chat_entry))
    return;

  if (self->state != PHOSH_HOME_STATE_UNFOLDED)
    return;

  if (!gtk_widget_translate_coordinates (self->chat_entry, GTK_WIDGET (self), 0, 0, &ex, &ey))
    return;

  gtk_widget_get_allocation (self->chat_entry, &alloc);
  inside_entry = x >= ex && x <= (ex + alloc.width) && y >= ey && y <= (ey + alloc.height);

  if (!inside_entry)
    gtk_window_set_focus (GTK_WINDOW (self), NULL);
}


static void
phosh_home_update_home_bar (PhoshHome *self)
{
  gboolean reveal, solid = TRUE;
  PhoshDragSurfaceState drag_state = phosh_drag_surface_get_drag_state (PHOSH_DRAG_SURFACE (self));

  reveal = !(self->state == PHOSH_HOME_STATE_UNFOLDED);
  gtk_revealer_set_reveal_child (GTK_REVEALER (self->rev_powerbar), reveal);

  if (self->use_background)
    solid = !!(self->state == PHOSH_HOME_STATE_FOLDED && drag_state != PHOSH_DRAG_SURFACE_STATE_DRAGGED);

  phosh_util_toggle_style_class (self->evbox_home_bar, "p-solid", solid);

  phosh_home_enforce_safe_widget_state (self);
  phosh_home_sync_chat_strip_visibility (self);
}


static void
phosh_home_set_property (GObject      *object,
                         guint         property_id,
                         const GValue *value,
                         GParamSpec   *pspec)
{
  PhoshHome *self = PHOSH_HOME (object);

  switch (property_id) {
  case PROP_HOME_STATE:
    phosh_home_set_state (self, g_value_get_enum (value));
    break;
  case PROP_OSK_ENABLED:
    self->osk_enabled = g_value_get_boolean (value);
    g_object_notify_by_pspec (G_OBJECT (self), props[PROP_OSK_ENABLED]);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
phosh_home_get_property (GObject    *object,
                         guint       property_id,
                         GValue     *value,
                         GParamSpec *pspec)
{
  PhoshHome *self = PHOSH_HOME (object);

  switch (property_id) {
  case PROP_HOME_STATE:
    g_value_set_enum (value, self->state);
    break;
  case PROP_OSK_ENABLED:
    g_value_set_boolean (value, self->osk_enabled);
    break;
  default:
    G_OBJECT_WARN_INVALID_PROPERTY_ID (object, property_id, pspec);
    break;
  }
}


static void
update_drag_handle (PhoshHome *self, gboolean queue_draw)
{
  gboolean success;
  gint handle = 0;
  guint previous_handle = 0;
  PhoshAppGrid *app_grid;
  PhoshDragSurfaceDragMode drag_mode = PHOSH_DRAG_SURFACE_DRAG_MODE_NONE;

  /* reset osk_toggle_long_press to prevent OSK from unfolding accidentally */
  gtk_event_controller_reset (GTK_EVENT_CONTROLLER (self->osk_toggle_long_press));

  app_grid = phosh_overview_get_app_grid (PHOSH_OVERVIEW (self->overview));

  /* AtomOS: disable drag gestures for the entire home surface in all states.
   * Folding/unfolding should only happen via explicit actions, never swipes. */
  phosh_drag_surface_set_drag_mode (PHOSH_DRAG_SURFACE (self), drag_mode);

  /* Update handle size */
  success = gtk_widget_translate_coordinates (GTK_WIDGET (app_grid),
                                              GTK_WIDGET (self),
                                              0, 0, NULL, &handle);
  previous_handle = phosh_drag_surface_get_drag_handle (PHOSH_DRAG_SURFACE (self));
  if (!success) {
    /* App-grid can be hidden/unmapped during transitions and while toggling.
     * In that case, keep the last valid drag handle so the home surface
     * doesn't collapse into a tiny draggable strip. */
    g_debug ("Failed to get handle position; keeping previous drag handle");
    if (previous_handle > 0) {
      handle = (gint) previous_handle;
    } else {
      handle = PHOSH_HOME_BAR_HEIGHT;
    }
  }

  g_debug ("Drag Handle: %d", handle);
  phosh_drag_surface_set_drag_handle (PHOSH_DRAG_SURFACE (self), handle);
  /* Trigger redraw and surface commit */
  if (queue_draw)
    gtk_widget_queue_draw (GTK_WIDGET (self));
}


static int
get_margin (gint height)
{
  return (-1 * height) + PHOSH_HOME_BAR_HEIGHT;
}


/* Folded margin must track the physical display height. Spurious smaller
 * Gtk configure heights (e.g. during transitions) shrink the layer and look
 * like a bottom sheet; clamp to the monitor the surface is on. */
static gint
reference_height_for_margin (PhoshHome *self, gint configured_height)
{
  GtkWidget *widget = GTK_WIDGET (self);
  GdkWindow *win;
  GdkDisplay *display;
  GdkMonitor *monitor;
  GdkRectangle geom;
  gint monitor_height = 0;
  gint ref_height;

  g_return_val_if_fail (PHOSH_IS_HOME (self), configured_height);

  ref_height = configured_height;

  win = gtk_widget_get_window (widget);
  if (win) {
    display = gdk_window_get_display (win);
    monitor = gdk_display_get_monitor_at_window (display, win);
    if (monitor) {
      gdk_monitor_get_geometry (monitor, &geom);
      if (geom.height > 0)
        monitor_height = geom.height;
    }
  }

  if (monitor_height > 0)
    ref_height = MAX (ref_height, monitor_height);

  if (ref_height <= PHOSH_HOME_BAR_HEIGHT) {
    if (self->last_reference_height > PHOSH_HOME_BAR_HEIGHT) {
      ref_height = self->last_reference_height;
    } else if (monitor_height > PHOSH_HOME_BAR_HEIGHT) {
      ref_height = monitor_height;
    } else {
      ref_height = PHOSH_HOME_BAR_HEIGHT + 1;
    }
  }

  self->last_reference_height = MAX (self->last_reference_height, ref_height);
  return ref_height;
}


static gboolean
on_configure_event (PhoshHome *self, GdkEventConfigure *event)
{
  guint margin;
  gint ref_height;
  PhoshDragSurfaceState drag_state;

  /* ignore popovers like the power menu */
  if (gtk_widget_get_window (GTK_WIDGET (self)) != event->window)
    return FALSE;

  drag_state = phosh_drag_surface_get_drag_state (PHOSH_DRAG_SURFACE (self));
  if (drag_state == PHOSH_DRAG_SURFACE_STATE_DRAGGED)
    return FALSE;

  ref_height = reference_height_for_margin (self, event->height);
  margin = get_margin (ref_height);

  HOME_TRACE ("configure-event h=%d ref=%d margin=%d drag_state=%d",
              event->height,
              ref_height,
              margin,
              phosh_drag_surface_get_drag_state (PHOSH_DRAG_SURFACE (self)));
  g_debug ("%s: %dx%d (ref %d), margin: %d", __func__, event->height, event->width, ref_height, margin);

  /* If the size changes we need to update the folded margin */
  phosh_drag_surface_set_margin (PHOSH_DRAG_SURFACE (self), margin, 0);
  /* Update drag handle since overview size might have changed */
  update_drag_handle (self, TRUE);

  return FALSE;
}


static void
phosh_home_map (GtkWidget *widget)
{
  PhoshHome *self = PHOSH_HOME (widget);

  GTK_WIDGET_CLASS (phosh_home_parent_class)->map (widget);

  phosh_layer_surface_set_stacked_below (PHOSH_LAYER_SURFACE (self->background),
                                         PHOSH_LAYER_SURFACE (self));
}


static void
on_home_released (GtkButton *button, int n_press, double x, double y, GtkGestureMultiPress *gesture)
{
  PhoshHome *self = g_object_get_data (G_OBJECT (gesture), "phosh-home");

  g_return_if_fail (PHOSH_IS_HOME (self));
  /* AtomOS: home-bar tap should not toggle fold/unfold. */
  (void) button;
  (void) n_press;
  (void) x;
  (void) y;
}


static void
on_powerbar_action_started (PhoshHome *self)
{
  g_debug ("powerbar action started");
  phosh_util_toggle_style_class (self->home_bar, POWERBAR_FAILED_CLASS, FALSE);
  phosh_util_toggle_style_class (self->home_bar, POWERBAR_ACTIVE_CLASS, TRUE);
}


static void
on_powerbar_action_ended (PhoshHome *self)
{
  g_debug ("powerbar action ended");
  phosh_util_toggle_style_class (self->home_bar, POWERBAR_ACTIVE_CLASS, FALSE);
  phosh_util_toggle_style_class (self->home_bar, POWERBAR_FAILED_CLASS, FALSE);
}


static void
on_powerbar_action_failed (PhoshHome *self)
{
  g_debug ("powerbar action failed");
  phosh_util_toggle_style_class (self->home_bar, POWERBAR_ACTIVE_CLASS, FALSE);
  phosh_util_toggle_style_class (self->home_bar, POWERBAR_FAILED_CLASS, TRUE);
}


static void
on_powerbar_pressed (PhoshHome *self)
{
  PhoshOskManager *osk;
  gboolean osk_is_available, osk_current_state, osk_new_state;

  g_return_if_fail (PHOSH_IS_HOME (self));

  osk = phosh_shell_get_osk_manager (phosh_shell_get_default ());

  osk_is_available = phosh_osk_manager_get_available (osk);
  osk_current_state = phosh_osk_manager_get_visible (osk);
  osk_new_state = osk_current_state;

  gtk_gesture_set_state ((self->click_gesture), GTK_EVENT_SEQUENCE_DENIED);

  if (osk_is_available) {
    osk_new_state = !osk_current_state;
    on_powerbar_action_ended (self);
  } else {
    on_powerbar_action_failed (self);
    return;
  }

  g_debug ("OSK toggled with pressed signal");
  phosh_osk_manager_set_visible (osk, osk_new_state);

  phosh_trigger_feedback ("button-pressed");
}


static void
on_chat_entry_activate (GtkEntry *entry, PhoshHome *self)
{
  const char *text = gtk_entry_get_text (entry);
  g_autofree char *command = g_strdup (ATOMOS_CHAT_SUBMIT_PATH);
  g_autofree char *payload = NULL;
  char *argv[] = { NULL, NULL, NULL };
  g_autoptr (GError) err = NULL;

  g_return_if_fail (PHOSH_IS_HOME (self));

  if (!text || !*text)
    return;

  payload = g_strdup (text);
  g_strstrip (payload);
  if (!payload[0])
    return;

  argv[0] = command;
  argv[1] = payload;
  if (!g_spawn_async (NULL,
                      argv,
                      NULL,
                      G_SPAWN_DEFAULT,
                      NULL,
                      NULL,
                      NULL,
                      &err)) {
    g_warning ("Failed to submit chat payload: %s", err->message);
    return;
  }

  gtk_entry_set_text (entry, "");
}


static gboolean
apply_queued_app_grid_toggle_idle (gpointer data)
{
  PhoshHome *self = PHOSH_HOME (data);
  PhoshAppGrid *app_grid;
  gboolean next_visible;

  if (!PHOSH_IS_HOME (self))
    return G_SOURCE_REMOVE;
  if (!self->app_grid_toggle_queued)
    return G_SOURCE_REMOVE;
  if (self->state != PHOSH_HOME_STATE_UNFOLDED)
    return G_SOURCE_REMOVE;
  if (!self->ui_stable_for_popups)
    return G_SOURCE_CONTINUE;
  if (!gtk_widget_get_mapped (GTK_WIDGET (self->overview)))
    return G_SOURCE_CONTINUE;

  app_grid = phosh_overview_get_app_grid (PHOSH_OVERVIEW (self->overview));
  next_visible = !gtk_widget_get_visible (GTK_WIDGET (app_grid));
  gtk_widget_set_visible (GTK_WIDGET (app_grid), next_visible);
  if (self->app_grid_toggle_icon) {
    gtk_image_set_from_icon_name (GTK_IMAGE (self->app_grid_toggle_icon),
                                  next_visible ? "window-close-symbolic" : "view-app-grid-symbolic",
                                  GTK_ICON_SIZE_BUTTON);
  }
  if (next_visible)
    phosh_home_style_app_grid_widgets (self);
  self->app_grid_toggle_queued = FALSE;
  HOME_TRACE ("queued app-grid toggle applied visible=%d", next_visible);
  phosh_home_sync_chat_strip_visibility (self);
  update_drag_handle (self, TRUE);

  return G_SOURCE_REMOVE;
}


static void
on_app_grid_toggle_clicked (GtkButton *button, PhoshHome *self)
{
  PhoshAppGrid *app_grid;
  gboolean next_visible;

  (void)button;

  g_return_if_fail (PHOSH_IS_HOME (self));

  if (!app_grid_toggle_enabled ()) {
    HOME_TRACE ("app-grid toggle disabled by default for stability");
    if (self->state != PHOSH_HOME_STATE_UNFOLDED) {
      phosh_home_set_state (self, PHOSH_HOME_STATE_UNFOLDED);
    } else {
      phosh_home_set_state (self, PHOSH_HOME_STATE_FOLDED);
    }
    return;
  }

  /* Never toggle app-grid visibility while folded/transitioning.
   * In those states the overview tree can be unmapped, and forcing app-grid
   * visible can create popup/subsurface children without mapped parents. */
  if (self->state != PHOSH_HOME_STATE_UNFOLDED) {
    self->app_grid_toggle_queued = TRUE;
    HOME_TRACE ("app-grid click while state=%d; queueing toggle and unfolding", self->state);
    phosh_home_set_state (self, PHOSH_HOME_STATE_UNFOLDED);
    return;
  }
  if (!self->ui_stable_for_popups || !gtk_widget_get_mapped (GTK_WIDGET (self->overview))) {
    self->app_grid_toggle_queued = TRUE;
    HOME_TRACE ("app-grid click while not stable/mapped; deferring toggle");
    if (self->unfold_stable_source == 0)
      schedule_ui_stable_gate (self);
    return;
  }

  app_grid = phosh_overview_get_app_grid (PHOSH_OVERVIEW (self->overview));
  next_visible = !gtk_widget_get_visible (GTK_WIDGET (app_grid));
  gtk_widget_set_visible (GTK_WIDGET (app_grid), next_visible);

  if (self->app_grid_toggle_icon) {
    gtk_image_set_from_icon_name (GTK_IMAGE (self->app_grid_toggle_icon),
                                  next_visible ? "window-close-symbolic" : "view-app-grid-symbolic",
                                  GTK_ICON_SIZE_BUTTON);
  }
  if (next_visible)
    phosh_home_style_app_grid_widgets (self);

  self->app_grid_toggle_queued = FALSE;
  HOME_TRACE ("app-grid toggled visible=%d", next_visible);
  phosh_home_sync_chat_strip_visibility (self);
  update_drag_handle (self, TRUE);
}


static void
fold_cb (PhoshHome *self, PhoshOverview *overview)
{
  PhoshAppGrid *app_grid;

  g_return_if_fail (PHOSH_IS_HOME (self));
  g_return_if_fail (PHOSH_IS_OVERVIEW (overview));

  app_grid = phosh_overview_get_app_grid (overview);
  if (self->app_grid_toggle_queued || gtk_widget_get_visible (GTK_WIDGET (app_grid))) {
    HOME_TRACE ("ignoring fold callback while app-grid is opening/visible");
    return;
  }

  phosh_home_set_state (self, PHOSH_HOME_STATE_FOLDED);
}


static void
delayed_handle_resize (gpointer data)
{
  PhoshHome *self = PHOSH_HOME (data);

  self->debounce_handle = 0;
  update_drag_handle (self, TRUE);
}


static void
on_has_activities_changed (PhoshHome *self)
{
  g_return_if_fail (PHOSH_IS_HOME (self));

  /* TODO: we need to debounce the handle resize a little until all
     the queued resizing is done, would be nicer to have that tied to
     a signal */
  self->debounce_handle = g_timeout_add_once (200, delayed_handle_resize, self);
  g_source_set_name_by_id (self->debounce_handle, "[phosh] delayed_handle_resize");
}


static gboolean
window_key_press_event_cb (PhoshHome *self, GdkEvent *event, gpointer data)
{
  gboolean ret = GDK_EVENT_PROPAGATE;
  guint keyval;
  g_return_val_if_fail (PHOSH_IS_HOME (self), GDK_EVENT_PROPAGATE);

  if (self->state != PHOSH_HOME_STATE_UNFOLDED)
    return GDK_EVENT_PROPAGATE;

  if (!gdk_event_get_keyval (event, &keyval))
    return GDK_EVENT_PROPAGATE;

  switch (keyval) {
    case GDK_KEY_Escape:
      phosh_home_set_state (self, PHOSH_HOME_STATE_FOLDED);
      ret = GDK_EVENT_STOP;
      break;
    case GDK_KEY_Return:
      ret = GDK_EVENT_PROPAGATE;
      break;
    default:
      /* Focus search when typing */
      ret = phosh_overview_handle_search (PHOSH_OVERVIEW (self->overview), event);
  }

  return ret;
}


static void
toggle_overview_action (GSimpleAction *action, GVariant *param, gpointer data)
{
  PhoshHome *self = PHOSH_HOME (data);
  PhoshHomeState state;

  g_return_if_fail (PHOSH_IS_HOME (self));

  state = self->state == PHOSH_HOME_STATE_UNFOLDED ?
    PHOSH_HOME_STATE_FOLDED : PHOSH_HOME_STATE_UNFOLDED;
  phosh_home_set_state (self, state);
}


static void
toggle_application_view_action (GSimpleAction *action, GVariant *param, gpointer data)
{
  PhoshHome *self = PHOSH_HOME (data);
  PhoshHomeState state;

  g_return_if_fail (PHOSH_IS_HOME (self));

  state = self->state == PHOSH_HOME_STATE_UNFOLDED ?
    PHOSH_HOME_STATE_FOLDED : PHOSH_HOME_STATE_UNFOLDED;
  phosh_home_set_state (self, state);

  /* Focus app search once unfolded */
  if (state == PHOSH_HOME_STATE_UNFOLDED)
    self->focus_app_search = TRUE;
}


static void
add_keybindings (PhoshHome *self)
{
  const GActionEntry super_entries[] = {
    { "Super_R", .activate = toggle_overview_action },
    { "Super_L", .activate = toggle_overview_action },
  };
  g_autoptr (GStrvBuilder) builder = g_strv_builder_new ();
  g_autoptr (GSettings) settings = g_settings_new (KEYBINDINGS_SCHEMA_ID);
  g_autoptr (GArray) actions = g_array_new (FALSE, TRUE, sizeof (GActionEntry));

  PHOSH_UTIL_BUILD_KEYBINDING (actions,
                               builder,
                               settings,
                               KEYBINDING_KEY_TOGGLE_OVERVIEW,
                               toggle_overview_action);

  PHOSH_UTIL_BUILD_KEYBINDING (actions,
                               builder,
                               settings,
                               KEYBINDING_KEY_TOGGLE_APPLICATION_VIEW,
                               toggle_application_view_action);

  phosh_shell_add_global_keyboard_action_entries (phosh_shell_get_default (),
                                                  (GActionEntry*) actions->data,
                                                  actions->len,
                                                  self);

  phosh_shell_add_global_keyboard_action_entries (phosh_shell_get_default (),
                                                  (GActionEntry*)super_entries,
                                                  G_N_ELEMENTS (super_entries),
                                                  self);

  for (int i = 0; i < G_N_ELEMENTS (super_entries); i++)
    g_strv_builder_add (builder, super_entries[i].name);

  self->action_names = g_strv_builder_end (builder);
}


static void
on_keybindings_changed (PhoshHome *self,
                        char      *key,
                        GSettings *settings)
{
  /* For now just redo all keybindings */
  g_debug ("Updating keybindings");
  phosh_shell_remove_global_keyboard_action_entries (phosh_shell_get_default (),
                                                     self->action_names);
  g_clear_pointer (&self->action_names, g_strfreev);
  add_keybindings (self);
}


static void
phosh_home_set_background_alpha (PhoshHome *self, double alpha)
{
  if (self->background)
    phosh_layer_surface_set_alpha (PHOSH_LAYER_SURFACE (self->background), alpha);
}


static void
phosh_home_dragged (PhoshDragSurface *drag_surface, int margin)
{
  PhoshHome *self = PHOSH_HOME (drag_surface);
  int width, height;
  double progress, alpha;

  gtk_window_get_size (GTK_WINDOW (self), &width, &height);
  progress = 1.0 - (-margin / (double)(height - PHOSH_HOME_BAR_HEIGHT));
  /* Avoid negative values when resizing the surface */
  progress = MAX (0, progress);

  alpha = hdy_ease_out_cubic (progress);
  phosh_home_set_background_alpha (self, alpha);
}


static void
on_drag_state_changed (PhoshHome *self)
{
  PhoshHomeState state = self->state;
  PhoshDragSurfaceState drag_state;
  gboolean kbd_interactivity = FALSE;

  drag_state = phosh_drag_surface_get_drag_state (PHOSH_DRAG_SURFACE (self));
  HOME_TRACE ("drag-state-changed drag_state=%d old_state=%d queued_toggle=%d",
              drag_state,
              self->state,
              self->app_grid_toggle_queued);

  switch (drag_state) {
  case PHOSH_DRAG_SURFACE_STATE_UNFOLDED:
    state = PHOSH_HOME_STATE_UNFOLDED;
    kbd_interactivity = TRUE;
    schedule_ui_stable_gate (self);
    if (self->focus_app_search) {
      phosh_overview_focus_app_search (PHOSH_OVERVIEW (self->overview));
      self->focus_app_search = FALSE;
    }
    phosh_home_set_background_alpha (self, 1.0);
    break;
  case PHOSH_DRAG_SURFACE_STATE_FOLDED:
    state = PHOSH_HOME_STATE_FOLDED;
    self->ui_stable_for_popups = FALSE;
    self->app_grid_toggle_queued = FALSE;
    g_clear_handle_id (&self->unfold_stable_source, g_source_remove);
    phosh_home_set_background_alpha (self, 0.0);
    phosh_overview_reset (PHOSH_OVERVIEW (self->overview));
    break;
  case PHOSH_DRAG_SURFACE_STATE_DRAGGED:
    state = PHOSH_HOME_STATE_TRANSITION;
    self->ui_stable_for_popups = FALSE;
    self->app_grid_toggle_queued = FALSE;
    g_clear_handle_id (&self->unfold_stable_source, g_source_remove);
    if (self->state == PHOSH_HOME_STATE_FOLDED)
      phosh_overview_refresh (PHOSH_OVERVIEW (self->overview));
    break;
  default:
    g_return_if_reached ();
    return;
  }

  if (self->state != state) {
    self->state = state;
    g_object_notify_by_pspec (G_OBJECT (self), props[PROP_HOME_STATE]);
  }

  if (self->state == PHOSH_HOME_STATE_UNFOLDED && self->app_grid_toggle_queued) {
    HOME_TRACE ("scheduling queued app-grid toggle");
    g_idle_add (apply_queued_app_grid_toggle_idle, self);
  }

  phosh_home_update_home_bar (self);

  phosh_layer_surface_set_kbd_interactivity (PHOSH_LAYER_SURFACE (self), kbd_interactivity);
  update_drag_handle (self, TRUE);
}


static void
on_osk_manager_visible_notify (GObject *object, GParamSpec *pspec, gpointer user_data)
{
  PhoshHome *self = PHOSH_HOME (user_data);

  (void) object;
  (void) pspec;

  phosh_home_update_home_bar (self);
}


static void
phosh_home_add_background (PhoshHome *self)
{
  PhoshWayland *wl = phosh_wayland_get_default ();
  PhoshShell *shell = phosh_shell_get_default ();
  PhoshMonitor *monitor;
  cairo_rectangle_int_t rect = { 0, 0, 0, 0 };
  cairo_region_t *region;

  monitor = phosh_shell_get_primary_monitor (shell);
  self->background = PHOSH_BACKGROUND (phosh_background_new (
                                         phosh_wayland_get_zwlr_layer_shell_v1 (wl),
                                         monitor,
                                         /* Span over whole display */
                                         FALSE,
                                         ZWLR_LAYER_SHELL_V1_LAYER_TOP));
  g_object_bind_property (self, "visible", self->background, "visible", G_BINDING_SYNC_CREATE);

  g_signal_connect_object (phosh_shell_get_background_manager (shell),
                           "config-changed",
                           G_CALLBACK (phosh_background_needs_update),
                           self->background,
                           G_CONNECT_SWAPPED);

  region = cairo_region_create_rectangle (&rect);
  gtk_widget_input_shape_combine_region (GTK_WIDGET (self->background), region);
  cairo_region_destroy (region);
}


static void
on_theme_name_changed (PhoshHome  *self, GParamSpec *pspec, PhoshStyleManager *style_manager)
{
  g_assert (PHOSH_IS_HOME (self));
  g_assert (PHOSH_IS_STYLE_MANAGER (style_manager));

  self->use_background = !phosh_style_manager_is_high_contrast (style_manager);
  phosh_util_toggle_style_class (GTK_WIDGET (self), "p-solid", !self->use_background);
  if (gtk_widget_get_visible (GTK_WIDGET (self)))
    gtk_widget_set_visible (GTK_WIDGET (self->background), self->use_background);

  phosh_home_update_atomos_visual_theme (self);
  phosh_home_update_home_bar (self);
}


static void
phosh_home_constructed (GObject *object)
{
  PhoshHome *self = PHOSH_HOME (object);
  PhoshShell *shell = phosh_shell_get_default ();
  PhoshOskManager *osk_manager;
  GtkWidget *root_box;
  GtkWidget *app_grid_row;
  PhoshAppGrid *app_grid;

  G_OBJECT_CLASS (phosh_home_parent_class)->constructed (object);

  g_object_connect (self->settings,
                    "swapped-signal::changed::" KEYBINDING_KEY_TOGGLE_OVERVIEW,
                    on_keybindings_changed, self,
                    "swapped-signal::changed::" KEYBINDING_KEY_TOGGLE_APPLICATION_VIEW,
                    on_keybindings_changed, self,
                    NULL);
  add_keybindings (self);

  osk_manager = phosh_shell_get_osk_manager (phosh_shell_get_default ());
  g_object_bind_property (osk_manager, "available",
                          self, "osk-enabled",
                          G_BINDING_SYNC_CREATE);

  g_signal_connect (osk_manager, "notify::visible",
                    G_CALLBACK (on_osk_manager_visible_notify), self);

  g_signal_connect (self, "notify::drag-state", G_CALLBACK (on_drag_state_changed), NULL);

  g_object_set_data (G_OBJECT (self->click_gesture), "phosh-home", self);
  g_object_set_data (G_OBJECT (self->osk_toggle_long_press), "phosh-home", self);
  root_box = gtk_widget_get_parent (self->overview);
  g_return_if_fail (GTK_IS_BOX (root_box));

  /* AtomOS: remove the legacy divider/home-bar strip entirely so there is no
   * visible swipe strip above overview content. */
  gtk_widget_set_sensitive (self->evbox_home_bar, FALSE);
  gtk_widget_set_visible (self->rev_powerbar, FALSE);
  gtk_widget_set_size_request (self->evbox_home_bar, -1, 0);
  gtk_widget_set_visible (self->evbox_home_bar, FALSE);

  self->app_grid_toggle_icon = gtk_image_new_from_icon_name ("view-app-grid-symbolic", GTK_ICON_SIZE_BUTTON);
  gtk_image_set_pixel_size (GTK_IMAGE (self->app_grid_toggle_icon), 22);
  self->app_grid_toggle_button = gtk_button_new ();
  gtk_style_context_add_class (gtk_widget_get_style_context (self->app_grid_toggle_button), "atomos-dock-btn");
  gtk_button_set_image (GTK_BUTTON (self->app_grid_toggle_button), self->app_grid_toggle_icon);
  /* Avoid tooltip popup windows here; rapid home-surface transitions can leave
   * popup parents unmapped and trigger the map errors we are diagnosing. */
  gtk_widget_set_has_tooltip (self->app_grid_toggle_button, FALSE);
  gtk_widget_set_visible (self->app_grid_toggle_button, TRUE);
  app_grid_row = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);
  gtk_widget_set_halign (app_grid_row, GTK_ALIGN_FILL);
  gtk_widget_set_visible (app_grid_row, TRUE);
  gtk_style_context_add_class (gtk_widget_get_style_context (app_grid_row), "atomos-app-grid-row");
  gtk_box_pack_start (GTK_BOX (app_grid_row), self->app_grid_toggle_button, FALSE, FALSE, 0);
  gtk_box_pack_start (GTK_BOX (root_box), app_grid_row, FALSE, FALSE, 0);
  /* Keep this row directly below the divider/home-bar and above overview content. */
  gtk_box_reorder_child (GTK_BOX (root_box), app_grid_row, 1);

  g_signal_connect (self->app_grid_toggle_button,
                    "clicked",
                    G_CALLBACK (on_app_grid_toggle_clicked),
                    self);

  self->chat_entry = gtk_entry_new ();
  gtk_entry_set_placeholder_text (GTK_ENTRY (self->chat_entry), "Ask AtomOS");
  gtk_style_context_add_class (gtk_widget_get_style_context (self->chat_entry), "atomos-chat-input");
  gtk_widget_set_hexpand (self->chat_entry, TRUE);
  gtk_widget_set_visible (self->chat_entry, FALSE);
  {
    GtkWidget *chat_wrap = gtk_box_new (GTK_ORIENTATION_HORIZONTAL, 0);

    gtk_style_context_add_class (gtk_widget_get_style_context (chat_wrap), "atomos-chat-wrap");
    gtk_box_pack_start (GTK_BOX (chat_wrap), self->chat_entry, TRUE, TRUE, 0);
    gtk_box_pack_end (GTK_BOX (root_box), chat_wrap, FALSE, FALSE, 0);
    gtk_widget_set_visible (chat_wrap, FALSE);
  }
  g_signal_connect (self->chat_entry, "activate", G_CALLBACK (on_chat_entry_activate), self);
  self->chat_dismiss_tap = gtk_gesture_multi_press_new (GTK_WIDGET (self));
  gtk_event_controller_set_propagation_phase (GTK_EVENT_CONTROLLER (self->chat_dismiss_tap),
                                              GTK_PHASE_BUBBLE);
  gtk_gesture_single_set_button (GTK_GESTURE_SINGLE (self->chat_dismiss_tap), 0);
  g_signal_connect (self->chat_dismiss_tap,
                    "pressed",
                    G_CALLBACK (on_chat_dismiss_tap_pressed),
                    self);

  app_grid = phosh_overview_get_app_grid (PHOSH_OVERVIEW (self->overview));
  phosh_home_style_app_grid_widgets (self);
  gtk_widget_set_visible (GTK_WIDGET (app_grid), FALSE);

  phosh_home_add_background (self);
  g_signal_connect_object (phosh_shell_get_style_manager (shell),
                           "notify::theme-name",
                           G_CALLBACK (on_theme_name_changed),
                           self,
                           G_CONNECT_SWAPPED);
  g_signal_connect_object (gtk_settings_get_default (),
                           "notify::gtk-application-prefer-dark-theme",
                           G_CALLBACK (on_gtk_settings_atomos_theme),
                           self,
                           G_CONNECT_AFTER);
  on_theme_name_changed (self, NULL, phosh_shell_get_style_manager (shell));
  phosh_home_update_home_bar (self);
}


static void
phosh_home_dispose (GObject *object)
{
  PhoshHome *self = PHOSH_HOME (object);
  PhoshOskManager *osk_manager;

  osk_manager = phosh_shell_get_osk_manager (phosh_shell_get_default ());
  if (osk_manager)
    g_signal_handlers_disconnect_by_data (G_OBJECT (osk_manager), self);

  g_clear_object (&self->chat_dismiss_tap);
  g_clear_object (&self->settings);
  g_clear_handle_id (&self->unfold_stable_source, g_source_remove);

  if (self->action_names) {
    phosh_shell_remove_global_keyboard_action_entries (phosh_shell_get_default (),
                                                       self->action_names);
    g_clear_pointer (&self->action_names, g_strfreev);
  }
  g_clear_handle_id (&self->debounce_handle, g_source_remove);

  g_clear_pointer (&self->background, phosh_cp_widget_destroy);

  G_OBJECT_CLASS (phosh_home_parent_class)->dispose (object);
}


static void
phosh_home_class_init (PhoshHomeClass *klass)
{
  GObjectClass *object_class = (GObjectClass *)klass;
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS (klass);
  PhoshDragSurfaceClass *drag_surface_class = PHOSH_DRAG_SURFACE_CLASS (klass);

  install_atomos_overview_chat_ui_css_once ();

  object_class->constructed = phosh_home_constructed;
  object_class->dispose = phosh_home_dispose;

  object_class->set_property = phosh_home_set_property;
  object_class->get_property = phosh_home_get_property;

  widget_class->map = phosh_home_map;

  drag_surface_class->dragged = phosh_home_dragged;

  /**
   * PhoshHome:state:
   *
   * Whether the home widget is currently folded (only home-bar is
   * visible) or unfolded (overview is visible). The property is
   * changed when the widget reaches it's target state.
   */
  props[PROP_HOME_STATE] =
    g_param_spec_enum ("state", "", "",
                       PHOSH_TYPE_HOME_STATE,
                       PHOSH_HOME_STATE_FOLDED,
                       G_PARAM_READWRITE | G_PARAM_EXPLICIT_NOTIFY | G_PARAM_STATIC_STRINGS);
  /**
   * PhoshHome:osk-enabled:
   *
   * Whether the osk is currently enabled in the system configuration.
   */
  props[PROP_OSK_ENABLED] =
    g_param_spec_boolean ("osk-enabled", "", "",
                          FALSE,
                          G_PARAM_READWRITE | G_PARAM_EXPLICIT_NOTIFY |  G_PARAM_STATIC_STRINGS);

  g_object_class_install_properties (object_class, PROP_LAST_PROP, props);

  g_type_ensure (PHOSH_TYPE_OVERVIEW);

  gtk_widget_class_set_template_from_resource (widget_class,
                                               "/mobi/phosh/ui/home.ui");
  gtk_widget_class_bind_template_child (widget_class, PhoshHome, click_gesture);
  gtk_widget_class_bind_template_child (widget_class, PhoshHome, evbox_home_bar);
  gtk_widget_class_bind_template_child (widget_class, PhoshHome, home_bar);
  gtk_widget_class_bind_template_child (widget_class, PhoshHome, osk_toggle_long_press);
  gtk_widget_class_bind_template_child (widget_class, PhoshHome, overview);
  gtk_widget_class_bind_template_child (widget_class, PhoshHome, rev_powerbar);
  gtk_widget_class_bind_template_child (widget_class, PhoshHome, powerbar);
  gtk_widget_class_bind_template_callback (widget_class, fold_cb);
  gtk_widget_class_bind_template_callback (widget_class, on_home_released);
  gtk_widget_class_bind_template_callback (widget_class, on_has_activities_changed);
  gtk_widget_class_bind_template_callback (widget_class, on_powerbar_pressed);
  gtk_widget_class_bind_template_callback (widget_class, on_powerbar_action_started);
  gtk_widget_class_bind_template_callback (widget_class, on_powerbar_action_ended);
  gtk_widget_class_bind_template_callback (widget_class, window_key_press_event_cb);

  gtk_widget_class_set_css_name (widget_class, "phosh-home");
}


static void
phosh_home_init (PhoshHome *self)
{
  g_autoptr (GSettings) settings = NULL;

  gtk_widget_init_template (GTK_WIDGET (self));

  self->use_background = TRUE;
  self->state = PHOSH_HOME_STATE_FOLDED;
  self->last_reference_height = 0;
  self->app_grid_toggle_queued = FALSE;
  self->ui_stable_for_popups = FALSE;
  self->unfold_stable_source = 0;
  self->settings = g_settings_new (KEYBINDINGS_SCHEMA_ID);

  /* Adjust margins and folded state on size changes */
  g_signal_connect (self, "configure-event", G_CALLBACK (on_configure_event), NULL);

  settings = g_settings_new (PHOSH_SETTINGS);
  g_settings_bind (settings, "osk-unfold-delay",
                   self->osk_toggle_long_press, "delay-factor",
                   G_SETTINGS_BIND_GET);
}


GtkWidget *
phosh_home_new (struct zwlr_layer_shell_v1          *layer_shell,
                struct zphoc_layer_shell_effects_v1 *layer_shell_effects,
                PhoshMonitor                        *monitor)
{
  return g_object_new (PHOSH_TYPE_HOME,
                       /* layer-surface */
                       "layer-shell", layer_shell,
                       "wl-output", monitor->wl_output,
                       "anchor", ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
                                 ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
                                 ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT,
                       "layer", ZWLR_LAYER_SHELL_V1_LAYER_TOP,
                       "kbd-interactivity", FALSE,
                       /* AtomOS: no reserved strip/divider above overview content. */
                       "exclusive-zone", 0,
                       "namespace", "phosh home",
                       /* drag-surface */
                       "layer-shell-effects", layer_shell_effects,
                       "drag-mode", PHOSH_DRAG_SURFACE_DRAG_MODE_NONE,
                       "exclusive", 0,
                       "threshold", PHOSH_HOME_DRAG_THRESHOLD,
                       NULL);
}

/**
 * phosh_home_get_state:
 * @self: The home surface
 *
 * Get the current state of the home widget. See [property@Home:state] for details.
 *
 * Returns: The home widget's state
 */
PhoshHomeState
phosh_home_get_state (PhoshHome *self)
{
  g_return_val_if_fail (PHOSH_IS_HOME (self), PHOSH_HOME_STATE_FOLDED);

  return self->state;
}

/**
 * phosh_home_set_state:
 * @self: The home surface
 * @state: The state to set
 *
 * Set the state of the home screen. See #PhoshHomeState.
 */
void
phosh_home_set_state (PhoshHome *self, PhoshHomeState state)
{
  g_autofree char *state_name = NULL;
  PhoshDragSurfaceState drag_state = phosh_drag_surface_get_drag_state (PHOSH_DRAG_SURFACE (self));
  PhoshDragSurfaceState target_state = PHOSH_DRAG_SURFACE_STATE_FOLDED;

  g_return_if_fail (PHOSH_IS_HOME (self));

  if (self->state == state)
    return;

  if (drag_state == PHOSH_DRAG_SURFACE_STATE_DRAGGED)
    return;

  state_name = g_enum_to_string (PHOSH_TYPE_HOME_STATE, state);
  HOME_TRACE ("set-state requested=%s drag_state=%d", state_name ? state_name : "<null>", drag_state);
  g_debug ("Setting state to %s", state_name);

  if (state == PHOSH_HOME_STATE_UNFOLDED)
    target_state = PHOSH_DRAG_SURFACE_STATE_UNFOLDED;

  phosh_drag_surface_set_drag_state (PHOSH_DRAG_SURFACE (self), target_state);
}

/**
 * phosh_home_get_overview:
 * @self: The home surface
 *
 * Get the overview widget
 *
 * Returns:(transfer none): The overview
 */
PhoshOverview*
phosh_home_get_overview (PhoshHome *self)
{
  g_return_val_if_fail (PHOSH_IS_HOME (self), NULL);

  return PHOSH_OVERVIEW (self->overview);
}
