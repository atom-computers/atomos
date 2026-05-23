//! Background Wayland client that binds `zwlr_foreign_toplevel_manager_v1`
//! and `wl_seat`, tracks running toplevels, and pushes snapshots to the
//! GTK main loop.
//!
//! Architecture:
//!
//!   GTK main loop (atomos-app-handler process)
//!     - owns `Rc<OverlayController>` and the card widgets
//!     - holds `async_channel::Receiver<Snapshot>` and drains it via
//!       `glib::spawn_future_local`
//!     - calls `ToplevelHandle::activate()` / `ToplevelHandle::close()`
//!       directly from card-gesture callbacks (those proxy methods are
//!       cheap; they queue a request on the shared `wayland_client::
//!       Connection` and the wayland thread flushes it on the next tick)
//!
//!   Wayland thread (spawned once at startup)
//!     - opens its own connection to `WAYLAND_DISPLAY`
//!     - binds the foreign-toplevel-manager and the first available seat
//!     - blocks in `event_queue.blocking_dispatch(state)` and emits a
//!       fresh snapshot whenever the toplevel set changes
//!
//! Why a separate thread and not gtk-rs's wayland-backed `gdk::Display`?
//! The wlr-foreign-toplevel protocol is not exposed by `gdk::Wayland`, so
//! we'd still have to open a side connection. Doing it on a dedicated
//! thread keeps the GTK main loop free of blocking dispatch calls and
//! lets us cleanly shut down by dropping the thread's `JoinHandle`.

use atomos_app_handler::ToplevelEntry;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::thread;
use wayland_client::backend::ObjectId;
use wayland_client::globals::{registry_queue_init, GlobalListContents};
use wayland_client::protocol::{wl_registry, wl_seat};
use wayland_client::{event_created_child, Connection, Dispatch, Proxy, QueueHandle};
use wayland_protocols_wlr::foreign_toplevel::v1::client::{
    zwlr_foreign_toplevel_handle_v1::{self as toplevel_handle, ZwlrForeignToplevelHandleV1},
    zwlr_foreign_toplevel_manager_v1::{
        self as toplevel_manager, ZwlrForeignToplevelManagerV1,
    },
};

/// A snapshot of the running toplevels, paired with handles the card UI
/// can invoke `activate`/`close` on.
pub type Snapshot = Vec<(ToplevelEntry, ToplevelHandle)>;

/// Top-level actions the GTK side can apply to a specific toplevel. Kept
/// in the public surface so other consumers (e.g. unit tests that exercise
/// the wayland module via a mock) can match on it; v1 only emits these
/// from card gestures and immediately resolves them through the
/// `ToplevelHandle::activate()` / `close()` shortcuts, so the variants are
/// currently constructed by external callers only.
#[derive(Debug, Clone)]
#[allow(dead_code)]
pub enum ToplevelAction {
    Activate(u32),
    Close(u32),
}

/// Clonable handle that wraps a `ZwlrForeignToplevelHandleV1` plus the
/// shared `Connection` so the GTK side can fire `activate` / `close`
/// without touching the wayland module's internals.
#[derive(Clone)]
pub struct ToplevelHandle {
    inner: ZwlrForeignToplevelHandleV1,
    seat: wl_seat::WlSeat,
    conn: Connection,
    id: u32,
}

impl ToplevelHandle {
    /// Stable monotonic id mirroring [`ToplevelEntry::id`]. Kept on the
    /// public surface so external consumers can correlate snapshot entries
    /// with their handles; the cards module uses [`ToplevelEntry::id`]
    /// directly so this accessor is currently unused internally.
    #[allow(dead_code)]
    pub fn id(&self) -> u32 {
        self.id
    }

    pub fn activate(&self) {
        self.inner.activate(&self.seat);
        let _ = self.conn.flush();
    }

    pub fn close(&self) {
        self.inner.close();
        let _ = self.conn.flush();
    }
}

impl std::fmt::Debug for ToplevelHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ToplevelHandle")
            .field("id", &self.id)
            .finish()
    }
}

/// Public wayland client handle owned by the GTK side.
#[derive(Clone)]
pub struct WaylandClient {
    snapshots: async_channel::Receiver<Snapshot>,
}

impl WaylandClient {
    /// Spawn the wayland thread and return a handle to the GTK side. Fails
    /// if the wayland connection can't be opened (no `WAYLAND_DISPLAY`,
    /// socket unreadable, etc.) or if the required globals aren't
    /// advertised. The caller is expected to fall back to an empty card
    /// list in that case (the user will see "no running apps" rather than
    /// a crash).
    pub fn spawn() -> Result<Self, WaylandError> {
        let conn = Connection::connect_to_env().map_err(WaylandError::Connect)?;
        let (globals, mut event_queue) =
            registry_queue_init::<State>(&conn).map_err(WaylandError::Registry)?;
        let qh = event_queue.handle();

        let manager: ZwlrForeignToplevelManagerV1 = globals
            .bind(&qh, 1..=3, ())
            .map_err(|err| WaylandError::MissingGlobal {
                interface: "zwlr_foreign_toplevel_manager_v1",
                source: format!("{err}"),
            })?;
        let seat: wl_seat::WlSeat = globals
            .bind(&qh, 1..=8, ())
            .map_err(|err| WaylandError::MissingGlobal {
                interface: "wl_seat",
                source: format!("{err}"),
            })?;

        let (tx, rx) = async_channel::unbounded::<Snapshot>();
        let state = Arc::new(Mutex::new(State::new(
            conn.clone(),
            qh.clone(),
            seat.clone(),
            tx,
            manager.clone(),
        )));

        let state_for_thread = state.clone();
        thread::Builder::new()
            .name("atomos-app-handler-wayland".into())
            .spawn(move || {
                eprintln!("atomos-app-handler: wayland thread started");
                loop {
                    let dispatch_result = {
                        let mut guard = match state_for_thread.lock() {
                            Ok(g) => g,
                            Err(poisoned) => poisoned.into_inner(),
                        };
                        event_queue.blocking_dispatch(&mut guard)
                    };
                    match dispatch_result {
                        Ok(_) => {}
                        Err(err) => {
                            eprintln!(
                                "atomos-app-handler: wayland thread dispatch failed: {err}; \
                                 exiting"
                            );
                            return;
                        }
                    }
                }
            })
            .map_err(WaylandError::ThreadSpawn)?;

        Ok(WaylandClient { snapshots: rx })
    }

    /// Receiver the GTK side polls via `glib::spawn_future_local`.
    pub fn snapshots(&self) -> async_channel::Receiver<Snapshot> {
        self.snapshots.clone()
    }
}

#[derive(Debug)]
pub enum WaylandError {
    Connect(wayland_client::ConnectError),
    Registry(wayland_client::globals::GlobalError),
    MissingGlobal {
        interface: &'static str,
        source: String,
    },
    ThreadSpawn(std::io::Error),
}

impl std::fmt::Display for WaylandError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WaylandError::Connect(e) => write!(f, "wayland connect failed: {e}"),
            WaylandError::Registry(e) => write!(f, "wayland registry init failed: {e}"),
            WaylandError::MissingGlobal { interface, source } => write!(
                f,
                "compositor does not advertise required global '{interface}': {source}"
            ),
            WaylandError::ThreadSpawn(e) => write!(f, "wayland thread spawn failed: {e}"),
        }
    }
}

impl std::error::Error for WaylandError {}

/// Per-toplevel tracked state. We pin a monotonic `id` so the snapshot is
/// `Send` and the GTK side never has to think about Wayland object ids.
struct Tracked {
    id: u32,
    handle: ZwlrForeignToplevelHandleV1,
    title: String,
    app_id: String,
    activated: bool,
    /// `false` until the first `Done` event for this handle. Per protocol,
    /// the manager batches an atomic set of (Title|AppId|State|...) events
    /// terminated by `Done`; we wait for `Done` before pushing snapshots so
    /// the card UI never flickers with half-populated rows.
    ready: bool,
}

struct State {
    conn: Connection,
    /// Stashed for completeness — the protocol's `Dispatch` callbacks
    /// already receive a `&QueueHandle<Self>` parameter so we never need
    /// to read this back in v1. Keeping it on the struct documents the
    /// intent that any future "create child object" requests (e.g.
    /// zwlr_screencopy thumbnails) would route through this handle.
    #[allow(dead_code)]
    qh: QueueHandle<State>,
    seat: wl_seat::WlSeat,
    snapshot_tx: async_channel::Sender<Snapshot>,
    _manager: ZwlrForeignToplevelManagerV1,
    next_id: u32,
    tracked: HashMap<u32, Tracked>,
    /// Reverse map from the Wayland object id to our monotonic id so
    /// event handlers can look up the right `Tracked` entry.
    by_handle_id: HashMap<ObjectId, u32>,
    dirty: bool,
}

impl State {
    fn new(
        conn: Connection,
        qh: QueueHandle<State>,
        seat: wl_seat::WlSeat,
        snapshot_tx: async_channel::Sender<Snapshot>,
        manager: ZwlrForeignToplevelManagerV1,
    ) -> Self {
        Self {
            conn,
            qh,
            seat,
            snapshot_tx,
            _manager: manager,
            next_id: 1,
            tracked: HashMap::new(),
            by_handle_id: HashMap::new(),
            dirty: false,
        }
    }

    fn flush_snapshot_if_dirty(&mut self) {
        if !self.dirty {
            return;
        }
        self.dirty = false;
        let snapshot: Snapshot = self
            .tracked
            .values()
            .filter(|t| t.ready)
            .map(|t| {
                let entry = ToplevelEntry {
                    id: t.id,
                    app_id: t.app_id.clone(),
                    title: t.title.clone(),
                    activated: t.activated,
                };
                let handle = ToplevelHandle {
                    inner: t.handle.clone(),
                    seat: self.seat.clone(),
                    conn: self.conn.clone(),
                    id: t.id,
                };
                (entry, handle)
            })
            .collect();
        // Best-effort: if the receiver is gone the GTK side has already
        // exited, so drop the message.
        let _ = self.snapshot_tx.try_send(snapshot);
    }
}

// Registry: we don't need globals during operation (we bound everything
// up-front via `registry_queue_init`), so this Dispatch is a no-op.
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
        event: toplevel_manager::Event,
        _data: &(),
        _conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        match event {
            toplevel_manager::Event::Toplevel { toplevel } => {
                let id = state.next_id;
                state.next_id = state.next_id.wrapping_add(1).max(1);
                state
                    .by_handle_id
                    .insert(toplevel.id(), id);
                state.tracked.insert(
                    id,
                    Tracked {
                        id,
                        handle: toplevel,
                        title: String::new(),
                        app_id: String::new(),
                        activated: false,
                        ready: false,
                    },
                );
                let _ = qh; // suppress unused warning when no compile-time use below
            }
            toplevel_manager::Event::Finished => {
                eprintln!(
                    "atomos-app-handler: foreign-toplevel manager Finished; \
                     clearing tracked toplevels"
                );
                state.tracked.clear();
                state.by_handle_id.clear();
                state.dirty = true;
                state.flush_snapshot_if_dirty();
            }
            _ => {}
        }
    }

    // The `toplevel` event (opcode 0) ferries a freshly created
    // `ZwlrForeignToplevelHandleV1` proxy. wayland-client 0.31 requires the
    // Dispatch impl to declare the child interface + UserData up front
    // here; without this override the default impl panics with:
    //   "Missing event_created_child specialization for event opcode 0 of
    //    zwlr_foreign_toplevel_manager_v1"
    // which kills the wayland thread right after the first toplevel is
    // advertised (see the launcher log captured by diagnose-app-switcher.sh).
    // The macro lives inside the impl block so it can override the auto-
    // generated trait method.
    event_created_child!(State, ZwlrForeignToplevelManagerV1, [
        toplevel_manager::EVT_TOPLEVEL_OPCODE => (ZwlrForeignToplevelHandleV1, ()),
    ]);
}

impl Dispatch<ZwlrForeignToplevelHandleV1, ()> for State {
    fn event(
        state: &mut Self,
        proxy: &ZwlrForeignToplevelHandleV1,
        event: toplevel_handle::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        let our_id = match state.by_handle_id.get(&proxy.id()).copied() {
            Some(v) => v,
            None => return, // unknown handle (manager Finished, late event, etc.)
        };
        let Some(tracked) = state.tracked.get_mut(&our_id) else {
            return;
        };

        match event {
            toplevel_handle::Event::Title { title } => {
                tracked.title = title;
            }
            toplevel_handle::Event::AppId { app_id } => {
                tracked.app_id = app_id;
            }
            toplevel_handle::Event::State { state: raw_state } => {
                // Per protocol, the `state` argument is an array of
                // little-endian u32 values from the `State` enum:
                // 0=maximized, 1=minimized, 2=activated, 3=fullscreen.
                tracked.activated = raw_state
                    .chunks_exact(4)
                    .any(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]) == 2);
            }
            toplevel_handle::Event::Done => {
                if !tracked.ready {
                    tracked.ready = true;
                }
                state.dirty = true;
                state.flush_snapshot_if_dirty();
            }
            toplevel_handle::Event::Closed => {
                // Per protocol we still need to destroy() the proxy to free
                // the server-side resource.
                tracked.handle.destroy();
                state.by_handle_id.remove(&proxy.id());
                state.tracked.remove(&our_id);
                state.dirty = true;
                state.flush_snapshot_if_dirty();
            }
            toplevel_handle::Event::OutputEnter { .. }
            | toplevel_handle::Event::OutputLeave { .. }
            | toplevel_handle::Event::Parent { .. } => {
                // We don't care which output the toplevel sits on (the
                // switcher is multi-output unaware in v1) and we don't
                // currently fold parented popups into the card row.
            }
            _ => {}
        }
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(
        _state: &mut Self,
        _proxy: &wl_seat::WlSeat,
        _event: wl_seat::Event,
        _data: &(),
        _conn: &Connection,
        _qh: &QueueHandle<Self>,
    ) {
        // We only use the seat for `toplevel.activate(seat)`; we don't need
        // to track capabilities or name.
    }
}
