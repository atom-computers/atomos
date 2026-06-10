//! Background layer management for atomos-home.
//!
//! Manages the visual background of the home surface. When the home surface
//! is folded, the background is transparent (allowing the compositor background
//! to show through). When unfolded, a semi-transparent overlay provides contrast
//! for the overview content.

#![cfg(target_os = "linux")]

use gtk::prelude::*;

use atomos_home_core::HomeDragState;

pub const DARK_THEME_CLASS: &str = "atomos-dark";
pub const LIGHT_THEME_CLASS: &str = "atomos-light";

pub fn apply_drag_state_theme(widget: &impl IsA<gtk::Widget>, drag_state: HomeDragState) {
    match drag_state {
        HomeDragState::Folded => {
            widget.remove_css_class(LIGHT_THEME_CLASS);
            widget.add_css_class(DARK_THEME_CLASS);
        }
        HomeDragState::Unfolded => {
            widget.remove_css_class(DARK_THEME_CLASS);
            widget.add_css_class(LIGHT_THEME_CLASS);
        }
        HomeDragState::Transition => {
        }
    }
}

pub fn set_home_bar_solid(bar: &impl IsA<gtk::Widget>, solid: bool) {
    if solid {
        bar.add_css_class("p-solid");
    } else {
        bar.remove_css_class("p-solid");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn theme_class_names_match_css() {
        assert_eq!(DARK_THEME_CLASS, "atomos-dark");
        assert_eq!(LIGHT_THEME_CLASS, "atomos-light");
    }
}