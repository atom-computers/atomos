//! Combined egui dev preview.
//!
//! Single eframe window that stacks:
//! 1. `atomos-home-bg` content (white background + bouncing ball + HUD) —
//!    drawn edge-to-edge as the "background layer".
//! 2. `atomos-overview-chat-ui` chat input — rendered on top, using the
//!    real `enter_action` / `layout_state_for_text` helpers from the
//!    overview-chat-ui core crate so input behavior stays faithful.
//!
//! Visual parity with what a phosh device would composite with
//! wlr-layer-shell. Not shipped to the rootfs; invoked from
//! `scripts/home-bg/preview-home-bg-and-overview-chat-ui.sh` in
//! egui-fallback mode.

mod ball;
mod overlay;

use atomos_overview_chat_ui::{enter_action, layout_state_for_text, EnterKeyAction, MAX_LINES};
use ball::{step, BallState};
use eframe::egui;
use overlay::chat_strip_height;

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
    ball: BallState,
    last_frame_instant: Option<std::time::Instant>,
    frame_count: u64,
    fps_ema: f32,
    chat_text: String,
    last_submit: Option<String>,
}

impl Default for CombinedPreviewApp {
    fn default() -> Self {
        Self {
            ball: BallState::initial(),
            last_frame_instant: None,
            frame_count: 0,
            fps_ema: 0.0,
            chat_text: String::new(),
            last_submit: None,
        }
    }
}

impl eframe::App for CombinedPreviewApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        ctx.request_repaint();

        let now = std::time::Instant::now();
        let dt = self
            .last_frame_instant
            .map(|t| (now - t).as_secs_f32())
            .unwrap_or(0.0);
        self.last_frame_instant = Some(now);
        self.frame_count = self.frame_count.wrapping_add(1);
        if dt > 0.0 {
            let inst = 1.0 / dt;
            self.fps_ema = if self.fps_ema > 0.0 {
                self.fps_ema * 0.92 + inst * 0.08
            } else {
                inst
            };
        }

        let viewport = ctx.input(|i| {
            i.viewport()
                .inner_rect
                .unwrap_or(egui::Rect::from_min_size(
                    egui::pos2(0.0, 0.0),
                    egui::vec2(420.0, 820.0),
                ))
        });
        let w = viewport.width();
        let h = viewport.height();
        self.ball = step(self.ball, dt, w, h);

        // ---- "Background layer": full-white canvas + ball + HUD ----
        egui::CentralPanel::default()
            .frame(egui::Frame::NONE.fill(egui::Color32::WHITE).inner_margin(0.0))
            .show(ctx, |ui| {
                paint_home_bg_layer(ui, self.ball, self.frame_count, self.fps_ema);
            });

        // ---- "Top layer": chat input strip overlay ----
        paint_chat_input_overlay(
            ctx,
            &mut self.chat_text,
            &mut self.last_submit,
        );
    }
}

fn paint_home_bg_layer(ui: &mut egui::Ui, ball: BallState, frame_count: u64, fps_ema: f32) {
    let rect = ui.max_rect();
    let painter = ui.painter();

    let crosshair = egui::Stroke::new(
        1.0,
        egui::Color32::from_black_alpha((0.08 * 255.0) as u8),
    );
    painter.line_segment(
        [
            egui::pos2(rect.center().x, rect.top()),
            egui::pos2(rect.center().x, rect.bottom()),
        ],
        crosshair,
    );
    painter.line_segment(
        [
            egui::pos2(rect.left(), rect.center().y),
            egui::pos2(rect.right(), rect.center().y),
        ],
        crosshair,
    );

    let (outer_color, highlight_color) = hsl_to_rgb_pair(ball.hue, 0.85);
    painter.circle_filled(
        egui::pos2(rect.min.x + ball.x, rect.min.y + ball.y),
        ball.r,
        outer_color,
    );
    painter.circle_filled(
        egui::pos2(
            rect.min.x + ball.x - ball.r * 0.3,
            rect.min.y + ball.y - ball.r * 0.3,
        ),
        ball.r * 0.45,
        highlight_color,
    );

    let hud_text = format!(
        "atomos-home-bg preview test (egui)\nframe: {frame_count}  fps: {:.1}",
        fps_ema
    );
    let hud_rect = egui::Rect::from_min_size(
        rect.min + egui::vec2(12.0, 12.0),
        egui::vec2(260.0, 38.0),
    );
    painter.rect_filled(
        hud_rect,
        6.0,
        egui::Color32::from_rgba_premultiplied(255, 255, 255, 220),
    );
    painter.text(
        hud_rect.min + egui::vec2(10.0, 4.0),
        egui::Align2::LEFT_TOP,
        hud_text,
        egui::FontId::monospace(12.0),
        egui::Color32::from_rgb(0x33, 0x33, 0x33),
    );
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

fn hsl_to_rgb_pair(hue_deg: f32, saturation: f32) -> (egui::Color32, egui::Color32) {
    let body = hsl_to_rgb(hue_deg, saturation, 0.42);
    let highlight = hsl_to_rgb(hue_deg, saturation, 0.70);
    (body, highlight)
}

fn hsl_to_rgb(h_deg: f32, s: f32, l: f32) -> egui::Color32 {
    let h = h_deg.rem_euclid(360.0) / 360.0;
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let h6 = h * 6.0;
    let x = c * (1.0 - ((h6 % 2.0) - 1.0).abs());
    let (r1, g1, b1) = match h6 as i32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = l - c / 2.0;
    let to_u8 = |v: f32| ((v + m).clamp(0.0, 1.0) * 255.0).round() as u8;
    egui::Color32::from_rgb(to_u8(r1), to_u8(g1), to_u8(b1))
}

#[cfg(test)]
mod color_tests {
    use super::hsl_to_rgb;

    #[test]
    fn hsl_pure_red() {
        let c = hsl_to_rgb(0.0, 1.0, 0.5);
        assert_eq!(c.r(), 255);
        assert_eq!(c.g(), 0);
        assert_eq!(c.b(), 0);
    }

    #[test]
    fn hsl_pure_green() {
        let c = hsl_to_rgb(120.0, 1.0, 0.5);
        assert_eq!(c.r(), 0);
        assert_eq!(c.g(), 255);
        assert_eq!(c.b(), 0);
    }

    #[test]
    fn hsl_white_at_full_lightness() {
        let c = hsl_to_rgb(200.0, 0.85, 1.0);
        assert_eq!(c.r(), 255);
        assert_eq!(c.g(), 255);
        assert_eq!(c.b(), 255);
    }

    #[test]
    fn hsl_black_at_zero_lightness() {
        let c = hsl_to_rgb(200.0, 0.85, 0.0);
        assert_eq!(c.r(), 0);
        assert_eq!(c.g(), 0);
        assert_eq!(c.b(), 0);
    }

    #[test]
    fn hsl_wraps_hue_modulo_360() {
        let a = hsl_to_rgb(0.0, 1.0, 0.5);
        let b = hsl_to_rgb(360.0, 1.0, 0.5);
        assert_eq!(a, b);
        let c = hsl_to_rgb(-120.0, 1.0, 0.5);
        let d = hsl_to_rgb(240.0, 1.0, 0.5);
        assert_eq!(c, d);
    }
}
