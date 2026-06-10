//! Home bar — 15px bottom strip with powerbar (OSK toggle pill).
//!
//! The home bar is the drag target that appears when the home surface is folded.
//! It contains a centered "powerbar" pill that toggles the on-screen keyboard
//! on long-press. Mirrors Phosh's `evbox_home_bar` / `home_bar` / `rev_powerbar`.

#![cfg(target_os = "linux")]

use gtk::prelude::*;

use super::home_surface::HOME_BAR_HEIGHT_PX;

pub const HOME_BAR_CSS_CLASS: &str = "atomos-home-bar";
pub const POWERBAR_CSS_CLASS: &str = "atomos-powerbar";

pub fn create_home_bar() -> gtk::Box {
    let bar = gtk::Box::new(gtk::Orientation::Vertical, 0);
    bar.add_css_class(HOME_BAR_CSS_CLASS);
    bar.set_height_request(HOME_BAR_HEIGHT_PX);
    bar.set_hexpand(true);
    bar.set_valign(gtk::Align::Fill);

    let powerbar = create_powerbar();
    bar.append(&powerbar);

    bar
}

fn create_powerbar() -> gtk::Box {
    let pill = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    pill.add_css_class(POWERBAR_CSS_CLASS);
    pill.set_halign(gtk::Align::Center);
    pill.set_valign(gtk::Align::Center);
    pill.set_size_request(120, 4);

    let gesture = gtk::GestureLongPress::new();
    gesture.connect_pressed(|_gesture, _x, _y| {
        toggle_osk();
    });
    pill.add_controller(gesture);

    pill
}

fn toggle_osk() {
    let _ = std::process::Command::new("busctl")
        .args(["--user", "call", "sm.puri.OSK0", "/sm/puri/OSK0", "sm.puri.OSK0", "SetVisible", "b", "1"])
        .spawn();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::linux::home_surface::HOME_BAR_HEIGHT_PX;

    #[test]
    fn home_bar_height_matches_phosh() {
        assert_eq!(HOME_BAR_HEIGHT_PX, 15);
    }

    #[test]
    fn css_classes_match_stylesheet() {
        assert_eq!(HOME_BAR_CSS_CLASS, "atomos-home-bar");
        assert_eq!(POWERBAR_CSS_CLASS, "atomos-powerbar");
    }
}