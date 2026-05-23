//! Source-level contract that pins the gesture diagnostic probes
//! `build_handle_window` must keep emitting in the launcher log so that
//! `diagnose-app-handler.sh` can classify *which* stage of the swipe-up
//! pipeline is failing on a given device.
//!
//! When the user reports "swipe up does nothing on device but the egui
//! preview works fine", the failure has to be in exactly one of:
//!
//!   1. Wayland routing — touch never reaches the layer-shell surface.
//!      Detect: `event_probe` log line never fires while user swipes.
//!   2. GTK gesture state — `drag_begin` never fires even though raw
//!      events do reach the widget.
//!   3. Sequence cancellation — `drag_begin` fires but `drag_update`
//!      stops after a few px of motion.
//!   4. Threshold not reached — `drag_update` fires but `accumulated_dy`
//!      at `drag_end` is below `open_threshold_px`.
//!
//! Without these probes the device-side launcher log only shows
//! `drag_begin` / `drag_update` / `drag_end`, and (1) is indistinguishable
//! from (2). These tests assert the probes survive future refactors.

const LINUX_RS: &str = include_str!("../../app-gtk/src/linux.rs");

#[test]
fn handle_window_logs_its_allocation_on_map_so_diagnose_can_check_full_width() {
    // gtk4-layer-shell anchors L+R on the handle but `set_default_size`
    // hints 420×24. If Phoc fails to override the window with the full
    // output width, GTK allocates the strip 420×24 and any swipe past
    // x=420 misses the hit-test. The map-time allocation log catches
    // this without needing wayland-info on device.
    assert!(
        LINUX_RS.contains("handle_window map width="),
        "build_handle_window must log the realized window allocation \
         on `connect_map` so diagnose-app-handler.sh can detect \
         layer-shell sizing bugs"
    );
}

#[test]
fn handle_strip_logs_its_resize_allocation_for_hit_region_diagnostics() {
    // If `set_content_width(0) + hexpand=true` doesn't actually expand
    // the DrawingArea to the parent's allocation under layer-shell, the
    // strip's hit region narrows and any touch with horizontal jitter
    // misses. The resize log captures the actual allocated width.
    assert!(
        LINUX_RS.contains("handle_strip resize"),
        "build_handle_window must log the strip allocation on \
         `connect_resize` so diagnose-app-handler.sh can detect a \
         narrow hit region"
    );
}

#[test]
fn handle_strip_has_event_probe_to_distinguish_wayland_from_gtk_failure() {
    // The raw-event probe (`gtk::EventControllerLegacy` in Capture
    // phase) is the only way to tell from the launcher log whether
    // touch events reach the widget tree at all. If a swipe produces
    // zero probe lines, the failure is in Phoc/layer-shell input
    // routing — not in our gesture wiring.
    assert!(
        LINUX_RS.contains("EventControllerLegacy"),
        "build_handle_window must register a gtk::EventControllerLegacy \
         on the strip to log every raw event reaching the widget — this \
         is what tells us whether Phoc is delivering touches to the \
         overlay layer-shell surface"
    );
    assert!(
        LINUX_RS.contains("event_probe"),
        "the EventControllerLegacy handler must emit a log line \
         containing `event_probe` so diagnose-app-handler.sh can grep \
         for it"
    );
}

#[test]
fn event_probe_runs_in_capture_phase_to_see_events_before_gestures() {
    // Capture phase guarantees the probe sees events before the
    // GestureDrag controller (which may claim and consume them). If
    // the probe were in Bubble phase, a successfully-claimed drag
    // would suppress the probe and we'd lose the smoking-gun signal.
    let body = LINUX_RS;
    let probe_pos = body
        .find("EventControllerLegacy")
        .expect("EventControllerLegacy must be present (asserted above)");
    let after_probe = &body[probe_pos..];
    // Look for set_propagation_phase(...Capture) within the next ~60
    // lines — far enough to cover the constructor + setup but tight
    // enough that we know it applies to *this* controller.
    let window: String = after_probe.lines().take(40).collect::<Vec<_>>().join("\n");
    assert!(
        window.contains("PropagationPhase::Capture"),
        "the EventControllerLegacy probe must use PropagationPhase::Capture \
         so it observes events before the GestureDrag claims them"
    );
}
