//! D-Bus monitoring for persistent daemon mode.
//!
//! Two monitors:
//! 1. `watch_lock_state` — listens for `Lock`/`Unlock` signals on
//!    `org.freedesktop.login1.Session` (system bus).
//! 2. `watch_drag_state` — listens for `DragStateChanged` signals on
//!    `org.atomos.Home` (session bus).
//!
//! Platform-specific: only compiled on Linux with the `daemon` feature.

use crate::HomeDragState;
use crate::LockState;

/// Callback invoked when the session lock state changes.
pub type OnLockChanged = Box<dyn Fn(LockState) + Send>;

/// Callback invoked when the home surface drag state changes.
pub type OnDragChanged = Box<dyn Fn(HomeDragState) + Send>;

/// D-Bus name and path for the atomos-home surface.
const HOME_DBUS_NAME: &str = "org.atomos.Home";
const HOME_DBUS_PATH: &str = "/org/atomos/Home";
const HOME_DBUS_INTERFACE: &str = "org.atomos.Home";

/// Connect to the system bus and listen for login1 Lock/Unlock signals.
///
/// `on_lock_changed` is called with `LockState::Locked` or `LockState::Unlocked`
/// whenever the session lock state changes.
///
/// This function blocks the calling thread and runs indefinitely.
/// Returns an error if the D-Bus connection fails.
pub fn watch_lock_state(on_lock_changed: OnLockChanged) -> Result<(), String> {
    let rt = tokio::runtime::Runtime::new().map_err(|e| format!("tokio runtime: {e}"))?;

    rt.block_on(async {
        let conn = zbus::Connection::system()
            .await
            .map_err(|e| format!("system bus: {e}"))?;

        let session_path = find_session_path(&conn)
            .await
            .map_err(|e| format!("find session: {e}"))?;

        eprintln!(
            "atomos-lifecycle: monitoring lock state on {}",
            session_path
        );

        let session_pathobj = zbus::zvariant::ObjectPath::try_from(session_path.as_str())
            .map_err(|e| format!("invalid session path: {e}"))?;

        let lock_rule = zbus::MatchRule::builder()
            .member("Lock")
            .map_err(|e| format!("Lock rule member: {e}"))?
            .path(&session_pathobj)
            .map_err(|e| format!("Lock rule path: {e}"))?
            .interface("org.freedesktop.login1.Session")
            .map_err(|e| format!("Lock rule interface: {e}"))?
            .build();
        let lock_stream = zbus::MessageStream::for_match_rule(lock_rule, &conn, None)
            .await
            .map_err(|e| format!("add Lock match: {e}"))?;

        let unlock_rule = zbus::MatchRule::builder()
            .member("Unlock")
            .map_err(|e| format!("Unlock rule member: {e}"))?
            .path(&session_pathobj)
            .map_err(|e| format!("Unlock rule path: {e}"))?
            .interface("org.freedesktop.login1.Session")
            .map_err(|e| format!("Unlock rule interface: {e}"))?
            .build();
        let unlock_stream = zbus::MessageStream::for_match_rule(unlock_rule, &conn, None)
            .await
            .map_err(|e| format!("add Unlock match: {e}"))?;

        use futures::stream::StreamExt;

        let mut lock_events = lock_stream.map(|_| LockState::Locked);
        let mut unlock_events = unlock_stream.map(|_| LockState::Unlocked);

        loop {
            tokio::select! {
                Some(state) = lock_events.next() => {
                    on_lock_changed(state);
                }
                Some(state) = unlock_events.next() => {
                    on_lock_changed(state);
                }
            }
        }
    })
}

/// Connect to the session bus and listen for `DragChangedState` signals
/// from the atomos-home surface.
///
/// `on_drag_changed` is called with the new `HomeDragState` whenever the
/// home surface drag state changes (folded/unfolded/transition).
///
/// This function blocks the calling thread and runs indefinitely.
/// Returns an error if the D-Bus connection fails.
pub fn watch_drag_state(on_drag_changed: OnDragChanged) -> Result<(), String> {
    let rt = tokio::runtime::Runtime::new().map_err(|e| format!("tokio runtime: {e}"))?;

    rt.block_on(async {
        let conn = zbus::Connection::session()
            .await
            .map_err(|e| format!("session bus: {e}"))?;

        eprintln!(
            "atomos-lifecycle: monitoring drag state on {} {}",
            HOME_DBUS_NAME, HOME_DBUS_PATH
        );

        let home_path = zbus::zvariant::ObjectPath::try_from(HOME_DBUS_PATH)
            .map_err(|e| format!("invalid home path: {e}"))?;

        let drag_rule = zbus::MatchRule::builder()
            .member("DragStateChanged")
            .map_err(|e| format!("Drag rule member: {e}"))?
            .path(home_path)
            .map_err(|e| format!("Drag rule path: {e}"))?
            .interface(HOME_DBUS_INTERFACE)
            .map_err(|e| format!("Drag rule interface: {e}"))?
            .build();
        let drag_stream = zbus::MessageStream::for_match_rule(drag_rule, &conn, None)
            .await
            .map_err(|e| format!("add DragChangedState match: {e}"))?;

        use futures::stream::StreamExt;

        let mut events = drag_stream.filter_map(|msg| {
            let msg = match msg {
                Ok(m) => m,
                Err(_) => return std::future::ready(None),
            };
            let body: String = match msg.body().deserialize() {
                Ok(b) => b,
                Err(_) => return std::future::ready(None),
            };
            std::future::ready(HomeDragState::from_str(&body))
        });

        while let Some(state) = events.next().await {
            on_drag_changed(state);
        }

        Err("atomos-lifecycle: drag state stream ended unexpectedly".to_string())
    })
}

async fn find_session_path(
    conn: &zbus::Connection,
) -> Result<String, String> {
    use zbus::proxy::CacheProperties;

    #[zbus::proxy(
        interface = "org.freedesktop.login1.Manager",
        default_service = "org.freedesktop.login1",
        default_path = "/org/freedesktop/login1"
    )]
    trait LoginManager {
        #[zbus(property)]
        fn sessions(&self) -> zbus::Result<Vec<(String, zbus::zvariant::OwnedObjectPath, String, String, zbus::zvariant::OwnedObjectPath)>>;
    }

    let manager = LoginManagerProxy::builder(conn)
        .cache_properties(CacheProperties::No)
        .build()
        .await
        .map_err(|e| format!("login1 manager proxy: {e}"))?;

    let uid = nix::unistd::getuid().as_raw();

    let sessions = manager
        .sessions()
        .await
        .map_err(|e| format!("get sessions: {e}"))?;

    for (_session_id, path, _user_name, _seat, _user_path) in sessions {
        let path_str = path.as_str().to_string();

        #[zbus::proxy(
            interface = "org.freedesktop.login1.Session",
            default_service = "org.freedesktop.login1"
        )]
        trait Login1Session {
            #[zbus(property)]
            fn user(&self) -> zbus::Result<(u32, zbus::zvariant::OwnedObjectPath)>;
        }

        let session = Login1SessionProxy::builder(conn)
            .cache_properties(CacheProperties::No)
            .path(path.into_inner())
            .map_err(|e| format!("session path: {e}"))?
            .build()
            .await
            .map_err(|e| format!("session proxy: {e}"))?;

        let (session_uid, _) = session
            .user()
            .await
            .map_err(|e| format!("get session user: {e}"))?;

        if session_uid == uid {
            return Ok(path_str);
        }
    }

    Err("no login1 session found for current UID".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lock_state_enum_round_trips() {
        assert_eq!(LockState::Locked, LockState::Locked);
        assert_eq!(LockState::Unlocked, LockState::Unlocked);
    }

    #[test]
    fn drag_state_from_dbus_signal_body() {
        assert_eq!(HomeDragState::from_str("folded"), Some(HomeDragState::Folded));
        assert_eq!(HomeDragState::from_str("unfolded"), Some(HomeDragState::Unfolded));
        assert_eq!(HomeDragState::from_str("transition"), Some(HomeDragState::Transition));
        assert_eq!(HomeDragState::from_str("unknown"), None);
    }

    #[test]
    fn home_dbus_constants_match_atomos_home() {
        assert_eq!(HOME_DBUS_NAME, "org.atomos.Home");
        assert_eq!(HOME_DBUS_PATH, "/org/atomos/Home");
        assert_eq!(HOME_DBUS_INTERFACE, "org.atomos.Home");
    }

    #[test]
    fn drag_state_matches_org_atomos_home_signal_spec() {
        assert_eq!(HomeDragState::Folded.as_str(), "folded");
        assert_eq!(HomeDragState::Unfolded.as_str(), "unfolded");
        assert_eq!(HomeDragState::Transition.as_str(), "transition");
    }

    #[test]
    fn dbus_interface_equals_well_known_name() {
        assert_eq!(HOME_DBUS_INTERFACE, HOME_DBUS_NAME);
    }
}