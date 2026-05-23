use eframe::egui;

const DEFAULT_VIEWPORT_W: f32 = 420.0;
const DEFAULT_VIEWPORT_H: f32 = 820.0;
const DEFAULT_EDGE_HANDLE_PX: f32 = 15.0;
const DEFAULT_THRESHOLD_FRACTION: f32 = 0.30;

fn main() -> eframe::Result<()> {
    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("AtomOS Swipe Lab (open app -> overview)")
            .with_inner_size([DEFAULT_VIEWPORT_W, DEFAULT_VIEWPORT_H]),
        ..Default::default()
    };

    eframe::run_native(
        "AtomOS Swipe Lab",
        native_options,
        Box::new(|_cc| Ok(Box::<SwipeLabApp>::default())),
    )
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SwipeOutcome {
    Triggered,
    Cancelled,
    IgnoredStartOutsideHandle,
}

#[derive(Default)]
struct SwipeLabApp {
    drag_start_y: Option<f32>,
    drag_current_y: Option<f32>,
    viewport_h_override: f32,
    edge_handle_px: f32,
    threshold_fraction: f32,
    last_outcome: Option<SwipeOutcome>,
    started_in_handle: bool,
    overview_open: bool,
}

impl SwipeLabApp {
    fn viewport_h(&self, ctx: &egui::Context) -> f32 {
        let detected = ctx.input(|i| {
            i.viewport()
                .inner_rect
                .map(|r| r.height())
                .unwrap_or(DEFAULT_VIEWPORT_H)
        });
        if self.viewport_h_override > 0.0 {
            self.viewport_h_override
        } else {
            detected
        }
    }

    fn ensure_defaults(&mut self) {
        if self.edge_handle_px <= 0.0 {
            self.edge_handle_px = DEFAULT_EDGE_HANDLE_PX;
        }
        if self.threshold_fraction <= 0.0 {
            self.threshold_fraction = DEFAULT_THRESHOLD_FRACTION;
        }
    }

    fn start_drag_if_valid(&mut self, pointer_y: f32, viewport_h: f32) {
        self.drag_start_y = Some(pointer_y);
        self.drag_current_y = Some(pointer_y);
        self.started_in_handle = pointer_y >= (viewport_h - self.edge_handle_px);
    }

    fn update_drag(&mut self, pointer_y: f32) {
        if self.drag_start_y.is_some() {
            self.drag_current_y = Some(pointer_y);
        }
    }

    fn finish_drag(&mut self, viewport_h: f32) {
        let Some(start_y) = self.drag_start_y else {
            return;
        };
        let end_y = self.drag_current_y.unwrap_or(start_y);
        let upward_distance = (start_y - end_y).max(0.0);
        let threshold_px = self.threshold_fraction * viewport_h.max(1.0);

        if !self.started_in_handle {
            self.last_outcome = Some(SwipeOutcome::IgnoredStartOutsideHandle);
            self.overview_open = false;
        } else if upward_distance >= threshold_px {
            self.last_outcome = Some(SwipeOutcome::Triggered);
            self.overview_open = true;
        } else {
            self.last_outcome = Some(SwipeOutcome::Cancelled);
            self.overview_open = false;
        }

        self.drag_start_y = None;
        self.drag_current_y = None;
    }
}

impl eframe::App for SwipeLabApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.ensure_defaults();
        let viewport_h = self.viewport_h(ctx);
        let threshold_px = self.threshold_fraction * viewport_h.max(1.0);

        // Main "open app" view.
        egui::CentralPanel::default()
            .frame(
                egui::Frame::default()
                    .fill(egui::Color32::from_rgb(20, 24, 34))
                    .inner_margin(0.0),
            )
            .show(ctx, |ui| {
                ui.allocate_ui_with_layout(
                    ui.available_size(),
                    egui::Layout::top_down(egui::Align::LEFT),
                    |ui| {
                        ui.horizontal(|ui| {
                            ui.label(
                                egui::RichText::new(if self.overview_open {
                                    "Overview: OPEN"
                                } else {
                                    "Overview: FOLDED (app visible)"
                                })
                                .strong()
                                .color(if self.overview_open {
                                    egui::Color32::from_rgb(150, 240, 170)
                                } else {
                                    egui::Color32::from_rgb(200, 210, 255)
                                }),
                            );
                        });
                        ui.add_space(8.0);
                        ui.label("Swipe from bottom handle upward to simulate vendor phosh gesture.");
                        ui.label("This is a fast logic lab (not a compositor integration test).");
                    },
                );
            });

        // Bottom handle visual.
        let bottom_strip_h = self.edge_handle_px.max(1.0);
        egui::Area::new(egui::Id::new("swipe-lab-bottom-handle"))
            .anchor(egui::Align2::LEFT_BOTTOM, egui::vec2(0.0, 0.0))
            .order(egui::Order::Foreground)
            .show(ctx, |ui| {
                let w = ui.available_width().max(DEFAULT_VIEWPORT_W);
                let (rect, _resp) = ui.allocate_exact_size(
                    egui::vec2(w, bottom_strip_h),
                    egui::Sense::hover(),
                );
                ui.painter().rect_filled(
                    rect,
                    0.0,
                    egui::Color32::from_rgba_premultiplied(210, 215, 230, 50),
                );
            });

        // Settings panel.
        egui::Window::new("Swipe Controls")
            .default_pos(egui::pos2(16.0, 64.0))
            .resizable(false)
            .collapsible(false)
            .show(ctx, |ui| {
                ui.label("Tune these to mirror current phosh/home assumptions:");
                ui.add(
                    egui::Slider::new(&mut self.edge_handle_px, 1.0..=80.0)
                        .text("edge handle px"),
                );
                ui.add(
                    egui::Slider::new(&mut self.threshold_fraction, 0.05..=0.80)
                        .text("threshold fraction"),
                );
                ui.add(
                    egui::Slider::new(&mut self.viewport_h_override, 0.0..=1400.0)
                        .text("viewport h override (0=auto)"),
                );
                ui.separator();
                ui.label(format!("threshold px: {:.1}", threshold_px));
                if let Some(outcome) = self.last_outcome {
                    let text = match outcome {
                        SwipeOutcome::Triggered => "last outcome: triggered overview",
                        SwipeOutcome::Cancelled => "last outcome: cancelled (distance too short)",
                        SwipeOutcome::IgnoredStartOutsideHandle => {
                            "last outcome: ignored (start outside handle)"
                        }
                    };
                    ui.label(text);
                } else {
                    ui.label("last outcome: none");
                }
            });

        // Pointer gesture capture.
        let (primary_down, latest_pos) =
            ctx.input(|i| (i.pointer.primary_down(), i.pointer.latest_pos()));

        if primary_down {
            if let Some(pos) = latest_pos {
                if self.drag_start_y.is_none() {
                    self.start_drag_if_valid(pos.y, viewport_h);
                } else {
                    self.update_drag(pos.y);
                }
            }
        } else if self.drag_start_y.is_some() {
            self.finish_drag(viewport_h);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn triggers_when_started_in_handle_and_above_threshold() {
        let mut app = SwipeLabApp {
            edge_handle_px: 15.0,
            threshold_fraction: 0.3,
            ..Default::default()
        };
        let vh = 800.0;
        app.start_drag_if_valid(796.0, vh);
        app.update_drag(540.0);
        app.finish_drag(vh);
        assert_eq!(app.last_outcome, Some(SwipeOutcome::Triggered));
        assert!(app.overview_open);
    }

    #[test]
    fn ignores_when_start_outside_handle() {
        let mut app = SwipeLabApp {
            edge_handle_px: 15.0,
            threshold_fraction: 0.3,
            ..Default::default()
        };
        let vh = 800.0;
        app.start_drag_if_valid(700.0, vh);
        app.update_drag(200.0);
        app.finish_drag(vh);
        assert_eq!(
            app.last_outcome,
            Some(SwipeOutcome::IgnoredStartOutsideHandle)
        );
        assert!(!app.overview_open);
    }
}
