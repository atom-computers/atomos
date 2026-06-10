//! GTK4 layer-shell home surface — Linux-only.
//!
//! Creates a `gtk4::ApplicationWindow` mapped as a wlr-layer-shell surface
//! with namespace `"atomos-home"` on layer TOP, anchored to the bottom edge.
//! Folded height is 15px (home-bar swipe target); unfolded fills the screen.
//!
//! Widget hierarchy (mirrors PhoshHome):
//! ```text
//! ApplicationWindow (layer-shell)
//!   └─ GtkBox (vertical, root_box)
//!       ├─ GtkBox (atomos-home-bar, 15px)  ← home_bar module
//!       │    └─ GtkBox (atomos-powerbar)   ← OSK toggle pill
//!       ├─ GtkBox (atomos-app-grid-row)    ← app_grid module
//!       │    └─ Button (atomos-dock-btn)   ← grid toggle
//!       └─ GtkBox (atomos-chat-wrap)        ← chat_entry module
//!            └─ GtkEntry (atomos-chat-input)
//! ```

#![cfg(target_os = "linux")]

use gtk::prelude::*;
use gtk4_layer_shell::{Edge, Layer, LayerShell};

use atomos_home_core::{HomeDragState, HOME_DBUS_NAME, HOME_DBUS_PATH};

use super::app_grid;
use super::background;
use super::chat_entry;
use super::css;
use super::home_bar;
use super::keybinding;

pub const LAYER_NAMESPACE: &str = "atomos-home";
pub const HOME_BAR_HEIGHT_PX: i32 = 15;
pub const LAYER: Layer = Layer::Top;

pub fn create_home_window(app: &gtk::Application) -> gtk::ApplicationWindow {
    let provider = css::load_css_provider();

    let window = gtk::ApplicationWindow::new(app);
    window.set_title(Some("atomos-home"));

    window.init_layer_shell();
    window.set_namespace(Some(LAYER_NAMESPACE));
    window.set_layer(Layer::Top);

    window.set_anchor(Edge::Left, true);
    window.set_anchor(Edge::Right, true);
    window.set_anchor(Edge::Bottom, true);
    window.set_anchor(Edge::Top, false);

    window.set_exclusive_zone(HOME_BAR_HEIGHT_PX);

    let root_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
    window.set_child(Some(&root_box));

    let home_bar_widget = home_bar::create_home_bar();
    root_box.append(&home_bar_widget);

    let grid_row = app_grid::create_app_grid_row();
    let toggle_btn = app_grid::create_app_grid_toggle_button(false);
    grid_row.append(&toggle_btn);
    root_box.append(&grid_row);

    let chat_entry = chat_entry::create_chat_entry();
    let chat_wrap = chat_entry::create_chat_wrap(&chat_entry);
    root_box.append(&chat_wrap);

    background::apply_drag_state_theme(&root_box, HomeDragState::Folded);
    background::set_home_bar_solid(&home_bar_widget, true);

    keybinding::install_keybindings(&window);

    window.set_height_request(HOME_BAR_HEIGHT_PX);
    window.set_visible(true);

    let _ = (provider, HOME_DBUS_NAME, HOME_DBUS_PATH);

    window
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layer_namespace_matches_phosh_home() {
        assert_ne!(LAYER_NAMESPACE, "phosh home");
    }

    #[test]
    fn home_bar_height_is_reasonable() {
        assert!(HOME_BAR_HEIGHT_PX > 0);
        assert!(HOME_BAR_HEIGHT_PX < 100);
    }

    #[test]
    fn dbus_name_matches_core_constant() {
        assert_eq!(HOME_DBUS_NAME, "org.atomos.Home");
        assert_eq!(HOME_DBUS_PATH, "/org/atomos/Home");
    }
}