//! Linux-specific modules for the GTK4 layer-shell home surface.

#![cfg(target_os = "linux")]

pub mod app_grid;
pub mod background;
pub mod chat_entry;
pub mod css;
pub mod dbus;
pub mod home_bar;
pub mod home_surface;
pub mod keybinding;