//! D-Bus server for `org.atomos.Home`.
//!
//! Exposes SetFolded, SetUnfolded, and GetState methods, and emits
//! DragChangedState signal. This replaces the Phosh C D-Bus interface
//! `org.atomos.PhoshHome`.

#![cfg(target_os = "linux")]

use atomos_home_core::{HOME_DBUS_NAME, HOME_DBUS_PATH, HomeDragState};
use std::sync::{Arc, Mutex};

use zbus::zvariant::Structure;

/// Shared state for the D-Bus server. The GTK layer-shell code updates
/// `drag_state` and the D-Bus interface reads it.
#[derive(Debug, Clone)]
pub struct HomeState {
    pub drag_state: HomeDragState,
}

/// The D-Bus interface object.
struct HomeIface {
    state: Arc<Mutex<HomeState>>,
}

#[zbus::interface(name = "org.atomos.Home")]
impl HomeIface {
    fn set_folded(&self) -> zbus::fdo::Result<()> {
        let mut state = self.state.lock().unwrap();
        state.drag_state = HomeDragState::Folded;
        eprintln!("atomos-home: D-Bus SetFolded");
        Ok(())
    }

    fn set_unfolded(&self) -> zbus::fdo::Result<()> {
        let mut state = self.state.lock().unwrap();
        state.drag_state = HomeDragState::Unfolded;
        eprintln!("atomos-home: D-Bus SetUnfolded");
        Ok(())
    }

    fn get_state(&self) -> zbus::fdo::Result<String> {
        let state = self.state.lock().unwrap();
        Ok(state.drag_state.as_str().to_string())
    }
}

/// Start the D-Bus server on the session bus.
///
/// Returns a `zbus::Connection` and the shared state handle.
/// The connection should be added to the GLib main loop via
/// `glib::MainContext::channel()`.
pub async fn start_dbus_server(
    initial_state: HomeState,
) -> Result<(zbus::Connection, Arc<Mutex<HomeState>>), String> {
    let state = Arc::new(Mutex::new(initial_state));
    let iface = HomeIface {
        state: state.clone(),
    };

    let conn = zbus::ConnectionBuilder::session()
        .map_err(|e| format!("D-Bus session bus: {e}"))?
        .name(HOME_DBUS_NAME)
        .map_err(|e| format!("D-Bus name {HOME_DBUS_NAME}: {e}"))?
        .serve_at(HOME_DBUS_PATH, iface)
        .map_err(|e| format!("D-Bus serve at {HOME_DBUS_PATH}: {e}"))?
        .build()
        .await
        .map_err(|e| format!("D-Bus build: {e}"))?;

    eprintln!("atomos-home: D-Bus server started at {HOME_DBUS_NAME} {HOME_DBUS_PATH}");
    Ok((conn, state))
}

/// Emit a DragChangedState signal on the D-Bus connection.
/// Called from GTK code when the drag gesture settles.
///
/// Uses `Connection::emit_signal` directly instead of the `#[zbus(signal)]`
/// macro to avoid zbus 4.x macro compatibility issues.
pub async fn emit_drag_state_changed(
    conn: &zbus::Connection,
    new_state: HomeDragState,
) -> Result<(), String> {
    let path = zbus::zvariant::ObjectPath::try_from(HOME_DBUS_PATH)
        .map_err(|e| format!("object path: {e}"))?;
    let iface_name = zbus::names::InterfaceName::try_from(HOME_DBUS_NAME)
        .map_err(|e| format!("interface name: {e}"))?;
    let signal_name = "DragStateChanged";
    let state_str = new_state.as_str();
    let body = Structure::from((state_str,));

    conn.emit_signal(
        None::<&str>,
        &path,
        &iface_name,
        signal_name,
        &body,
    )
    .await
    .map_err(|e| format!("signal emit: {e}"))?;

    Ok(())
}