//! Keybinding handlers for Super and Escape.
//!
//! Super key toggles the home surface (fold/unfold).
//! Escape key folds the home surface (like Phosh's `toggle-application-view`).

#![cfg(target_os = "linux")]

use gtk::prelude::*;

pub fn install_keybindings(window: &gtk::ApplicationWindow) {
    let controller = gtk::EventControllerKey::new();

    controller.connect_key_pressed(|_, keyval, _, _| {
        match keyval {
            gtk::gdk::Key::Super_L | gtk::gdk::Key::Super_R => {
                toggle_home_via_dbus();
                gtk::glib::Propagation::Stop
            }
            gtk::gdk::Key::Escape => {
                fold_home_via_dbus();
                gtk::glib::Propagation::Stop
            }
            _ => gtk::glib::Propagation::Proceed,
        }
    });

    window.add_controller(controller);
}

fn toggle_home_via_dbus() {
    let _ = gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>)
        .map_err(|e| eprintln!("atomos-home: D-Bus session connect: {e}"))
        .and_then(|conn| {
            conn.call_sync(
                Some("org.atomos.Home"),
                "/org/atomos/Home",
                "org.atomos.Home",
                "SetUnfolded",
                None,
                None,
                gio::DBusCallFlags::NONE,
                5000,
                None::<&gio::Cancellable>,
            )
            .map_err(|e| eprintln!("atomos-home: D-Bus SetUnfolded: {e}"))
        });
}

fn fold_home_via_dbus() {
    let _ = gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>)
        .map_err(|e| eprintln!("atomos-home: D-Bus session connect: {e}"))
        .and_then(|conn| {
            conn.call_sync(
                Some("org.atomos.Home"),
                "/org/atomos/Home",
                "org.atomos.Home",
                "SetFolded",
                None,
                None,
                gio::DBusCallFlags::NONE,
                5000,
                None::<&gio::Cancellable>,
            )
            .map_err(|e| eprintln!("atomos-home: D-Bus SetFolded: {e}"))
        });
}

#[cfg(test)]
mod tests {
    #[test]
    fn keybinding_module_compiles() {
    }
}