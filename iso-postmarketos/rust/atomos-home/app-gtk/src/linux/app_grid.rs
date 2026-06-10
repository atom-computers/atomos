//! App grid toggle button and visibility management.
//!
//! A circular dock button with `view-app-grid-symbolic` icon that toggles
//! the application grid overlay. Mirrors Phosh's `atomos-app-grid-row`
//! and `atomos-dock-btn` pattern.

#![cfg(target_os = "linux")]

use gtk::prelude::*;

pub const DOCK_BTN_CSS_CLASS: &str = "atomos-dock-btn";
pub const APP_GRID_ROW_CSS_CLASS: &str = "atomos-app-grid-row";
pub const ICON_GRID: &str = "view-app-grid-symbolic";
pub const ICON_CLOSE: &str = "window-close-symbolic";

pub fn create_app_grid_row() -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    row.add_css_class(APP_GRID_ROW_CSS_CLASS);
    row.set_halign(gtk::Align::Center);
    row
}

pub fn create_app_grid_toggle_button(is_grid_visible: bool) -> gtk::Button {
    let btn = gtk::Button::new();
    btn.add_css_class(DOCK_BTN_CSS_CLASS);

    let icon_name = if is_grid_visible {
        ICON_CLOSE
    } else {
        ICON_GRID
    };
    set_button_icon(&btn, icon_name);

    btn
}

pub fn set_button_icon(btn: &gtk::Button, icon_name: &str) {
    let image = gtk::Image::from_icon_name(icon_name);
    btn.set_child(Some(&image));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dock_btn_css_class_matches_stylesheet() {
        assert_eq!(DOCK_BTN_CSS_CLASS, "atomos-dock-btn");
    }

    #[test]
    fn app_grid_row_css_class_matches_stylesheet() {
        assert_eq!(APP_GRID_ROW_CSS_CLASS, "atomos-app-grid-row");
    }

    #[test]
    fn icon_names_are_symbolic() {
        assert!(ICON_GRID.ends_with("-symbolic"));
        assert!(ICON_CLOSE.ends_with("-symbolic"));
    }
}