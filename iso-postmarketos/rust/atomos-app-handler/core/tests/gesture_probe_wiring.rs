//! Source-level contract that pins the gesture diagnostic probes
//! `build_fade_window` must keep emitting in the launcher log so that
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
fn fade_window_logs_its_allocation_on_map_so_diagnose_can_check_full_width() {
    // gtk4-layer-shell anchors L+R+T+B on the gesture overlay. If Phoc
    // fails to override the window with the full output width, GTK
    // allocates a narrow strip and any swipe past x=width misses the
    // hit-test. The map-time allocation log catches this without needing
    // wayland-info on device.
    assert!(
        LINUX_RS.contains("fade_window map width="),
        "build_fade_window must log the realized window allocation \
         on `connect_map` so diagnose-app-handler.sh can detect \
         layer-shell sizing bugs"
    );
}

#[test]
fn handle_canvas_logs_its_resize_allocation_for_hit_region_diagnostics() {
    // If `set_content_width(0) + hexpand=true` doesn't actually expand
    // the DrawingArea to the parent's allocation under layer-shell,
    // the canvas's hit region narrows and any touch with horizontal
    // jitter misses. The resize log captures the actual allocated
    // width.
    //
    assert!(
        LINUX_RS.contains("gesture_root resize"),
        "build_fade_window must log the gesture root allocation on \
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
        "build_fade_window must register a gtk::EventControllerLegacy \
         on the gesture strip to log every raw event reaching the widget — \
         this is what tells us whether Phoc is delivering touches to the \
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
fn swipe_threshold_closes_foreground_app_not_opens_switcher_overlay() {
    // We now background/close the foreground app on swipe-up.
    let update_body = LINUX_RS
        .split("drag.connect_drag_update")
        .nth(1)
        .and_then(|tail| tail.split("drag.connect_drag_end").next())
        .unwrap_or("");
    assert!(
        update_body.contains("SwipeOutcome::OpenOverlay") && update_body.contains("handle.close()"),
        "connect_drag_update must call handle.close() when evaluate_swipe_up \
         returns OpenOverlay"
    );
    assert!(
        !update_body.contains("ctl_update.open()"),
        "connect_drag_update must not open the switcher overlay on swipe-up"
    );
}

#[test]
fn gesture_fade_layer_shell_anchors_top_for_full_screen_drag_survival() {
    // QEMU virtio pointer input breaks the implicit grab when the wayland
    // surface is only 24 px tall (GrabBroken at |dy|≈8). The gesture fade
    // overlay must be full-screen (anchors L+R+T+B) from map time.
    let fade_branch = LINUX_RS
        .split("Full-screen overlay so the wayland implicit pointer grab")
        .nth(1)
        .and_then(|tail| tail.split("LayerSurfaceRole::Switcher").next())
        .unwrap_or("");
    assert!(
        fade_branch.contains("set_anchor(Edge::Top, true)"),
        "configure_layer_surface(GestureFade) must anchor Top so the layer-shell \
         surface spans the full display before the first drag_update"
    );
    assert!(
        !fade_branch.contains("set_size_request"),
        "configure_layer_surface(GestureFade) must not hint a 24 px window height — \
         layer-shell anchors define the full-screen overlay size"
    );
}

#[test]
fn handle_strip_sits_on_overlay_layer_above_foreground_app_to_push_keyboard() {
    assert!(
        LINUX_RS.contains("LayerSurfaceRole::HandleStrip | LayerSurfaceRole::GestureFade | LayerSurfaceRole::Switcher => {"),
        "configure_layer_surface must map HandleStrip to Layer::Overlay so the \
         visible handle sits on the Overlay layer and virtual keyboards respect exclusive_zone"
    );
    let anchor_branch = LINUX_RS
        .split("Bottom strip on Layer::Overlay so the virtual keyboard")
        .nth(1)
        .and_then(|tail| tail.split("LayerSurfaceRole::GestureFade").next())
        .unwrap_or("");
    assert!(
        anchor_branch.contains("set_anchor(Edge::Top, false)"),
        "configure_layer_surface(HandleStrip) must not anchor Top — it is a \
         bottom strip, not a full-screen overlay"
    );
    assert!(
        anchor_branch.contains("set_exclusive_zone(handle_height_px)"),
        "configure_layer_surface(HandleStrip) must reserve bottom inset so \
         apps lay out above the handle"
    );
}

#[test]
fn fade_window_narrows_wayland_input_region_for_click_through() {
    assert!(
        LINUX_RS.contains("apply_bottom_strip_input_region"),
        "build_fade_window must narrow the Wayland input region to the \
         bottom handle strip so the transparent overlay is click-through \
         to the foreground app"
    );
    assert!(
        LINUX_RS.contains("apply_non_interactive_input_region"),
        "build_handle_strip_window must clear the handle strip input region \
         so visual chrome does not compete with fade_window for touches"
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

#[test]
fn input_region_expands_on_drag_begin_and_resets_on_drag_end() {
    assert!(
        LINUX_RS.contains("input_region::set_input_region_height"),
        "linux.rs must dynamically update input region height using set_input_region_height"
    );
    // Let's make sure it's inside drag.connect_drag_begin and drag.connect_drag_end
    let begin_body = LINUX_RS
        .split("drag.connect_drag_begin")
        .nth(1)
        .and_then(|tail| tail.split("drag.connect_drag_update").next())
        .unwrap_or("");
    assert!(
        begin_body.contains("input_region::set_input_region_height(win, alloc.height())"),
        "connect_drag_begin must expand the input region to full height"
    );

    let end_body = LINUX_RS
        .split("drag.connect_drag_end")
        .nth(1)
        .unwrap_or("");
    assert!(
        end_body.contains("input_region::set_input_region_height(win, ctl_end.gestures.handle_height_px)"),
        "connect_drag_end must restore the input region height to handle_height_px"
    );
}

#[test]
fn handle_window_fades_out_on_drag_update_and_restores_on_drag_end() {
    let update_body = LINUX_RS
        .split("drag.connect_drag_update")
        .nth(1)
        .and_then(|tail| tail.split("drag.connect_drag_end").next())
        .unwrap_or("");
    assert!(
        update_body.contains("win.set_opacity((1.0 - progress) as f64)"),
        "connect_drag_update must dynamically set handle_window opacity using progress"
    );

    let end_body = LINUX_RS
        .split("drag.connect_drag_end")
        .nth(1)
        .unwrap_or("");
    assert!(
        end_body.contains("win.set_opacity(1.0)"),
        "connect_drag_end must restore handle_window opacity to 1.0"
    );
}

#[test]
fn handle_strip_clears_input_region_on_canvas_resize() {
    assert!(
        LINUX_RS.contains("input_region::apply_non_interactive_input_region(&win, &handle_canvas)"),
        "build_handle_strip_window must pass &handle_canvas to apply_non_interactive_input_region \
         to continuously clear the input region on resize, preventing GTK4 from making it interactive"
    );
}

#[test]
fn verify_full_gesture_sequence_flow_and_fade_out() {
    // 1. Verify click down (drag_begin) validates bottom boundary
    let begin_body = LINUX_RS
        .split("drag.connect_drag_begin")
        .nth(1)
        .and_then(|tail| tail.split("drag.connect_drag_update").next())
        .expect("Must connect drag_begin");

    assert!(
        begin_body.contains("sy < bottom_y"),
        "drag_begin must reject coordinates above the bottom handle strip"
    );
    assert!(
        begin_body.contains("set_state(gtk::EventSequenceState::Denied)"),
        "drag_begin must deny events starting outside the bottom zone"
    );
    assert!(
        begin_body.contains("set_state(gtk::EventSequenceState::Claimed)"),
        "drag_begin must claim events starting inside the bottom zone"
    );
    assert!(
        begin_body.contains("set_input_region_height"),
        "drag_begin must expand the wayland input region to full height"
    );

    // 2. Verify drag up (drag_update) updates progress, fades bottom bar, and triggers open
    let update_body = LINUX_RS
        .split("drag.connect_drag_update")
        .nth(1)
        .and_then(|tail| tail.split("drag.connect_drag_end").next())
        .expect("Must connect drag_update");

    assert!(
        update_body.contains("handle_drag_progress"),
        "drag_update must compute handle drag progress dynamically"
    );
    assert!(
        update_body.contains("win.set_opacity"),
        "drag_update must fade out the bottom bar (handle_window) during upward swipe"
    );
    assert!(
        update_body.contains("evaluate_swipe_up"),
        "drag_update must evaluate the swipe dy to check if the threshold is met"
    );
    assert!(
        update_body.contains("handle.close()"),
        "drag_update must call handle.close() to background the active application when threshold is met"
    );

    // 3. Verify drag end / cancellation restores handle state and input region
    let end_body = LINUX_RS
        .split("drag.connect_drag_end")
        .nth(1)
        .expect("Must connect drag_end");

    assert!(
        end_body.contains("set_input_region_height"),
        "drag_end must restore the narrow bottom strip input region"
    );
    assert!(
        end_body.contains("win.set_opacity(1.0)"),
        "drag_end must restore the bottom bar's full opacity"
    );
}

#[test]
fn swipe_threshold_falls_back_to_first_window_when_none_activated() {
    // Assert that the drag_update handler includes the fallback to snapshot.first()
    // if no active window is found. This protects against on-device gesture failures
    // when Phoc/the compositor does not advertise the activated state.
    let update_body = LINUX_RS
        .split("drag.connect_drag_update")
        .nth(1)
        .and_then(|tail| tail.split("drag.connect_drag_end").next())
        .unwrap_or("");
    
    assert!(
        update_body.contains("snapshot.first()"),
        "drag_update must fall back to snapshot.first() if no window in the snapshot has entry.activated"
    );
    assert!(
        update_body.contains("fallback backgrounding application"),
        "drag_update must log fallback backgrounding action when closing first available window"
    );
}



