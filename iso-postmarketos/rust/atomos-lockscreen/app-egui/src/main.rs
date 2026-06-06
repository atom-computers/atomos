use eframe::egui;
use atomos_theme::{draw_battery, draw_signal_bars, AtomOSTheme};
use chrono::Local;

fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([400.0, 800.0])
            .with_title("AtomOS Lockscreen"),
        ..Default::default()
    };
    eframe::run_native(
        "AtomOS Lockscreen",
        options,
        Box::new(|_cc| Ok(Box::new(LockscreenApp::default()))),
    )
}

struct LockscreenApp {
    swipe_offset: f32,
    unlocked: bool,
}

impl Default for LockscreenApp {
    fn default() -> Self {
        Self {
            swipe_offset: 0.0,
            unlocked: false,
        }
    }
}

impl eframe::App for LockscreenApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if self.unlocked {
            egui::CentralPanel::default().show(ctx, |ui| {
                ui.centered_and_justified(|ui| {
                    ui.heading("Unlocked!");
                    if ui.button("Lock again").clicked() {
                        self.unlocked = false;
                        self.swipe_offset = 0.0;
                    }
                });
            });
            return;
        }

        let theme = AtomOSTheme { dark_mode: true }; // Lockscreen always dark or follows system

        // The entire lockscreen
        egui::CentralPanel::default()
            .frame(egui::Frame::NONE.fill(egui::Color32::from_rgb(20, 20, 30))) // Keep dark wallpaper feel for now
            .show(ctx, |ui| {
                // Shift UI based on swipe offset
                let transform = egui::emath::TSTransform::from_translation(egui::vec2(0.0, -self.swipe_offset));
                ctx.set_transform_layer(ui.layer_id(), transform);

                // Top Bar (Status)
                ui.add_space(32.0);
                ui.horizontal(|ui| {
                    ui.add_space(24.0);
                    // Left
                    ui.label(egui::RichText::new("AtomOS").color(theme.text_primary()).size(14.0));
                    
                    // Right
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        ui.add_space(24.0);
                        draw_battery(ui, 0.85, false);
                        ui.add_space(8.0);
                        draw_signal_bars(ui, 3);
                    });
                });

                // Center Clock
                ui.add_space(100.0);
                ui.vertical_centered(|ui| {
                    let time = Local::now().format("%H:%M").to_string();
                    let date = Local::now().format("%A, %B %d").to_string();
                    
                    ui.label(egui::RichText::new(time)
                        .color(theme.text_primary())
                        .size(80.0)
                        .strong());
                        
                    ui.label(egui::RichText::new(date)
                        .color(theme.text_primary().linear_multiply(0.7))
                        .size(20.0));
                });

                // Bottom: Swipe to unlock
                ui.with_layout(egui::Layout::bottom_up(egui::Align::Center), |ui| {
                    ui.add_space(40.0);
                    let text = egui::RichText::new("Swipe up to unlock")
                        .color(theme.text_primary().linear_multiply(0.5))
                        .size(16.0);
                    ui.label(text);
                    
                    // Handle swipe/drag
                    let response = ui.interact(ui.max_rect(), ui.id().with("swipe_area"), egui::Sense::drag());
                    
                    if response.dragged() {
                        let delta = response.drag_delta();
                        if delta.y < 0.0 {
                            self.swipe_offset -= delta.y; // Move up
                        }
                    }
                    
                    if response.drag_stopped() {
                        if self.swipe_offset > 200.0 {
                            self.unlocked = true;
                        } else {
                            self.swipe_offset = 0.0; // Snap back
                        }
                    } else if !response.dragged() && self.swipe_offset > 0.0 {
                        // Smooth snap back
                        self.swipe_offset *= 0.8;
                    }
                });
            });

        ctx.request_repaint(); // Keep animating time/snap back
    }
}
