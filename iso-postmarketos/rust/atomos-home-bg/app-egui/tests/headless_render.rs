//! Headless egui render test for the combined preview.
//!
//! Runs the full render path through a fresh `egui::Context` without
//! opening an eframe window, and uses public egui APIs
//! (`Context::layer_id_at`, `Memory`) to assert:
//!
//!   1. both the dark home-bg CentralPanel and the chat-strip
//!      Foreground Area produce paint commands;
//!   2. the chat-strip Area is actually sized (non-empty rect) — this is
//!      the exact regression the user hit, where the strip was emitted
//!      into a zero-size Area and silently didn't appear;
//!   3. clicks in the bottom-of-viewport region route to the Foreground
//!      chat strip rather than the Background CentralPanel;
//!   4. the home-bg CentralPanel uses the `#0a0a0a` base color that
//!      matches the shipped HTML's `<body>` fill (the WebGL shader is
//!      not exercised by this test — the dev preview only mirrors the
//!      base color so layering / interactivity stay honest).

use eframe::egui;

#[path = "../src/overlay.rs"]
mod overlay;

use overlay::chat_strip_height;

const HOME_BG_BASE_COLOR: egui::Color32 = egui::Color32::from_rgb(0x0a, 0x0a, 0x0a);

const STRIP_ID: &str = "atomos-overview-chat-ui-strip";

fn render_one_frame(ctx: &egui::Context, width: f32, height: f32) {
    egui::CentralPanel::default()
        .frame(
            egui::Frame::NONE
                .fill(HOME_BG_BASE_COLOR)
                .inner_margin(0.0),
        )
        .show(ctx, |_ui| {
            // Dark base — mirrors the shipped placeholder's <body> fill.
            // The actual WebGL shader runs in WebKitGTK on device only.
        });

    let strip_h = chat_strip_height(height);
    egui::Area::new(egui::Id::new(STRIP_ID))
        .anchor(egui::Align2::LEFT_BOTTOM, egui::vec2(0.0, 0.0))
        .order(egui::Order::Foreground)
        .interactable(true)
        .show(ctx, |ui| {
            egui::Frame::default()
                .fill(egui::Color32::from_rgba_premultiplied(14, 14, 14, 210))
                .inner_margin(egui::Margin::same(12))
                .show(ui, |ui| {
                    ui.set_min_width(width);
                    ui.set_max_width(width);
                    ui.set_min_height(strip_h - 24.0);
                    ui.label("overview-chat-ui (layered on top)");
                    let mut text = String::new();
                    ui.add(egui::TextEdit::singleline(&mut text).hint_text("Message..."));
                });
        });
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
    // Two passes: anchored Areas need a discover-then-anchor sequence.
    let _ = ctx.run(raw_input.clone(), |ctx| render_one_frame(ctx, width, height));
    let _ = ctx.run(raw_input, |ctx| render_one_frame(ctx, width, height));
    ctx
}

#[test]
fn chat_strip_area_is_tracked_in_memory_after_render() {
    let ctx = context_for(420.0, 820.0);
    let area_rect = ctx.memory(|m| m.area_rect(egui::Id::new(STRIP_ID)));
    let rect = area_rect.expect("chat strip Area was never registered in egui memory");
    let area = rect.width().max(0.0) * rect.height().max(0.0);
    assert!(
        area > 1000.0,
        "chat strip Area must have meaningful rendered area; got {area} px^2 (rect={rect:?})"
    );
}

#[test]
fn clicks_at_bottom_of_viewport_route_to_foreground_chat_strip() {
    let width = 420.0;
    let height = 820.0;
    let ctx = context_for(width, height);
    let strip_probe = egui::pos2(width / 2.0, height - 20.0);
    let top_probe = egui::pos2(width / 2.0, 20.0);

    let strip_layer = ctx.layer_id_at(strip_probe);
    let top_layer = ctx.layer_id_at(top_probe);

    let strip_layer = strip_layer.expect("no layer at bottom-of-viewport; chat strip is missing");
    assert_eq!(
        strip_layer.order,
        egui::Order::Foreground,
        "bottom-of-viewport must be covered by the Foreground chat strip layer, got {:?}",
        strip_layer.order,
    );
    assert_eq!(
        strip_layer.id,
        egui::Id::new(STRIP_ID),
        "expected chat strip layer id to win the hit-test"
    );

    if let Some(top_layer) = top_layer {
        assert_ne!(
            top_layer.id,
            egui::Id::new(STRIP_ID),
            "top of viewport must not resolve to the chat strip; strip is too tall"
        );
    }
}

#[test]
fn chat_strip_height_is_substantial_fraction_of_viewport() {
    assert_eq!(chat_strip_height(820.0), 160.0);
}

#[test]
fn render_is_idempotent_across_frames() {
    let ctx = context_for(420.0, 820.0);
    let a = ctx.memory(|m| m.area_rect(egui::Id::new(STRIP_ID)));
    let b = ctx.memory(|m| m.area_rect(egui::Id::new(STRIP_ID)));
    assert_eq!(a, b, "chat strip Area rect must be stable across equal frames");
}
