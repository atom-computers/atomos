//! Headless egui render test for the app-switcher dev preview.
//!
//! Drives one or more frames through a fresh `egui::Context` without
//! opening an eframe window, and asserts the visual contracts that matter:
//!
//!   1. The backdrop fill matches `BACKDROP_BASE_COLOR_RGB` (`#0a0a0a`) so
//!      the switcher reads as the home-bg surface rather than a still of
//!      the running app — this is the user-visible requirement.
//!   2. The card row layout actually produces non-empty rects with usable
//!      area (the same regression class home-bg hit with a zero-size
//!      chat-strip Area).
//!   3. The overlay state machine never skips the `Opening` / `Closing`
//!      animation phases, even when the preview drives it as fast as it
//!      can.
//!
//! These tests don't need a windowing system, so they run on the same
//! macOS hosts that exercise `cargo test -p atomos-app-handler` for the
//! core crate.

use atomos_app_handler::{handle, OverlayState, BACKDROP_BASE_COLOR_RGB};
use egui;

#[path = "../src/layout.rs"]
mod layout;

use layout::{bottom_handle_rect, lay_out_cards, overlay_progress};

fn backdrop_color() -> egui::Color32 {
    egui::Color32::from_rgb(
        BACKDROP_BASE_COLOR_RGB[0],
        BACKDROP_BASE_COLOR_RGB[1],
        BACKDROP_BASE_COLOR_RGB[2],
    )
}

fn render_one_frame(ctx: &egui::Context) {
    egui::CentralPanel::default()
        .frame(
            egui::Frame::NONE
                .fill(backdrop_color())
                .inner_margin(0.0),
        )
        .show(ctx, |_ui| {});
}

fn context_for(width: f32, height: f32) -> egui::Context {
    let ctx = egui::Context::default();
    let raw_input = egui::RawInput {
        screen_rect: Some(egui::Rect::from_min_size(
            egui::pos2(0.0, 0.0),
            egui::vec2(width, height),
        )),
        viewports: {
            let mut m = std::collections::HashMap::default();
            let mut info = egui::ViewportInfo::default();
            info.inner_rect = Some(egui::Rect::from_min_size(
                egui::pos2(0.0, 0.0),
                egui::vec2(width, height),
            ));
            m.insert(egui::ViewportId::ROOT, info);
            m
        },
        ..Default::default()
    };
    let _ = ctx.run(raw_input.clone(), render_one_frame);
    let _ = ctx.run(raw_input, render_one_frame);
    ctx
}

#[test]
fn backdrop_color_is_home_bg_base() {
    let ctx = context_for(420.0, 820.0);
    // We can't trivially inspect the rasterized pixels without a renderer,
    // but we can confirm the central panel painted by checking that the
    // background area was registered with a layer at the viewport center.
    // The stronger byte-for-byte contract is asserted via the constant
    // below, mirroring how the home-bg test pins HOME_BG_BASE_COLOR.
    let probe = egui::pos2(210.0, 410.0);
    let layer = ctx.layer_id_at(probe);
    assert!(
        layer.is_some(),
        "central panel must register a layer at the viewport center"
    );
    let c = backdrop_color();
    assert_eq!(c.r(), 0x0a);
    assert_eq!(c.g(), 0x0a);
    assert_eq!(c.b(), 0x0a);
}

#[test]
fn bottom_handle_rect_sits_at_bottom_edge_of_phone_viewport() {
    let r = bottom_handle_rect(420.0, 820.0, 24);
    let bottom = r.y + r.height;
    assert!(
        (bottom - 820.0).abs() < f32::EPSILON,
        "handle must reach the bottom edge; got bottom={bottom}"
    );
}

#[test]
fn handle_paint_layout_matches_core_contract() {
    let touch = bottom_handle_rect(420.0, 820.0, 24);
    let plan = handle::layout_handle_paint(touch.width as f64, touch.height as f64)
        .expect("handle strip must layout");
    assert_eq!(plan.pill.width, handle::PILL_WIDTH_PX);
    assert_eq!(plan.pill.height, handle::PILL_HEIGHT_PX);
    assert!(handle::STRIP_SCRIM.a > 0.0);
    assert!(handle::PILL_FILL.a > 0.0);
}

#[test]
fn card_layout_produces_nonempty_area_for_realistic_phone_viewport() {
    let rects = lay_out_cards(4, 420.0, 820.0, 1.0);
    assert_eq!(rects.len(), 4);
    let total_area: f32 = rects.iter().map(|r| r.width * r.height).sum();
    assert!(
        total_area > 5_000.0,
        "card row must claim meaningful area on a phone viewport; got total {total_area} px^2"
    );
    for r in &rects {
        assert!(r.width > 0.0 && r.height > 0.0);
    }
}

#[test]
fn overlay_progress_endpoints_are_clamped() {
    assert_eq!(overlay_progress(OverlayState::Closed), 0.0);
    assert_eq!(overlay_progress(OverlayState::Open), 1.0);
    assert_eq!(
        overlay_progress(OverlayState::Opening { progress: -0.5 }),
        0.0
    );
    assert_eq!(
        overlay_progress(OverlayState::Opening { progress: 2.0 }),
        1.0
    );
}

#[test]
fn animation_steps_never_skip_opening_or_closing() {
    // Mirror the preview's `advance_overlay_animation()` policy: each
    // tick must remain in (or graduate to) an adjacent state — never
    // jump from Closed straight to Open or from Open straight to Closed.
    let mut s = OverlayState::Closed;
    s = s
        .try_transition(OverlayState::Opening { progress: 0.0 })
        .expect("Closed -> Opening(0.0) is the only legal transition out of Closed");
    let mut steps = 0;
    while steps < 100 {
        match s {
            OverlayState::Opening { progress } => {
                let next = (progress + 0.15).min(1.0);
                s = if next >= 1.0 {
                    s.try_transition(OverlayState::Open).unwrap()
                } else {
                    s.try_transition(OverlayState::Opening { progress: next }).unwrap()
                };
            }
            OverlayState::Open => break,
            _ => unreachable!("unexpected state during opening: {s:?}"),
        }
        steps += 1;
    }
    assert_eq!(s, OverlayState::Open);

    s = s
        .try_transition(OverlayState::Closing { progress: 0.0 })
        .expect("Open -> Closing(0.0) is the only legal transition out of Open");
    steps = 0;
    while steps < 100 {
        match s {
            OverlayState::Closing { progress } => {
                let next = (progress + 0.15).min(1.0);
                s = if next >= 1.0 {
                    s.try_transition(OverlayState::Closed).unwrap()
                } else {
                    s.try_transition(OverlayState::Closing { progress: next })
                        .unwrap()
                };
            }
            OverlayState::Closed => break,
            _ => unreachable!("unexpected state during closing: {s:?}"),
        }
        steps += 1;
    }
    assert_eq!(s, OverlayState::Closed);
}
