#![allow(deprecated, dead_code)]
//! Combined egui dev preview.
//!
//! Single eframe window that stacks:
//! 1. `atomos-home-bg` content — drawn here as an opaque `#0a0a0a`
//!    fill. On a real Phosh device this surface is a WebKitGTK webview
//!    running the WebGL event-horizon shader (`event-horizon.js`); we
//!    can't run that shader inside eframe, so we paint just the dark
//!    base color the HTML places under the canvas. That keeps the
//!    layering / interactivity contract honest even though the
//!    decorative animation is missing in the dev preview.
//! 2. `atomos-overview-chat-ui` chat input — rendered on top, using the
//!    real `enter_action` / `layout_state_for_text` helpers from the
//!    overview-chat-ui core crate so input behavior stays faithful.
//!
//! Visual parity with what a phosh device would composite with
//! wlr-layer-shell. Not shipped to the rootfs; invoked from
//! `scripts/home-bg/preview-home-bg-and-overview-chat-ui.sh` in
//! egui-fallback mode.

mod overlay;

use atomos_overview_chat_ui::{enter_action, layout_state_for_text, EnterKeyAction, MAX_LINES};
use eframe::egui;
use overlay::chat_strip_height;

/// `#0a0a0a` — same hex the React component uses for the background
/// container (`bg-[#0a0a0a]`) and the same hex the HTML CSS sets on
/// `<body>`. Centralized so the egui preview, the headless test, and
/// any future consumers match by symbol rather than by re-typing the
/// number.
pub const HOME_BG_BASE_COLOR: egui::Color32 = egui::Color32::from_rgb(0x0a, 0x0a, 0x0a);

fn dummy_main() -> eframe::Result<()> {
    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("AtomOS home-bg + overview-chat-ui (combined preview)")
            .with_inner_size([420.0, 820.0]),
        ..Default::default()
    };

    eframe::run_native(
        "AtomOS home-bg combined preview",
        native_options,
        Box::new(|_cc| Ok(Box::<CombinedPreviewApp>::default())),
    )
}

pub struct CombinedPreviewApp {
    chat_text: String,
    last_submit: Option<String>,
}

impl Default for CombinedPreviewApp {
    fn default() -> Self {
        Self {
            chat_text: String::new(),
            last_submit: None,
        }
    }
}

impl eframe::App for CombinedPreviewApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // ---- "Background layer": opaque #0a0a0a base ----
        // The shipped surface paints a WebGL event-horizon shader on top
        // of this base color; egui can't run that shader, so we render
        // the base color alone.
        egui::Area::new(egui::Id::new("home_bg_area")).order(egui::Order::Background).show(ctx, |ui| {
            egui::Frame::NONE.fill(HOME_BG_BASE_COLOR).inner_margin(0.0).show(ui, |_ui| {
                let rect = ctx.screen_rect();
                _ui.set_min_size(rect.size());
                
                // MOCK ANIMATION: slowly moving grid to simulate the WebGL background
                let time = ctx.input(|i| i.time) as f32;
                let painter = _ui.painter();
                let grid_size = 40.0;
                let offset = (time * 15.0) % grid_size;
                
                // Draw vertical lines
                let mut x = offset;
                while x < rect.width() {
                    painter.line_segment(
                        [egui::pos2(x, 0.0), egui::pos2(x, rect.height())],
                        egui::Stroke::new(1.0, egui::Color32::from_white_alpha(15)),
                    );
                    x += grid_size;
                }
                
                // Draw horizontal lines
                let mut y = offset;
                while y < rect.height() {
                    painter.line_segment(
                        [egui::pos2(0.0, y), egui::pos2(rect.width(), y)],
                        egui::Stroke::new(1.0, egui::Color32::from_white_alpha(15)),
                    );
                    y += grid_size;
                }
                
                ctx.request_repaint(); // Keep animation playing
            });
        });

    }
}
