//! D-Bus calls into `org.atomos.Home` for fold/unfold.
//!
//! Replaces the old `org.atomos.PhoshHome` interface. The D-Bus name and
//! path changed in Phase 3 but the methods remain the same.

use atomos_app_handler::{HomeIpc, HOME_DBUS_NAME, HOME_DBUS_PATH};
use gtk::gio;
use gtk::glib::prelude::*;

const DBUS_INTERFACE: &str = "org.atomos.Home";

pub fn apply_home_ipc(ipc: HomeIpc) -> Result<(), String> {
    match ipc {
        HomeIpc::None => Ok(()),
        HomeIpc::SetFolded => call_void_method("SetFolded"),
        HomeIpc::SetUnfolded => call_void_method("SetUnfolded"),
    }
}

pub fn close_osk_keyboard() {
    let conn = match gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("atomos-app-handler: close_osk_keyboard failed to get session bus: {e}");
            return;
        }
    };
    let parameters = (false,).to_variant();
    match conn.call_sync(
        Some("sm.puri.OSK0"),
        "/sm/puri/OSK0",
        "sm.puri.OSK0",
        "SetVisible",
        Some(&parameters),
        None,
        gio::DBusCallFlags::NONE,
        1_000,
        None::<&gio::Cancellable>,
    ) {
        Ok(_) => eprintln!("atomos-app-handler: close_osk_keyboard SetVisible(false) sent successfully"),
        Err(e) => eprintln!("atomos-app-handler: close_osk_keyboard SetVisible(false) failed: {e}"),
    }
}

fn call_void_method(method: &str) -> Result<(), String> {
    let conn = gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>)
        .map_err(|e| e.to_string())?;
    conn.call_sync(
        Some(HOME_DBUS_NAME),
        HOME_DBUS_PATH,
        DBUS_INTERFACE,
        method,
        None,
        None,
        gio::DBusCallFlags::NONE,
        5_000,
        None::<&gio::Cancellable>,
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}