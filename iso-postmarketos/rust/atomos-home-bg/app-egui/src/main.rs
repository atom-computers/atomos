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

fn main() -> eframe::Result<()> {
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

struct CombinedPreviewApp {
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
        egui::CentralPanel::default()
            .frame(egui::Frame::NONE.fill(HOME_BG_BASE_COLOR).inner_margin(0.0))
            .show(ctx, |_ui| {});

        // ---- "Top layer": chat input strip overlay ----
        paint_chat_input_overlay(
            ctx,
            &mut self.chat_text,
            &mut self.last_submit,
        );
    }
}

fn paint_chat_input_overlay(
    ctx: &egui::Context,
    chat_text: &mut String,
    last_submit: &mut Option<String>,
) {
    let viewport_h = ctx.input(|i| {
        i.viewport()
            .inner_rect
            .map(|r| r.height())
            .unwrap_or(820.0)
    });
    let viewport_w = ctx.input(|i| {
        i.viewport()
            .inner_rect
            .map(|r| r.width())
            .unwrap_or(420.0)
    });
    let strip_h = chat_strip_height(viewport_h);

    egui::Area::new(egui::Id::new("atomos-overview-chat-ui-strip"))
        .anchor(egui::Align2::LEFT_BOTTOM, egui::vec2(0.0, 0.0))
        .order(egui::Order::Foreground)
        .interactable(true)
        .show(ctx, |ui| {
            egui::Frame::default()
                .fill(egui::Color32::from_rgba_premultiplied(14, 14, 14, 210))
                .inner_margin(egui::Margin::same(12))
                .stroke(egui::Stroke::new(
                    1.0,
                    egui::Color32::from_rgba_premultiplied(255, 255, 255, 40),
                ))
                .show(ui, |ui| {
                    ui.set_min_width(viewport_w);
                    ui.set_max_width(viewport_w);
                    ui.set_min_height(strip_h - 24.0);

                    ui.label(
                        egui::RichText::new("overview-chat-ui (layered on top)")
                            .color(egui::Color32::from_rgb(200, 200, 200))
                            .size(11.0),
                    );
                    ui.add_space(6.0);

                    let layout = layout_state_for_text(chat_text);
                    let rows = layout.visible_lines.clamp(1, MAX_LINES) as usize;
                    let desired_h = (rows as f32 * 22.0) + 16.0;

                    ui.horizontal(|ui| {
                        let max_w = (ui.available_width() - 90.0).max(200.0);
                        let response = ui.add_sized(
                            [max_w, desired_h],
                            egui::TextEdit::multiline(chat_text)
                                .hint_text("Message...")
                                .desired_rows(rows),
                        );
                        let send = ui.button("Send").clicked();

                        if response.has_focus() {
                            let enter = ui.input(|i| i.key_pressed(egui::Key::Enter));
                            let shift = ui.input(|i| i.modifiers.shift);
                            if enter {
                                if let EnterKeyAction::Submit(p) =
                                    enter_action(chat_text, shift)
                                {
                                    *last_submit = Some(p);
                                    chat_text.clear();
                                }
                            }
                        }
                        if send {
                            if let EnterKeyAction::Submit(p) = enter_action(chat_text, false) {
                                *last_submit = Some(p);
                                chat_text.clear();
                            }
                        }
                    });

                    if let Some(p) = last_submit.as_deref() {
                        ui.add_space(2.0);
                        ui.label(
                            egui::RichText::new(format!("Last submit: {p}"))
                                .color(egui::Color32::from_rgb(128, 224, 178))
                                .size(11.0),
                        );
                    }
                });
        });
}
