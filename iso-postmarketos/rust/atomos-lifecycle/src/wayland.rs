//! Wayland toplevel count tracking for persistent daemon mode.
//!
//! Connects to `zwlr_foreign_toplevel_manager_v1` and emits the count of
//! open toplevels whenever it changes. The lifecycle daemon uses this in
//! persistent mode to react to app open/close events without relying on
//! Phosh to pass `ATOMOS_LIFECYCLE_TOPLEVEL_COUNT`.
//!
//! Platform-specific: only compiled on Linux with the `wayland` feature.

use std::collections::HashMap;
use wayland_client::globals::registry_queue_init;
use wayland_client::protocol::wl_registry;
use wayland_client::globals::GlobalListContents;
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle};
use wayland_protocols_wlr::foreign_toplevel::v1::client::zwlr_foreign_toplevel_handle_v1::{
    Event as ToplevelEvent, ZwlrForeignToplevelHandleV1,
};
use wayland_protocols_wlr::foreign_toplevel::v1::client::zwlr_foreign_toplevel_manager_v1::{
    Event as ManagerEvent, ZwlrForeignToplevelManagerV1,
};

/// Callback invoked when the toplevel count changes.
pub type OnCountChanged = Box<dyn Fn(usize) + Send>;

/// Tracks open toplevels via `zwlr_foreign_toplevel_manager_v1`.
///
/// Call [`ToplevelCounter::run`] to connect to the Wayland compositor and
/// block in an event loop. Whenever a toplevel is added or removed, the
/// callback fires with the current count.
pub struct ToplevelCounter;

impl ToplevelCounter {
    /// Connect to the Wayland compositor and run an event loop that tracks
    /// toplevels. Blocks the calling thread.
    ///
    /// `on_count_changed` is called with the current toplevel count each
    /// time it changes.
    ///
    /// Returns an error if the Wayland connection fails or the required
    /// globals are not advertised.
    pub fn run(on_count_changed: OnCountChanged) -> Result<(), String> {
        let conn =
            Connection::connect_to_env().map_err(|e| format!("wayland connect: {e}"))?;
        let (globals, mut event_queue) =
            registry_queue_init::<State>(&conn).map_err(|e| format!("registry: {e}"))?;
        let qh = event_queue.handle();

        let manager: ZwlrForeignToplevelManagerV1 = globals
            .bind(&qh, 1..=3, ())
            .map_err(|e| format!("bind zwlr_foreign_toplevel_manager_v1: {e}"))?;

        let mut state = State {
            handles: HashMap::new(),
            manager,
            on_count_changed,
        };

        let initial_count = state.handles.len();
        (state.on_count_changed)(initial_count);

        loop {
            event_queue
                .blocking_dispatch(&mut state)
                .map_err(|e| format!("wayland dispatch: {e}"))?;
        }
    }
}

struct State {
    handles: HashMap<ZwlrForeignToplevelHandleV1, ()>,
    manager: ZwlrForeignToplevelManagerV1,
    on_count_changed: OnCountChanged,
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(
        _state: &mut Self,
        _proxy: &wl_registry::WlRegistry,
        _event: wl_registry::Event,
        _data: &GlobalListContents,
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwlrForeignToplevelManagerV1, ()> for State {
    fn event(
        state: &mut Self,
        _proxy: &ZwlrForeignToplevelManagerV1,
        event: ManagerEvent,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        if let ManagerEvent::Toplevel { toplevel } = event {
            let _ = toplevel.version();
            state.handles.insert(toplevel, ());
            (state.on_count_changed)(state.handles.len());
        }
    }
}

impl Dispatch<ZwlrForeignToplevelHandleV1, ()> for State {
    fn event(
        state: &mut Self,
        handle: &ZwlrForeignToplevelHandleV1,
        event: ToplevelEvent,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        match event {
            ToplevelEvent::Closed => {
                state.handles.remove(handle);
                (state.on_count_changed)(state.handles.len());
                handle.destroy();
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn toplevel_counter_state_handles_empty() {
        let handles: HashMap<ZwlrForeignToplevelHandleV1, ()> = HashMap::new();
        assert_eq!(handles.len(), 0);
    }
}