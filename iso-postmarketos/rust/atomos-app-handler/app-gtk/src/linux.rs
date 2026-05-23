//! Linux implementation of `atomos-app-handler`.
//!
//! Two `Layer::Overlay` layer-shell surfaces live in the same process:
//!
//!   - `handle_window` — a 24px bottom-edge strip used purely as a gesture
//!     capture region. It replaces the unix-socket round-trip the legacy
//!     `atomos-swipe-bridge` did to Phosh.
//!   - `switcher_window` — full-screen surface anchored to all four edges,
//!     hidden by default. Painted opaque `#0a0a0a` (the
//!     `BACKDROP_BASE_COLOR_HEX` constant in the core crate) so the running
//!     app behind us is fully occluded — the explicit visual requirement
//!     for v1 is that the switcher looks like the home-bg surface, not a
//!     still of the foreground app.
//!
//! All policy is composed in `atomos_app_handler::compose_runtime_config`;
//! this file just wires policy → live widgets. Lifecycle events are logged
//! with the `atomos-app-handler:` tag so the launcher's
//! `$XDG_RUNTIME_DIR/atomos-app-handler.log` reads as a step-by-step trace
//! of the gesture pipeline (the `diagnose-app-switcher.sh` script tails it).

use atomos_app_handler::{
    compose_runtime_config, derive_home_ipc, evaluate_swipe_up, gtk_argv_for_run_from_process_argv,
    launch::plan_launch, parse_lifecycle_action_from_argv, should_show_handle, EnvInputs,
    GestureConfig, LaunchPlan, LifecycleAction, OverlayState, PhoshHomeIpc, RuntimeConfig,
    SwipeOutcome, UiMode, BACKDROP_BASE_COLOR_HEX, LAYER_SHELL_NAMESPACE,
};
use gtk::gio;
use gtk::glib;
use gtk::prelude::*;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use std::cell::RefCell;
use std::rc::Rc;

mod backdrop;
mod cards;
mod handle;
mod launch_exec;
mod phosh_ipc;
mod wayland;

use cards::CardsController;
use wayland::WaylandClient;

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
    // --show / --hide / launch) via parse_lifecycle_action_from_argv.
    // Hand gtk only the program name; otherwise g_application_run's
    // option parser sees `--start` (or `--show`), errors with
    // `Unknown option --start`, and exits rc=1 — which is exactly what
    // the launcher log captured when the autostart bar was missing on
    // QEMU. `gtk_argv_for_run_from_process_argv` is the unit-tested
    // policy in the core crate.
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
                    phosh_ipc::apply_home_ipc(PhoshHomeIpc::SetFolded)
                        .map_err(|e| anyhow::anyhow!(e))?;
                    return Ok(());
                }
            }
        }
    }

    launch_exec::spawn_desktop_app(app_id).map_err(|e| anyhow::anyhow!(e))?;
    event!("launch: spawned new app id={app_id}");
    phosh_ipc::apply_home_ipc(PhoshHomeIpc::SetFolded).map_err(|e| anyhow::anyhow!(e))?;
    Ok(())
}

/// Shared state between the handle/switcher windows and the wayland thread.
///
/// Egui-parity contract: the GTK binary owns only the bottom-edge handle
/// strip and the full-screen switcher overlay (matching the egui preview
/// 1:1). The app launcher / app grid is owned exclusively by
/// `atomos-overview-chat-ui` — no GTK launcher window exists here.
pub(crate) struct OverlayController {
    pub(crate) state: RefCell<OverlayState>,
    pub(crate) gestures: GestureConfig,
    pub(crate) handle_drag_dy: RefCell<f64>,
    pub(crate) ui_mode: RefCell<UiMode>,
    pub(crate) toplevel_count: RefCell<usize>,
    pub(crate) switcher_window: RefCell<Option<gtk::ApplicationWindow>>,
    pub(crate) handle_window: RefCell<Option<gtk::ApplicationWindow>>,
    pub(crate) cards: RefCell<Option<CardsController>>,
}

impl OverlayController {
    pub(crate) fn new(gestures: GestureConfig) -> Self {
        Self {
            state: RefCell::new(OverlayState::Closed),
            gestures,
            handle_drag_dy: RefCell::new(0.0),
            ui_mode: RefCell::new(UiMode::Idle),
            toplevel_count: RefCell::new(0),
            switcher_window: RefCell::new(None),
            handle_window: RefCell::new(None),
            cards: RefCell::new(None),
        }
    }

    pub(crate) fn set_ui_mode(&self, mode: UiMode) {
        *self.ui_mode.borrow_mut() = mode;
    }

    pub(crate) fn on_toplevel_count_changed(&self, new_count: usize) {
        let prev = *self.toplevel_count.borrow();
        if prev == new_count {
            return;
        }
        *self.toplevel_count.borrow_mut() = new_count;

        // Egui-parity: handle bar maps only when at least one app is
        // open; on the home screen (count=0) atomos-overview-chat-ui is
        // the only visible UI.
        if let Some(win) = self.handle_window.borrow().as_ref() {
            let visible = should_show_handle(new_count);
            win.set_visible(visible);
            if visible {
                win.present();
            }
            event!(
                "handle_window visible={visible} (toplevel_count {prev} -> {new_count})"
            );
        }

        // If every app just closed, also tear the switcher overlay
        // down — there's nothing left to switch to and the cards row
        // would otherwise paint over the home screen.
        if new_count == 0 && self.is_open() {
            self.close();
        }

        let ipc = derive_home_ipc(prev, new_count, *self.ui_mode.borrow());
        event!("toplevel_count {prev} -> {new_count} home_ipc={ipc:?}");
        if let Err(err) = phosh_ipc::apply_home_ipc(ipc) {
            event!("phosh home ipc failed: {err}");
        }
    }

    pub(crate) fn open(&self) {
        let from = *self.state.borrow();
        *self.ui_mode.borrow_mut() = UiMode::SwitcherOpen;
        let next = from.try_transition(OverlayState::Opening { progress: 0.0 });
        if let Ok(s) = next {
            *self.state.borrow_mut() = s;
            // Skip the egui-style frame-by-frame animation on device; the
            // shell already cross-fades layer-shell surfaces. Snap to Open
            // after one tick so cards become interactive without a long
            // hand-rolled animation loop.
            if let Ok(open) = self
                .state
                .borrow()
                .try_transition(OverlayState::Open)
            {
                *self.state.borrow_mut() = open;
            }
            event!("overlay open from={from:?} to={:?}", *self.state.borrow());
            if let Some(win) = self.switcher_window.borrow().as_ref() {
                win.set_visible(true);
                win.present();
                event!("switcher_window present()");
            } else {
                event!("overlay open: switcher_window not yet built");
            }
        } else {
            event!("overlay open: rejected transition from={from:?}");
        }
    }

    pub(crate) fn close(&self) {
        let from = *self.state.borrow();
        if matches!(from, OverlayState::Closed) {
            return;
        }
        *self.ui_mode.borrow_mut() = UiMode::Idle;
        if let Ok(s) = from.try_transition(OverlayState::Closing { progress: 0.0 }) {
            *self.state.borrow_mut() = s;
        }
        if let Ok(closed) = self
            .state
            .borrow()
            .try_transition(OverlayState::Closed)
        {
            *self.state.borrow_mut() = closed;
        }
        event!("overlay close from={from:?} to={:?}", *self.state.borrow());
        if let Some(win) = self.switcher_window.borrow().as_ref() {
            win.set_visible(false);
        }
    }

    pub(crate) fn is_open(&self) -> bool {
        matches!(*self.state.borrow(), OverlayState::Open)
    }
}

fn build_ui(app: &gtk::Application, cfg: &RuntimeConfig, action: LifecycleAction) -> anyhow::Result<()> {
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

    backdrop::install_css(BACKDROP_BASE_COLOR_HEX);
    event!("backdrop CSS installed (base={BACKDROP_BASE_COLOR_HEX})");

    let controller = Rc::new(OverlayController::new(cfg.gestures));

    // The wayland client thread feeds the switcher window with the current
    // toplevel list. We start it before building the windows so the first
    // snapshot is ready by the time the user swipes up. If the connection
    // fails (no Wayland session, missing protocol), we still present the
    // surface — just with an empty card row. The switcher then reads as a
    // "no running apps" state rather than crashing.
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

    let switcher_window = build_switcher_window(app, controller.clone(), wayland.as_ref());
    *controller.switcher_window.borrow_mut() = Some(switcher_window);

    // Egui-parity: the bottom-edge handle is *not* mapped on the home
    // screen. It only appears when at least one Wayland toplevel exists
    // (i.e. an app is in the foreground). Visibility is gated by
    // `should_show_handle` from the wayland snapshot drain below; the
    // surface itself is built up-front so `set_visible(true)` later is
    // O(1).
    let handle_window = build_handle_window(app, controller.clone());
    handle_window.set_visible(false);
    *controller.handle_window.borrow_mut() = Some(handle_window);
    event!("handle_window built; hidden until first toplevel appears");

    if matches!(action, LifecycleAction::Show) {
        event!("cold --show: opening switcher overlay immediately");
        controller.open();
    }

    // POSIX show/hide bridge: the launcher script signals SIGUSR1=show,
    // SIGUSR2=hide on the pidfile-tracked process. The handlers run on
    // the GTK main thread, so calling controller.open() / .close()
    // straight from them is safe (no cross-thread state mutation).
    install_lifecycle_signal_handlers(controller.clone());

    // Drain wayland snapshots into the cards controller. We hold the
    // future on the application so it lives as long as the app.
    if let Some(client) = wayland {
        spawn_snapshot_drain(controller.clone(), client);
    }

    Ok(())
}

/// Map SIGUSR1 -> open overlay, SIGUSR2 -> close overlay. The launcher
/// script's `--show` / `--hide` actions send these signals to the
/// pidfile-tracked process so phosh's lifecycle hooks toggle the overlay
/// surface without restarting the handle-bar process.
fn install_lifecycle_signal_handlers(controller: Rc<OverlayController>) {
    let ctl_show = controller.clone();
    glib::unix_signal_add_local(libc::SIGUSR1 as i32, move || {
        event!("SIGUSR1 received; opening switcher overlay");
        ctl_show.open();
        glib::ControlFlow::Continue
    });
    let ctl_hide = controller;
    glib::unix_signal_add_local(libc::SIGUSR2 as i32, move || {
        event!("SIGUSR2 received; closing switcher overlay");
        ctl_hide.close();
        glib::ControlFlow::Continue
    });
    event!("installed SIGUSR1 (show) / SIGUSR2 (hide) lifecycle handlers");
}

fn build_handle_window(
    app: &gtk::Application,
    controller: Rc<OverlayController>,
) -> gtk::ApplicationWindow {
    let handle_height_px = controller.gestures.handle_height_px;
    let win = gtk::ApplicationWindow::builder()
        .application(app)
        .title("AtomOS App Switcher (handle)")
        .decorated(false)
        .resizable(false)
        .build();
    win.set_default_size(420, handle_height_px);
    win.set_size_request(-1, handle_height_px);
    win.set_can_focus(false);

    configure_layer_surface(&win, LayerSurfaceRole::Handle, handle_height_px);

    // The visible "strip" is a `gtk::DrawingArea`. An empty `gtk::Box` is not
    // guaranteed to be pickable by GTK4's hit-tester — it can be allocated
    // zero pickable area under layer-shell sizing in some compositor paths,
    // which silently drops every touch. DrawingArea is always pickable and
    // is what `atomos-home-bg` / `atomos-overview-chat-ui` use for their
    // input regions, so we follow suit.
    let strip = gtk::DrawingArea::new();
    strip.set_widget_name("atomos-app-handler-handle");
    strip.set_hexpand(true);
    strip.set_vexpand(true);
    strip.set_can_target(true);
    strip.set_focusable(false);
    // set_content_width(-1) hits a `width >= 0` g_assertion at runtime and the
    // strip then falls back to 0 width, which narrows the hit region just
    // enough that a real touch with any horizontal jitter misses the widget
    // entirely. 0 is the documented "no minimum" sentinel and pairs with
    // hexpand=true so the parent fills it horizontally.
    strip.set_content_width(0);
    strip.set_content_height(handle_height_px);

    let debug_tint = debug_tint_enabled();
    if debug_tint {
        event!("debug-tint enabled on handle strip");
    }
    handle::install_handle_paint(&strip, debug_tint);

    // GestureDrag fires `drag_update` on every motion event. We accumulate
    // the upward delta and call `evaluate_swipe_up` from the core crate so
    // the threshold policy is shared with the egui preview / unit tests.
    let drag = gtk::GestureDrag::new();
    // `button = 0` accepts any pointer button — and combined with
    // `touch_only = false` lets us also pick up touchscreen sequences (the
    // FP4 / QEMU mobile path). `Capture` phase guarantees this controller
    // sees touch events before any descendant widget could swallow them.
    drag.set_button(0);
    drag.set_touch_only(false);
    drag.set_propagation_phase(gtk::PropagationPhase::Capture);
    // `exclusive=true` together with `set_state(Claimed)` in drag_begin
    // below tells GTK that, once this gesture has accepted a sequence,
    // every subsequent motion event for that sequence is ours — even
    // when the pointer/touch leaves the strip's allocation. Without
    // this, GTK hit-tests every motion event against the widget tree
    // and the gesture is denied as soon as the cursor crosses the top
    // of the 24px strip (which happens after ~14px of upward motion in
    // QEMU mouse mode and produced the symptom seen in
    // diagnose-app-switcher.sh's launcher log: drag_end firing at
    // accumulated_dy ≈ -5..-7 px, well under the 48 px open threshold).
    drag.set_exclusive(true);

    let ctl_begin = controller.clone();
    drag.connect_drag_begin(move |gesture, sx, sy| {
        *ctl_begin.handle_drag_dy.borrow_mut() = 0.0;
        // Claim the sequence so subsequent motion events keep flowing to
        // this gesture even after the pointer leaves the visible 24px
        // strip — this is the primary fix for "drag works in egui
        // preview but not on device" reported via diagnose-app-switcher.sh.
        // set_state returns false if the sequence was already claimed or
        // denied by another gesture; either way we still log so the
        // launcher log shows whether the claim succeeded.
        let claimed = gesture.set_state(gtk::EventSequenceState::Claimed);
        event!("handle drag_begin sx={sx:.1} sy={sy:.1} claimed={claimed}");
    });

    let ctl_update = controller.clone();
    drag.connect_drag_update(move |_, ox, oy| {
        if ctl_update.is_open() {
            return;
        }
        *ctl_update.handle_drag_dy.borrow_mut() = oy;
        let outcome = evaluate_swipe_up(oy, &ctl_update.gestures);
        event!(
            "handle drag_update ox={ox:.1} oy={oy:.1} outcome={outcome:?} \
             threshold_px={}",
            ctl_update.gestures.open_threshold_px
        );
        if matches!(outcome, SwipeOutcome::OpenOverlay) {
            ctl_update.open();
        }
    });

    let ctl_end = controller.clone();
    drag.connect_drag_end(move |_, ox, oy| {
        let dy = *ctl_end.handle_drag_dy.borrow();
        *ctl_end.handle_drag_dy.borrow_mut() = 0.0;
        event!("handle drag_end ox={ox:.1} oy={oy:.1} accumulated_dy={dy:.1}");
    });

    strip.add_controller(drag);

    // Diagnostic catch-all: a `gtk::EventControllerLegacy` in Capture
    // phase that logs *every* input event reaching the strip BEFORE
    // GestureDrag has a chance to claim it. This is the single most
    // useful signal for distinguishing two device-side failure modes
    // that look identical from the user's perspective ("swipe up does
    // nothing"):
    //
    //   - If the user swipes and the launcher log shows zero
    //     `event_probe` lines, no input event ever reached the widget.
    //     The bug is in Phoc / wlr-layer-shell input routing — most
    //     commonly Phosh's bottom-edge-drag is still consuming the
    //     gesture before it can be delivered to our overlay surface.
    //   - If `event_probe` lines fire but `drag_begin` never does,
    //     events reach GTK but the GestureDrag is misconfigured (e.g.
    //     wrong button mask, propagation phase, hit-region).
    //
    // diagnose-app-handler.sh's "Gesture pipeline" section greps for
    // these probe lines and classifies the failure for the user.
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
    strip.add_controller(event_probe);

    // Strip allocation diagnostic: gtk4-layer-shell anchors L+R but
    // `set_default_size(420, 24)` was the original window hint; if
    // hexpand=true doesn't take effect under layer-shell sizing, the
    // strip stays 420 wide and any swipe past x=420 silently misses
    // the hit-test. Logging the realized allocation lets the diagnose
    // script flag a narrow strip without needing wayland-info on the
    // device.
    strip.connect_resize(|_, width, height| {
        event!("handle_strip resize width={width} height={height}");
    });

    // Egui-parity: the handle bar is *just* the strip — no "Apps"
    // button, no extra widgets. Chat-ui owns the launcher; this surface
    // exists solely as the swipe-up affordance back to the switcher.
    win.set_child(Some(&strip));

    // Window lifecycle hooks — these tell us whether the handle surface
    // is actually mapped onto the compositor. The map-time allocation
    // log catches the "wayland surface is full-width but GTK only
    // allocates the 420 default" sizing bug: if `map width=` is
    // narrower than the display, layer-shell anchors aren't taking
    // effect.
    win.connect_realize(|_| event!("handle_window realize"));
    win.connect_map(|w| {
        let alloc = w.allocation();
        event!(
            "handle_window map width={} height={}",
            alloc.width(),
            alloc.height()
        );
    });
    win.connect_unmap(|_| event!("handle_window unmap"));

    win
}

fn build_switcher_window(
    app: &gtk::Application,
    controller: Rc<OverlayController>,
    wayland: Option<&WaylandClient>,
) -> gtk::ApplicationWindow {
    let win = gtk::ApplicationWindow::builder()
        .application(app)
        .title("AtomOS App Switcher")
        .decorated(false)
        .resizable(false)
        .build();
    win.set_can_focus(true);

    configure_layer_surface(&win, LayerSurfaceRole::Switcher, controller.gestures.handle_height_px);

    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    root.add_css_class("atomos-app-handler-root");
    root.set_hexpand(true);
    root.set_vexpand(true);

    // Cards row sits in the vertical center; a top spacer + bottom spacer
    // keep it visually centered without committing to a fixed pixel height.
    let top_spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    top_spacer.set_vexpand(true);
    root.append(&top_spacer);

    let cards_controller = cards::CardsController::new(controller.clone(), wayland.cloned());
    let cards_row = cards_controller.widget();
    root.append(cards_row);
    *controller.cards.borrow_mut() = Some(cards_controller);

    let bottom_spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    bottom_spacer.set_vexpand(true);
    root.append(&bottom_spacer);

    // Tap outside the card row closes the switcher. Mounted in the bubble
    // phase so per-card click handlers take precedence.
    let dismiss = gtk::GestureClick::new();
    dismiss.set_button(0);
    dismiss.set_propagation_phase(gtk::PropagationPhase::Bubble);
    let ctl_for_dismiss = controller.clone();
    dismiss.connect_released(move |_, _, _x, _y| {
        if ctl_for_dismiss.is_open() {
            event!("switcher backdrop tap; closing overlay");
            ctl_for_dismiss.close();
        }
    });
    root.add_controller(dismiss);

    win.set_child(Some(&root));
    win.set_visible(false);

    win.connect_realize(|_| event!("switcher_window realize"));
    win.connect_map(|_| event!("switcher_window map"));
    win.connect_unmap(|_| event!("switcher_window unmap"));

    win
}

#[derive(Debug, Clone, Copy)]
enum LayerSurfaceRole {
    Handle,
    Switcher,
}

fn configure_layer_surface(
    win: &gtk::ApplicationWindow,
    role: LayerSurfaceRole,
    handle_height_px: i32,
) {
    win.init_layer_shell();
    let namespace = match role {
        LayerSurfaceRole::Handle => format!("{LAYER_SHELL_NAMESPACE}.handle"),
        LayerSurfaceRole::Switcher => LAYER_SHELL_NAMESPACE.to_string(),
    };
    win.set_namespace(Some(namespace.as_str()));
    win.set_layer(Layer::Overlay);

    match role {
        LayerSurfaceRole::Handle => {
            win.set_anchor(Edge::Left, true);
            win.set_anchor(Edge::Right, true);
            win.set_anchor(Edge::Bottom, true);
            win.set_anchor(Edge::Top, false);
            win.set_exclusive_zone(0);
            win.set_keyboard_mode(KeyboardMode::None);
            // The handle strip is opaque-by-default; clear its input
            // region so any tap *outside* the visible strip falls
            // through to whatever sits below. We leave the visible
            // strip itself fully interactive (gesture-drag wires its
            // events from inside the GTK widget tree).
            let _ = handle_height_px;
        }
        LayerSurfaceRole::Switcher => {
            win.set_anchor(Edge::Left, true);
            win.set_anchor(Edge::Right, true);
            win.set_anchor(Edge::Top, true);
            win.set_anchor(Edge::Bottom, true);
            win.set_exclusive_zone(-1);
            win.set_keyboard_mode(KeyboardMode::OnDemand);
            apply_opaque_compositor_hint(win);
        }
    }

    event!(
        "layer-shell configured role={role:?} namespace={namespace} layer=overlay \
         handle_height_px={handle_height_px}"
    );
}

/// The switcher surface is intentionally opaque — `set_opaque_region(NULL)`
/// (a `None` argument) tells the compositor every pixel is opaque so it can
/// skip blending and so the running app underneath is not visible. This
/// inverts the [translucent hint that overview-chat-ui uses](https://github.com/atomos/iso-postmarketos/blob/main/rust/atomos-overview-chat-ui/app-gtk/src/overlay.rs).
fn apply_opaque_compositor_hint(win: &gtk::ApplicationWindow) {
    let apply = |w: &gtk::ApplicationWindow| -> bool {
        let Some(surface) = w.surface() else {
            return false;
        };
        // `None` argument means "entire surface is opaque".
        surface.set_opaque_region(None);
        event!("switcher surface marked fully opaque");
        true
    };
    if apply(win) {
        return;
    }
    let w = win.clone();
    win.connect_map(move |_| {
        if !apply(&w) {
            event!("could not mark switcher surface opaque after map");
        }
    });
}

fn spawn_snapshot_drain(controller: Rc<OverlayController>, client: WaylandClient) {
    let rx = client.snapshots();
    glib::spawn_future_local(async move {
        while let Ok(snapshot) = rx.recv().await {
            event!("snapshot received len={}", snapshot.len());
            controller.on_toplevel_count_changed(snapshot.len());
            if let Some(cards) = controller.cards.borrow().as_ref() {
                cards.update_snapshot(snapshot);
            }
        }
        event!("snapshot drain loop ended (wayland channel closed)");
    });
}
