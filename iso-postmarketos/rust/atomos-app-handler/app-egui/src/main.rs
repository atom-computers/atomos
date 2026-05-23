//! Combined egui dev preview for `atomos-app-handler`.
//!
//! Renders a phone-sized eframe window that mirrors the real device layout:
//!
//! 1. Background — opaque `#0a0a0a` `CentralPanel`. On a Phosh device the
//!    GTK binary self-paints the same color as a layer-shell `Overlay`
//!    surface so the running app behind us is fully occluded. The dev
//!    preview gets the same visual contract.
//! 2. Bottom-edge visible handle (`DEFAULT_HANDLE_HEIGHT_PX`). Dragging
//!    upward past `OPEN_THRESHOLD_PX` flips the overlay state machine via
//!    `evaluate_swipe_up`.
//! 3. While `OverlayState::Open` (or `Opening` / `Closing`), card row over
//!    a mock toplevel list. Per-card vertical drag past
//!    `DISMISS_THRESHOLD_PX` removes the toplevel (this is the future
//!    `zwlr_foreign_toplevel_handle_v1.close` hook). Tap activates (we
//!    flag the card visually for preview purposes).
//!
//! Not shipped in the rootfs.

mod layout;

use atomos_app_handler::{
    evaluate_card_dismiss, evaluate_swipe_up, handle, CardOutcome, GestureConfig, OverlayState,
    SwipeOutcome, ToplevelEntry, BACKDROP_BASE_COLOR_RGB, DEFAULT_DISMISS_THRESHOLD_PX,
    DEFAULT_HANDLE_HEIGHT_PX, DEFAULT_OPEN_THRESHOLD_PX,
};
use egui;
use layout::{bottom_handle_rect, lay_out_cards, overlay_progress};

const VIEWPORT_W: f32 = 420.0;
const VIEWPORT_H: f32 = 820.0;
const OVERLAY_ANIM_STEP: f32 = 0.12;

fn backdrop_color() -> egui::Color32 {
    egui::Color32::from_rgb(
        BACKDROP_BASE_COLOR_RGB[0],
        BACKDROP_BASE_COLOR_RGB[1],
        BACKDROP_BASE_COLOR_RGB[2],
    )
}

fn main() -> eframe::Result<()> {
    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("AtomOS app-switcher (dev preview)")
            .with_inner_size([VIEWPORT_W, VIEWPORT_H]),
        ..Default::default()
    };

    eframe::run_native(
        "AtomOS app-switcher dev preview",
        native_options,
        Box::new(|_cc| Ok(Box::<PreviewApp>::default())),
    )
}

struct PreviewApp {
    toplevels: Vec<ToplevelEntry>,
    overlay: OverlayState,
    gestures: GestureConfig,
    last_activated: Option<u32>,
    /// Per-card live drag offset (in px). Only set on the card being dragged.
    card_drag_dy: std::collections::HashMap<u32, f32>,
    /// Bottom-edge handle live drag (in px, negative = up).
    handle_drag_dy: f32,
}

impl Default for PreviewApp {
    fn default() -> Self {
        Self {
            toplevels: mock_toplevels(),
            overlay: OverlayState::Closed,
            gestures: GestureConfig::default(),
            last_activated: None,
            card_drag_dy: Default::default(),
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

/// Deterministic per-card placeholder swatch: hash the app_id into a hue so
/// repeated runs look the same and a maintainer can recognize "the Firefox
/// card" by color. NOT a thumbnail — that lands in v2 once wlr-screencopy
/// is wired in the GTK binary.
fn card_swatch_color(app_id: &str) -> egui::Color32 {
    let mut h: u32 = 5381;
    for b in app_id.bytes() {
        h = h.wrapping_mul(33).wrapping_add(b as u32);
    }
    let hue = (h % 360) as f32;
    hsv_to_rgb(hue, 0.55, 0.75)
}

fn hsv_to_rgb(h: f32, s: f32, v: f32) -> egui::Color32 {
    let c = v * s;
    let h_prime = (h % 360.0) / 60.0;
    let x = c * (1.0 - (h_prime % 2.0 - 1.0).abs());
    let (r, g, b) = match h_prime as i32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = v - c;
    egui::Color32::from_rgb(
        ((r + m) * 255.0) as u8,
        ((g + m) * 255.0) as u8,
        ((b + m) * 255.0) as u8,
    )
}

impl PreviewApp {
    fn advance_overlay_animation(&mut self) {
        match self.overlay {
            OverlayState::Opening { progress } => {
                let next = (progress + OVERLAY_ANIM_STEP).min(1.0);
                let step = if next >= 1.0 {
                    OverlayState::Open
                } else {
                    OverlayState::Opening { progress: next }
                };
                if let Ok(s) = self.overlay.try_transition(step) {
                    self.overlay = s;
                }
            }
            OverlayState::Closing { progress } => {
                let next = (progress + OVERLAY_ANIM_STEP).min(1.0);
                let step = if next >= 1.0 {
                    OverlayState::Closed
                } else {
                    OverlayState::Closing { progress: next }
                };
                if let Ok(s) = self.overlay.try_transition(step) {
                    self.overlay = s;
                }
            }
            _ => {}
        }
    }

    fn request_open(&mut self) {
        if matches!(self.overlay, OverlayState::Closed) {
            if let Ok(s) = self.overlay.try_transition(OverlayState::Opening { progress: 0.0 }) {
                self.overlay = s;
            }
        }
    }

    fn request_close(&mut self) {
        if matches!(self.overlay, OverlayState::Open) {
            if let Ok(s) = self.overlay.try_transition(OverlayState::Closing { progress: 0.0 }) {
                self.overlay = s;
            }
        }
    }
}

impl eframe::App for PreviewApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.advance_overlay_animation();
        if self.overlay.is_visible() && !matches!(self.overlay, OverlayState::Open) {
            ctx.request_repaint();
        }

        egui::CentralPanel::default()
            .frame(egui::Frame::NONE.fill(backdrop_color()).inner_margin(0.0))
            .show(ctx, |ui| {
                let viewport = ui.available_rect_before_wrap();
                let viewport_w = viewport.width();
                let viewport_h = viewport.height();

                if self.overlay.is_visible() {
                    self.paint_cards(ctx, ui, viewport_w, viewport_h);
                } else {
                    self.paint_dim_hint(ui, viewport);
                }

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
            "Swipe up from the bottom edge to open the switcher",
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
        let id = egui::Id::new("app-switcher-bottom-handle");
        let response = ui.interact(rect, id, egui::Sense::click_and_drag());

        // Match the GTK handle via shared core layout/colors.
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
                SwipeOutcome::OpenOverlay
            ) {
                self.request_open();
                self.handle_drag_dy = 0.0;
            }
        }
        if response.drag_stopped() {
            self.handle_drag_dy = 0.0;
        }

        // Also support a click-to-toggle for headless mode / non-touch dev hosts.
        if response.clicked() {
            if matches!(self.overlay, OverlayState::Closed) {
                self.request_open();
            } else if matches!(self.overlay, OverlayState::Open) {
                self.request_close();
            }
        }

        // Provide a Reset button so the dev can quickly repopulate the
        // mock toplevels after dismissing them all.
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

    fn paint_cards(
        &mut self,
        ctx: &egui::Context,
        ui: &mut egui::Ui,
        viewport_w: f32,
        viewport_h: f32,
    ) {
        let anim = overlay_progress(self.overlay);
        let rects = lay_out_cards(self.toplevels.len(), viewport_w, viewport_h, anim);
        if rects.is_empty() {
            return;
        }
        let interactive = self.overlay.is_interactive();
        let mut to_close: Vec<u32> = Vec::new();
        let mut to_activate: Option<u32> = None;
        let snapshot: Vec<ToplevelEntry> = self.toplevels.clone();

        for (idx, t) in snapshot.iter().enumerate() {
            let card = rects[idx];
            let drag_dy = self.card_drag_dy.get(&t.id).copied().unwrap_or(0.0);
            let rect = egui::Rect::from_min_size(
                egui::pos2(card.x, card.y + drag_dy.min(0.0)),
                egui::vec2(card.width, card.height),
            );

            let painter = ui.painter();
            let alpha = (card.opacity.clamp(0.0, 1.0) * 255.0) as u8;
            let mut swatch = card_swatch_color(&t.app_id);
            if alpha < 255 {
                swatch = swatch.gamma_multiply(card.opacity);
            }
            painter.rect_filled(rect, 12.0, swatch);
            // Subtle outline to separate the card from the backdrop.
            painter.rect_stroke(
                rect,
                12.0,
                egui::Stroke::new(1.0, egui::Color32::from_rgba_premultiplied(255, 255, 255, 30)),
                egui::epaint::StrokeKind::Inside,
            );

            painter.text(
                rect.center_top() + egui::vec2(0.0, 18.0),
                egui::Align2::CENTER_CENTER,
                t.display_label(),
                egui::FontId::proportional(15.0),
                egui::Color32::from_rgb(20, 20, 20),
            );
            painter.text(
                rect.center_top() + egui::vec2(0.0, 38.0),
                egui::Align2::CENTER_CENTER,
                t.app_id.as_str(),
                egui::FontId::proportional(11.0),
                egui::Color32::from_rgba_premultiplied(0, 0, 0, 160),
            );

            if !interactive {
                continue;
            }

            let id = egui::Id::new(("app-switcher-card", t.id));
            let response = ui.interact(rect, id, egui::Sense::click_and_drag());

            if response.drag_started() {
                self.card_drag_dy.insert(t.id, 0.0);
            }
            if response.dragged() {
                *self.card_drag_dy.entry(t.id).or_insert(0.0) += response.drag_delta().y;
            }
            if response.drag_stopped() {
                let dy = self.card_drag_dy.remove(&t.id).unwrap_or(0.0);
                match evaluate_card_dismiss(0.0, dy as f64, &self.gestures) {
                    CardOutcome::Close => to_close.push(t.id),
                    CardOutcome::Activate => to_activate = Some(t.id),
                    CardOutcome::Ignore => {}
                }
            } else if response.clicked() {
                to_activate = Some(t.id);
            }
        }

        if !to_close.is_empty() {
            self.toplevels.retain(|t| !to_close.contains(&t.id));
            if self.toplevels.is_empty() {
                self.request_close();
            }
            ctx.request_repaint();
        }
        if let Some(activate_id) = to_activate {
            self.last_activated = Some(activate_id);
            for t in self.toplevels.iter_mut() {
                t.activated = t.id == activate_id;
            }
            self.request_close();
            ctx.request_repaint();
        }
    }
}

#[allow(dead_code)]
fn _unused_marker(_: f64) {
    // Keep DEFAULT_* in scope at the binary-level so doc-link sanity stays warm.
    let _ = DEFAULT_OPEN_THRESHOLD_PX;
    let _ = DEFAULT_DISMISS_THRESHOLD_PX;
    let _ = DEFAULT_HANDLE_HEIGHT_PX;
}
