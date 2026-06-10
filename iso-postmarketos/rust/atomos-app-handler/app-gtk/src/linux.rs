//! Linux implementation of `atomos-app-handler`.
//!
//! Two layer-shell surfaces live in the same process:
//!
//!   - `handle_window` — bottom-anchored `Layer::Top` strip (24 px by
//!     default) with `exclusive_zone = handle_height_px` so the foreground
//!     app and virtual keyboards are laid out above it. Paints only the
//!     visible scrim + pill chrome.
//!   - `fade_window` — full-screen `Layer::Overlay` (anchors L+R+T+B) that
//!     stays transparent when idle. During a swipe-up drag it cross-fades
//!     the foreground app content area (excluding the top bar and bottom
//!     handle insets) to opaque. The bottom strip of this surface captures
//!     the gesture; going full-screen keeps the wayland implicit pointer grab
//!     alive for the entire upward drag.
//!
//! Swipe-up closes the foreground app. No switcher overlay is opened.
//!
//! All policy is composed in `atomos_app_handler::compose_runtime_config`;
//! this file just wires policy → live widgets. Lifecycle events are logged
//! with the `atomos-app-handler:` tag so the launcher's
//! `$XDG_RUNTIME_DIR/atomos-app-handler.log` reads as a step-by-step trace
//! of the gesture pipeline.

use atomos_app_handler::{
    compose_runtime_config, evaluate_swipe_up, gtk_argv_for_run_from_process_argv,
    handle_drag_progress, launch::plan_launch, parse_lifecycle_action_from_argv,
    should_show_handle, EnvInputs, GestureConfig, LaunchPlan, LifecycleAction,
    HomeIpc, RuntimeConfig, SwipeOutcome,
    LAYER_SHELL_NAMESPACE,
};
use gtk::gio;
use gtk::glib;
use gtk::prelude::*;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use std::cell::RefCell;
use std::process::Command;
use std::rc::Rc;

mod handle;
mod input_region;
mod launch_exec;
mod home_ipc;
mod transparent;
mod wayland;

use wayland::{ToplevelHandle, WaylandClient};

/// One-line, syslog-friendly event log. The launcher script in
/// [`install-app-handler.sh`](../../../scripts/app-handler/install-app-handler.sh)
/// redirects stderr into `$XDG_RUNTIME_DIR/atomos-app-handler.log`, so every
/// line emitted here ends up in a per-session log file the diagnose script
/// (and the user) can tail.
macro_rules! event {
    ($($arg:tt)*) => {
        eprintln!("atomos-app-handler: {}", format_args!($($arg)*))
    };
}

const DEBUG_TINT_ENV: &str = "ATOMOS_APP_HANDLER_DEBUG_TINT";

fn debug_tint_enabled() -> bool {
    matches!(std::env::var(DEBUG_TINT_ENV).as_deref(), Ok("1"))
}

fn log_startup_env() {
    let pid = std::process::id();
    let runtime = std::env::var("ATOMOS_APP_HANDLER_ENABLE_RUNTIME").unwrap_or_else(|_| "<unset>".into());
    let wayland = std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "<unset>".into());
    let xdg_runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "<unset>".into());
    let display = std::env::var("DISPLAY").unwrap_or_else(|_| "<unset>".into());
    let gdk_backend = std::env::var("GDK_BACKEND").unwrap_or_else(|_| "<unset>".into());
    let handle_h = std::env::var("ATOMOS_APP_HANDLER_HANDLE_HEIGHT").unwrap_or_else(|_| "<unset>".into());
    let open_thr = std::env::var("ATOMOS_APP_HANDLER_OPEN_THRESHOLD_PX").unwrap_or_else(|_| "<unset>".into());
    let dismiss_thr = std::env::var("ATOMOS_APP_HANDLER_DISMISS_THRESHOLD_PX").unwrap_or_else(|_| "<unset>".into());
    let debug_tint = std::env::var(DEBUG_TINT_ENV).unwrap_or_else(|_| "<unset>".into());
    event!(
        "startup pid={pid} ATOMOS_APP_HANDLER_ENABLE_RUNTIME={runtime} \
         WAYLAND_DISPLAY={wayland} XDG_RUNTIME_DIR={xdg_runtime} DISPLAY={display} \
         GDK_BACKEND={gdk_backend} \
         ATOMOS_APP_HANDLER_HANDLE_HEIGHT={handle_h} \
         ATOMOS_APP_HANDLER_OPEN_THRESHOLD_PX={open_thr} \
         ATOMOS_APP_HANDLER_DISMISS_THRESHOLD_PX={dismiss_thr} \
         ATOMOS_APP_HANDLER_DEBUG_TINT={debug_tint}"
    );
}

pub fn run() -> anyhow::Result<()> {
    log_startup_env();

    let action = parse_lifecycle_action_from_argv();
    event!("lifecycle action={action:?}");

    if matches!(action, LifecycleAction::Hide) {
        event!("--hide received cold (no running process to signal); exiting");
        return Ok(());
    }

    if let LifecycleAction::Launch { app_id } = action {
        return run_launch_once(&app_id);
    }

    let cfg = compose_runtime_config(&EnvInputs::from_process_env());
    event!(
        "compose_runtime_config runtime_enabled={} gestures={:?}",
        cfg.runtime_enabled, cfg.gestures
    );
    if !cfg.runtime_enabled {
        event!(
            "ATOMOS_APP_HANDLER_ENABLE_RUNTIME!=1; exiting without presenting a surface"
        );
        return Ok(());
    }

    let app = gtk::Application::builder()
        .application_id("org.atomos.AppHandler")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();

    let cfg_for_activate = cfg.clone();
    let action_for_activate = action;
    app.connect_activate(move |app| {
        event!("gtk::Application activated");
        if let Err(err) = build_ui(app, &cfg_for_activate, action_for_activate.clone()) {
            event!("build_ui failed: {err:#}");
            app.quit();
        }
    });

    // We've already consumed our private lifecycle flags (--start /
    // --hide / launch) via parse_lifecycle_action_from_argv.
    // Hand gtk only the program name; otherwise g_application_run's
    // option parser sees `--start` (or `--hide`), errors with
    // `Unknown option --start`, and exits rc=1.
    let gtk_argv = gtk_argv_for_run_from_process_argv();
    event!("entering gtk::Application::run_with_args main loop argv={gtk_argv:?}");
    let exit_code = app.run_with_args(&gtk_argv);
    event!("gtk::Application::run_with_args returned exit_code={exit_code:?}");
    Ok(())
}

fn run_launch_once(app_id: &str) -> anyhow::Result<()> {
    if app_id.trim().is_empty() {
        anyhow::bail!("launch requires an app id");
    }

    gtk::init().map_err(|e| anyhow::anyhow!("gtk init failed: {e}"))?;

    if let Ok(client) = WaylandClient::spawn() {
        std::thread::sleep(std::time::Duration::from_millis(150));
        let entries: Vec<_> = client
            .snapshots()
            .try_recv()
            .unwrap_or_default()
            .into_iter()
            .map(|(e, _)| e)
            .collect();
        if let LaunchPlan::ActivateExisting { toplevel_id } = plan_launch(&entries, app_id) {
            if let Ok(snapshot) = client.snapshots().try_recv() {
                if let Some((_, handle)) = snapshot.iter().find(|(e, _)| e.id == toplevel_id) {
                    handle.activate();
                    event!("launch: activated existing toplevel id={toplevel_id}");
                    return Ok(());
                }
            }
        }
    }

    launch_exec::spawn_desktop_app(app_id).map_err(|e| anyhow::anyhow!(e))?;
    Ok(())
}

/// Shared state between the handle/fade windows and the wayland thread.
///
/// Swipe-up closes the foreground app — no switcher overlay is opened.
pub(crate) struct HandlerState {
    pub(crate) gestures: GestureConfig,
    pub(crate) handle_drag_dy: RefCell<f64>,
    /// `[0.0, 1.0]` fade-overlay alpha driven by the live `GestureDrag`
    /// accumulator. Painted by the handle canvas's draw function (see
    /// `linux/handle.rs::install_handle_paint`) so the running app fades
    /// out as the user drags upward. Reset to 0.0 on drag_end so a
    /// subsequent drag always starts from a fully transparent fade.
    pub(crate) handle_drag_progress: RefCell<f32>,
    pub(crate) toplevel_count: RefCell<usize>,
    pub(crate) first_run: RefCell<bool>,
    /// Visible handle chrome on `Layer::Bottom`, below the foreground app.
    pub(crate) handle_window: RefCell<Option<gtk::ApplicationWindow>>,
    /// Full-screen gesture + fade overlay above the foreground app.
    pub(crate) fade_window: RefCell<Option<gtk::ApplicationWindow>>,
    pub(crate) snapshot: RefCell<Vec<(atomos_app_handler::ToplevelEntry, ToplevelHandle)>>,
    pub(crate) session_locked: std::cell::Cell<bool>,
    pub(crate) swipe_triggered: std::cell::Cell<bool>,
}

impl HandlerState {
    pub(crate) fn new(gestures: GestureConfig) -> Self {
        Self {
            gestures,
            handle_drag_dy: RefCell::new(0.0),
            handle_drag_progress: RefCell::new(0.0),
            toplevel_count: RefCell::new(0),
            first_run: RefCell::new(true),
            handle_window: RefCell::new(None),
            fade_window: RefCell::new(None),
            snapshot: RefCell::new(Vec::new()),
            session_locked: std::cell::Cell::new(false),
            swipe_triggered: std::cell::Cell::new(false),
        }
    }

    pub(crate) fn on_toplevel_count_changed(&self, new_count: usize) {
        let is_first = {
            let mut first = self.first_run.borrow_mut();
            let was_first = *first;
            *first = false;
            was_first
        };
        let prev = *self.toplevel_count.borrow();
        if prev == new_count && !is_first {
            return;
        }
        *self.toplevel_count.borrow_mut() = new_count;

        let visible = should_show_handle(new_count) && !self.session_locked.get();
        for (name, win) in [
            ("handle_window", self.handle_window.borrow()),
            ("fade_window", self.fade_window.borrow()),
        ] {
            if let Some(win) = win.as_ref() {
                win.set_visible(visible);
                if visible {
                    win.present();
                }
                event!("{name} visible={visible} (toplevel_count {prev} -> {new_count})");
            }
        }
    }

    fn set_handle_surfaces_visible(&self, visible: bool) {
        let actual_visible = visible && !self.session_locked.get();
        for (name, win) in [
            ("handle_window", self.handle_window.borrow()),
            ("fade_window", self.fade_window.borrow()),
        ] {
            if let Some(win) = win.as_ref() {
                win.set_visible(actual_visible);
                if actual_visible {
                    win.present();
                }
                event!("{name} visible={actual_visible} (requested={visible}, locked={})", self.session_locked.get());
            }
        }
    }
}

fn build_ui(app: &gtk::Application, cfg: &RuntimeConfig, _action: LifecycleAction) -> anyhow::Result<()> {
    let layer_shell_ok = gtk4_layer_shell::is_supported();
    event!("gtk4_layer_shell::is_supported() = {layer_shell_ok}");
    if !layer_shell_ok {
        event!(
            "layer-shell unsupported by this compositor; exiting to avoid falling back \
             to a decorated toplevel"
        );
        app.quit();
        return Ok(());
    }

    transparent::install_css();

    let state = Rc::new(HandlerState::new(cfg.gestures));

    let wayland = match WaylandClient::spawn() {
        Ok(client) => {
            event!("WaylandClient::spawn ok");
            Some(client)
        }
        Err(err) => {
            event!(
                "WaylandClient::spawn failed: {err}; continuing with empty toplevel list"
            );
            None
        }
    };

    // The bottom-edge handle is *not* mapped on the home screen. It only
    // appears when at least one Wayland toplevel exists (i.e. an app is in
    // the foreground).
    let handle_window = build_handle_strip_window(app, state.clone());
    handle_window.set_visible(false);
    *state.handle_window.borrow_mut() = Some(handle_window);
    event!("handle_window built; hidden until first toplevel appears");

    let fade_window = build_fade_window(app, state.clone());
    fade_window.set_visible(false);
    *state.fade_window.borrow_mut() = Some(fade_window);
    event!("fade_window built; hidden until first toplevel appears");

    init_lock_tracking(state.clone());

    if let Some(client) = wayland {
        spawn_snapshot_drain(state.clone(), client);
    }

    Ok(())
}

fn build_handle_strip_window(
    app: &gtk::Application,
    state: Rc<HandlerState>,
) -> gtk::ApplicationWindow {
    let handle_height_px = state.gestures.handle_height_px;
    let win = gtk::ApplicationWindow::builder()
        .application(app)
        .title("AtomOS App Handler (handle)")
        .decorated(false)
        .build();
    win.set_can_focus(false);
    win.add_css_class("atomos-app-handler-transparent-window");
    configure_layer_surface(&win, LayerSurfaceRole::HandleStrip, handle_height_px);

    let handle_canvas = gtk::DrawingArea::new();
    handle_canvas.set_widget_name("atomos-app-handler-handle");
    handle_canvas.set_hexpand(true);
    handle_canvas.set_vexpand(true);
    handle_canvas.set_can_target(false);
    handle_canvas.set_focusable(false);
    handle_canvas.set_content_height(handle_height_px);

    let debug_tint = debug_tint_enabled();
    if debug_tint {
        event!("debug-tint enabled on handle strip");
    }
    handle::install_handle_paint(&handle_canvas, debug_tint);

    handle_canvas.connect_resize(|_, width, height| {
        event!("handle_canvas resize width={width} height={height}");
    });

    win.set_child(Some(&handle_canvas));

    win.connect_realize(|_| event!("handle_window realize"));
    win.connect_map(move |w| {
        let alloc = w.allocation();
        event!(
            "handle_window map width={} height={} (bottom strip; \
             exclusive_zone={handle_height_px}px below foreground app)",
            alloc.width(),
            alloc.height(),
        );
    });
    win.connect_unmap(|_| event!("handle_window unmap"));

    // Visual-only strip on Layer::Bottom — input is owned by fade_window.
    input_region::apply_non_interactive_input_region(&win, &handle_canvas);

    win
}

fn build_fade_window(
    app: &gtk::Application,
    state: Rc<HandlerState>,
) -> gtk::ApplicationWindow {
    let handle_height_px = state.gestures.handle_height_px;
    let win = gtk::ApplicationWindow::builder()
        .application(app)
        .title("AtomOS App Switcher (gesture)")
        .decorated(false)
        .build();
    win.set_can_focus(false);
    win.add_css_class("atomos-app-handler-transparent-window");
    configure_layer_surface(&win, LayerSurfaceRole::GestureFade, handle_height_px);

    let root = gtk::Overlay::new();
    root.set_widget_name("atomos-app-handler-gesture");
    root.set_hexpand(true);
    root.set_vexpand(true);

    let fade_canvas = gtk::DrawingArea::new();
    fade_canvas.set_hexpand(true);
    fade_canvas.set_vexpand(true);
    // Must be targetable so GTK4's in-process hit-testing detects touches on this canvas,
    // which then propagate to the parent GestureDrag controller on root.
    fade_canvas.set_can_target(true);
    fade_canvas.set_focusable(false);

    let ctl_for_paint = state.clone();
    let ctl_for_dy = state.clone();
    let debug_tint = debug_tint_enabled();
    if debug_tint {
        event!("debug-tint enabled on fade/gesture window");
    }
    handle::install_fade_paint(
        &fade_canvas,
        handle_height_px,
        debug_tint,
        move || *ctl_for_paint.handle_drag_progress.borrow(),
        move || *ctl_for_dy.handle_drag_dy.borrow(),
    );

    // Gesture controller on the full-screen root. Wayland input is narrowed
    // to the bottom strip via `input_region`; drag_begin rejects touches
    // outside that strip so the compositor can pass clicks through elsewhere.
    let drag = gtk::GestureDrag::new();
    drag.set_button(0);
    drag.set_touch_only(false);
    drag.set_propagation_phase(gtk::PropagationPhase::Capture);
    drag.set_exclusive(true);

    let ctl_begin = state.clone();
    let fade_canvas_for_begin = fade_canvas.clone();
    let root_for_begin = root.clone();
    let handle_h_begin = handle_height_px;
    drag.connect_drag_begin(move |gesture, sx, sy| {
        let alloc = root_for_begin.allocation();
        let bottom_y = alloc.height().saturating_sub(handle_h_begin) as f64;
        if sy < bottom_y {
            gesture.set_state(gtk::EventSequenceState::Denied);
            event!(
                "handle drag_begin sx={sx:.1} sy={sy:.1} bottom_y={bottom_y:.1}"
            );
            return;
        }
        ctl_begin.swipe_triggered.set(false);
        *ctl_begin.handle_drag_dy.borrow_mut() = 0.0;
        *ctl_begin.handle_drag_progress.borrow_mut() = 0.0;
        fade_canvas_for_begin.queue_draw();

        // Expand the input region to cover full height so touch is not dropped on upward swipe
        if let Some(win) = ctl_begin.fade_window.borrow().as_ref() {
            let alloc = win.allocation();
            input_region::set_input_region_height(win, alloc.height());
        }

        let claimed = gesture.set_state(gtk::EventSequenceState::Claimed);
        event!("handle drag_begin sx={sx:.1} sy={sy:.1} claimed={claimed}");
    });

    let ctl_update = state.clone();
    let fade_canvas_for_update = fade_canvas.clone();
    drag.connect_drag_update(move |_, ox, oy| {
        if ctl_update.swipe_triggered.get() {
            return;
        }
        *ctl_update.handle_drag_dy.borrow_mut() = oy;
        let progress = handle_drag_progress(oy, &ctl_update.gestures);
        *ctl_update.handle_drag_progress.borrow_mut() = progress;
        fade_canvas_for_update.queue_draw();

        // Fade out the bottom handle_window as the user swipes up
        if let Some(win) = ctl_update.handle_window.borrow().as_ref() {
            win.set_opacity((1.0 - progress) as f64);
        }

        let outcome = evaluate_swipe_up(oy, &ctl_update.gestures);
        event!(
            "handle drag_update ox={ox:.1} oy={oy:.1} progress={progress:.3} \
             outcome={outcome:?} threshold_px={}",
            ctl_update.gestures.open_threshold_px
        );
        if matches!(outcome, SwipeOutcome::CloseApp) {
            ctl_update.swipe_triggered.set(true);
            
            // Find the active window from snapshot where entry.activated is true
            let snapshot = ctl_update.snapshot.borrow();
            if let Some((entry, handle)) = snapshot.iter().find(|(entry, _)| entry.activated) {
                event!("swipe-up threshold reached: backgrounding application id={} app_id={}", entry.id, entry.app_id);
                handle.close();
            } else if let Some((entry, handle)) = snapshot.first() {
                event!("swipe-up threshold reached: fallback backgrounding application id={} app_id={}", entry.id, entry.app_id);
                handle.close();
            } else {
                event!("swipe-up threshold reached but no active application found in snapshot");
            }

            home_ipc::close_osk_keyboard();
            *ctl_update.handle_drag_dy.borrow_mut() = 0.0;
            *ctl_update.handle_drag_progress.borrow_mut() = 0.0;
            fade_canvas_for_update.queue_draw();
        }
    });

    let ctl_end = state.clone();
    let fade_canvas_for_end = fade_canvas.clone();
    drag.connect_drag_end(move |_, ox, oy| {
        let dy = *ctl_end.handle_drag_dy.borrow();
        *ctl_end.handle_drag_progress.borrow_mut() = 0.0;
        *ctl_end.handle_drag_dy.borrow_mut() = 0.0;
        fade_canvas_for_end.queue_draw();

        // Reset input region back to the narrow bottom strip
        if let Some(win) = ctl_end.fade_window.borrow().as_ref() {
            input_region::set_input_region_height(win, ctl_end.gestures.handle_height_px);
        }

        // Restore handle opacity to fully opaque
        if let Some(win) = ctl_end.handle_window.borrow().as_ref() {
            win.set_opacity(1.0);
        }

        event!("handle drag_end ox={ox:.1} oy={oy:.1} accumulated_dy={dy:.1}");
    });

    root.add_controller(drag);

    let event_probe = gtk::EventControllerLegacy::new();
    event_probe.set_propagation_phase(gtk::PropagationPhase::Capture);
    event_probe.connect_event(|_, ev| {
        let ev_type = ev.event_type();
        let device = ev
            .device()
            .map(|d| d.name().to_string())
            .unwrap_or_else(|| "<none>".into());
        event!("handle event_probe type={ev_type:?} device={device}");
        glib::Propagation::Proceed
    });
    root.add_controller(event_probe);

    root.set_child(Some(&fade_canvas));
    win.set_child(Some(&root));

    win.connect_notify_local(Some("height"), move |w, _| {
        let alloc = w.allocation();
        event!(
            "gesture_root resize width={} height={}",
            alloc.width(),
            alloc.height()
        );
    });

    input_region::apply_bottom_strip_input_region(&win, &fade_canvas, handle_height_px);
    input_region::apply_translucent_opaque_hint(&win);

    win.connect_realize(|_| event!("fade_window realize"));
    win.connect_map(move |w| {
        let alloc = w.allocation();
        event!(
            "fade_window map width={} height={} (full-screen overlay; \
             fade excludes top bar + bottom {handle_height_px}px strip)",
            alloc.width(),
            alloc.height(),
        );
    });
    win.connect_unmap(|_| event!("fade_window unmap"));

    win
}




#[derive(Debug, Clone, Copy)]
enum LayerSurfaceRole {
    HandleStrip,
    GestureFade,
}

fn configure_layer_surface(
    win: &gtk::ApplicationWindow,
    role: LayerSurfaceRole,
    handle_height_px: i32,
) {
    win.init_layer_shell();
    let namespace = match role {
        LayerSurfaceRole::HandleStrip => format!("{LAYER_SHELL_NAMESPACE}.handle"),
        LayerSurfaceRole::GestureFade => format!("{LAYER_SHELL_NAMESPACE}.gesture"),
    };
    win.set_namespace(Some(namespace.as_str()));
    match role {
        LayerSurfaceRole::HandleStrip | LayerSurfaceRole::GestureFade => {
            win.set_layer(Layer::Overlay);
        }
    }

    match role {
        LayerSurfaceRole::HandleStrip => {
            // Bottom strip on Layer::Overlay so the virtual keyboard (which
            // resides on Top or Overlay) respects its exclusive_zone and sits
            // above it on both QEMU and Fairphone 4. `exclusive_zone`
            // reserves the inset so xdg-toplevels lay out in the window
            // between the top bar and this handle.
            win.set_anchor(Edge::Left, true);
            win.set_anchor(Edge::Right, true);
            win.set_anchor(Edge::Bottom, true);
            win.set_anchor(Edge::Top, false);
            win.set_exclusive_zone(handle_height_px);
            win.set_keyboard_mode(KeyboardMode::None);
        }
        LayerSurfaceRole::GestureFade => {
            // Full-screen overlay so the wayland implicit pointer grab
            // survives the entire upward drag without GrabBroken.
            win.set_anchor(Edge::Left, true);
            win.set_anchor(Edge::Right, true);
            win.set_anchor(Edge::Bottom, true);
            win.set_anchor(Edge::Top, true);
            win.set_exclusive_zone(-1);
            win.set_keyboard_mode(KeyboardMode::None);
        }
    }

    let layer_name = "overlay";
    event!(
        "layer-shell configured role={role:?} namespace={namespace} layer={layer_name} \
         handle_height_px={handle_height_px}"
    );
}


fn spawn_snapshot_drain(state: Rc<HandlerState>, client: WaylandClient) {
    let rx = client.snapshots();
    glib::spawn_future_local(async move {
        while let Ok(snapshot) = rx.recv().await {
            event!("snapshot received len={}", snapshot.len());
            *state.snapshot.borrow_mut() = snapshot.clone();
            state.on_toplevel_count_changed(snapshot.len());
        }
        event!("snapshot drain loop ended (wayland channel closed)");
    });
}

fn track_system_theme<W: IsA<gtk::Widget>>(widget: &W) {
    if let Some(settings) = gtk::Settings::default() {
        let widget_clone = widget.clone();
        let update_theme = move |settings: &gtk::Settings| {
            let prefers_dark = settings.is_gtk_application_prefer_dark_theme();
            if prefers_dark {
                widget_clone.add_css_class("atomos-dark");
                widget_clone.remove_css_class("atomos-light");
            } else {
                widget_clone.add_css_class("atomos-light");
                widget_clone.remove_css_class("atomos-dark");
            }
        };
        update_theme(&settings);
        settings.connect_gtk_application_prefer_dark_theme_notify(update_theme);
    }
}

fn init_lock_tracking(state: Rc<HandlerState>) {
    let conn = match gio::bus_get_sync(gio::BusType::Session, None::<&gio::Cancellable>) {
        Ok(c) => c,
        Err(e) => {
            event!("lock tracking: failed to get session bus: {e}");
            return;
        }
    };

    let initial_locked = match conn.call_sync(
        Some("org.gnome.ScreenSaver"),
        "/org/gnome/ScreenSaver",
        "org.gnome.ScreenSaver",
        "GetActive",
        None,
        None,
        gio::DBusCallFlags::NONE,
        1_000,
        None::<&gio::Cancellable>,
    ) {
        Ok(res) => {
            let val = res.child_value(0).get::<bool>().unwrap_or(false);
            event!("lock tracking: GetActive returned {val}");
            Some(val)
        }
        Err(e) => {
            event!("lock tracking: GetActive failed: {e}; assuming locked during startup/init");
            None
        }
    };

    let resolved_locked = initial_locked.unwrap_or(true);
    state.session_locked.set(resolved_locked);
    if resolved_locked {
        event!("lock tracking: started with locked state (or unresolved). Hiding handle surfaces.");
        state.set_handle_surfaces_visible(false);
    }

    if initial_locked.is_none() {
        let conn_clone = conn.clone();
        let ctl_clone = state.clone();
        let mut retry_count = 0;
        glib::timeout_add_seconds_local(1, move || {
            retry_count += 1;
            match conn_clone.call_sync(
                Some("org.gnome.ScreenSaver"),
                "/org/gnome/ScreenSaver",
                "org.gnome.ScreenSaver",
                "GetActive",
                None,
                None,
                gio::DBusCallFlags::NONE,
                1_000,
                None::<&gio::Cancellable>,
            ) {
                Ok(res) => {
                    let val = res.child_value(0).get::<bool>().unwrap_or(false);
                    event!("lock tracking retry: GetActive succeeded on retry {retry_count} returning {val}");
                    ctl_clone.session_locked.set(val);
                    if !val {
                        let count = *ctl_clone.toplevel_count.borrow();
                        ctl_clone.set_handle_surfaces_visible(should_show_handle(count));
                    } else {
                        ctl_clone.set_handle_surfaces_visible(false);
                    }
                    glib::ControlFlow::Break
                }
                Err(e) => {
                    if retry_count >= 15 {
                        event!("lock tracking retry: failed 15 times: {e}; giving up and assuming unlocked");
                        ctl_clone.session_locked.set(false);
                        let count = *ctl_clone.toplevel_count.borrow();
                        ctl_clone.set_handle_surfaces_visible(should_show_handle(count));
                        glib::ControlFlow::Break
                    } else {
                        glib::ControlFlow::Continue
                    }
                }
            }
        });
    }

    let ctl = state.clone();
    conn.signal_subscribe(
        Some("org.gnome.ScreenSaver"),
        Some("org.gnome.ScreenSaver"),
        Some("ActiveChanged"),
        Some("/org/gnome/ScreenSaver"),
        None,
        gio::DBusSignalFlags::NONE,
        move |_conn, _sender, _object_path, _interface, _signal, parameters| {
            let active = parameters.child_value(0).get::<bool>().unwrap_or(false);
            event!("lock tracking: ActiveChanged received active={active}");
            ctl.session_locked.set(active);
            if active {
                event!("lock tracking: screen locked; hiding handles");
                ctl.set_handle_surfaces_visible(false);
            } else {
                event!("lock tracking: screen unlocked");
                let count = *ctl.toplevel_count.borrow();
                ctl.set_handle_surfaces_visible(should_show_handle(count));
            }
        },
    );
    event!("lock tracking: successfully initialized");
}

