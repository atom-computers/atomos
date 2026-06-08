//! Headless egui render test for the app-handler dev preview.
//!
//! Drives one or more frames through a fresh `egui::Context` without
//! opening an eframe window, and asserts the visual contracts that matter:
//!
//!   1. The backdrop fill matches `#0a0a0a` so the handle surface reads
//!      as the home-bg surface rather than a still of the running app.
//!   2. The bottom handle rect sits at the bottom edge of a phone viewport.
//!   3. The handle paint layout matches the core crate contract.
//!
//! These tests don't need a windowing system, so they run on the same
//! macOS hosts that exercise `cargo test -p atomos-app-handler` for the
//! core crate.

use atomos_app_handler::handle;
use egui;

#[path = "../src/layout.rs"]
mod layout;

use layout::bottom_handle_rect;

const BACKDROP_RGB: [u8; 3] = [0x0a, 0x0a, 0x0a];

fn backdrop_color() -> egui::Color32 {
    egui::Color32::from_rgb(BACKDROP_RGB[0], BACKDROP_RGB[1], BACKDROP_RGB[2])
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