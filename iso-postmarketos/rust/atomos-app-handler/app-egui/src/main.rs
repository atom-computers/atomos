//! Combined egui dev preview for `atomos-app-handler`.
//!
//! Renders a phone-sized eframe window that mirrors the real device layout:
//!
//! 1. Background — opaque `#0a0a0a` surface. On a Phosh device the GTK
//!    binary self-paints the same color as a layer-shell `Overlay` surface
//!    so the running app behind us is fully occluded. The dev preview gets
//!    the same visual contract.
//! 2. Bottom-edge visible handle (`DEFAULT_HANDLE_HEIGHT_PX`). Dragging
//!    upward past `OPEN_THRESHOLD_PX` closes the foreground mock app via
//!    `evaluate_swipe_up`.
//!
//! Not shipped in the rootfs.

mod layout;

use atomos_app_handler::{
    evaluate_swipe_up, handle, GestureConfig, SwipeOutcome, ToplevelEntry,
};
use egui;
use layout::bottom_handle_rect;

const VIEWPORT_W: f32 = 420.0;
const VIEWPORT_H: f32 = 820.0;

const BACKDROP_RGB: [u8; 3] = [0x0a, 0x0a, 0x0a];

fn backdrop_color() -> egui::Color32 {
    egui::Color32::from_rgb(BACKDROP_RGB[0], BACKDROP_RGB[1], BACKDROP_RGB[2])
}

fn main() -> eframe::Result<()> {
    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("AtomOS app-handler (dev preview)")
            .with_inner_size([VIEWPORT_W, VIEWPORT_H]),
        ..Default::default()
    };

    eframe::run_native(
        "AtomOS app-handler dev preview",
        native_options,
        Box::new(|_cc| Ok(Box::<PreviewApp>::default())),
    )
}

struct PreviewApp {
    toplevels: Vec<ToplevelEntry>,
    gestures: GestureConfig,
    last_activated: Option<u32>,
    /// Bottom-edge handle live drag (in px, negative = up).
    handle_drag_dy: f32,
}

impl Default for PreviewApp {
    fn default() -> Self {
        Self {
            toplevels: mock_toplevels(),
            gestures: GestureConfig::default(),
            last_activated: None,
            handle_drag_dy: 0.0,
        }
    }
}

fn mock_toplevels() -> Vec<ToplevelEntry> {
    vec![
        ToplevelEntry {
            id: 1,
            app_id: "org.mozilla.firefox".into(),
            title: "AtomOS — Cursor".into(),
            activated: true,
        },
        ToplevelEntry {
            id: 2,
            app_id: "org.gnome.Terminal".into(),
            title: "george@phone:~".into(),
            activated: false,
        },
        ToplevelEntry {
            id: 3,
            app_id: "org.gnome.Maps".into(),
            title: "Maps".into(),
            activated: false,
        },
        ToplevelEntry {
            id: 4,
            app_id: "sm.puri.Chatty".into(),
            title: "Chatty".into(),
            activated: false,
        },
    ]
}

impl eframe::App for PreviewApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        egui::CentralPanel::default()
            .frame(egui::Frame::NONE.fill(backdrop_color()).inner_margin(0.0))
            .show(ctx, |ui| {
                let viewport = ui.available_rect_before_wrap();
                let viewport_w = viewport.width();
                let viewport_h = viewport.height();

                self.paint_dim_hint(ui, viewport);
                self.paint_bottom_handle(ctx, ui, viewport_w, viewport_h);
            });
    }
}

impl PreviewApp {
    fn paint_dim_hint(&self, ui: &mut egui::Ui, viewport: egui::Rect) {
        let painter = ui.painter_at(viewport);
        let center = viewport.center();
        painter.text(
            egui::pos2(center.x, center.y - 16.0),
            egui::Align2::CENTER_CENTER,
            "Swipe up from the bottom edge to close the foreground app",
            egui::FontId::proportional(13.0),
            egui::Color32::from_rgb(120, 120, 120),
        );
        if let Some(id) = self.last_activated {
            if let Some(t) = self.toplevels.iter().find(|t| t.id == id) {
                painter.text(
                    egui::pos2(center.x, center.y + 8.0),
                    egui::Align2::CENTER_CENTER,
                    format!("Last activated: {}", t.display_label()),
                    egui::FontId::proportional(12.0),
                    egui::Color32::from_rgb(128, 224, 178),
                );
            }
        }
    }

    fn paint_bottom_handle(
        &mut self,
        ctx: &egui::Context,
        ui: &mut egui::Ui,
        viewport_w: f32,
        viewport_h: f32,
    ) {
        let r = bottom_handle_rect(viewport_w, viewport_h, self.gestures.handle_height_px);
        let rect = egui::Rect::from_min_size(
            egui::pos2(r.x, r.y),
            egui::vec2(r.width, r.height),
        );
        let id = egui::Id::new("app-handler-bottom-handle");
        let response = ui.interact(rect, id, egui::Sense::click_and_drag());

        let painter = ui.painter_at(rect);
        if let Some(plan) =
            handle::layout_handle_paint(rect.width() as f64, rect.height() as f64)
        {
            let scrim = handle::STRIP_SCRIM.to_premultiplied_u8();
            painter.rect_filled(
                rect,
                0.0,
                egui::Color32::from_rgba_premultiplied(
                    scrim[0], scrim[1], scrim[2], scrim[3],
                ),
            );
            let pill_rect = egui::Rect::from_min_size(
                egui::pos2(plan.pill.x as f32, plan.pill.y as f32),
                egui::vec2(plan.pill.width as f32, plan.pill.height as f32),
            );
            let pill = handle::PILL_FILL.to_premultiplied_u8();
            painter.rect_filled(
                pill_rect,
                (plan.pill.height / 2.0) as f32,
                egui::Color32::from_rgba_premultiplied(pill[0], pill[1], pill[2], pill[3]),
            );
        }

        if response.drag_started() {
            self.handle_drag_dy = 0.0;
        }
        if response.dragged() {
            self.handle_drag_dy += response.drag_delta().y;
            if matches!(
                evaluate_swipe_up(self.handle_drag_dy as f64, &self.gestures),
                SwipeOutcome::CloseApp
            ) {
                if let Some(last) = self.toplevels.pop() {
                    self.last_activated = Some(last.id);
                }
                self.handle_drag_dy = 0.0;
                ctx.request_repaint();
            }
        }
        if response.drag_stopped() {
            self.handle_drag_dy = 0.0;
        }

        if self.toplevels.is_empty() {
            let banner_rect = egui::Rect::from_min_size(
                egui::pos2(8.0, 8.0),
                egui::vec2(viewport_w - 16.0, 28.0),
            );
            ui.scope_builder(
                egui::UiBuilder::new().max_rect(banner_rect),
                |ui| {
                    ui.horizontal(|ui| {
                        ui.label(
                            egui::RichText::new("No mock toplevels left")
                                .color(egui::Color32::LIGHT_GRAY),
                        );
                        if ui.button("Reset").clicked() {
                            self.toplevels = mock_toplevels();
                            ctx.request_repaint();
                        }
                    });
                },
            );
        }
    }
}
