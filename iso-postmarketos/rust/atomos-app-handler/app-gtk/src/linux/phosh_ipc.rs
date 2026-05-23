//! D-Bus calls into Phosh `org.atomos.PhoshHome` for fold/unfold.

use atomos_app_handler::{PhoshHomeIpc, PHOSH_HOME_DBUS_NAME, PHOSH_HOME_DBUS_PATH};
use gtk::gio;

const DBUS_INTERFACE: &str = "org.atomos.PhoshHome";

pub fn apply_home_ipc(ipc: PhoshHomeIpc) -> Result<(), String> {
    match ipc {
        PhoshHomeIpc::None => Ok(()),
        PhoshHomeIpc::SetFolded => call_void_method("SetFolded"),
        PhoshHomeIpc::SetUnfolded => call_void_method("SetUnfolded"),
    }
}

fn call_void_method(method: &str) -> Result<(), String> {
    let conn = gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>)
        .map_err(|e| e.to_string())?;
    conn.call_sync(
        Some(PHOSH_HOME_DBUS_NAME),
        PHOSH_HOME_DBUS_PATH,
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
