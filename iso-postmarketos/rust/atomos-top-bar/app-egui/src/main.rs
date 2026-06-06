use eframe::egui;
use std::sync::{Arc, Mutex};
use atomos_top_bar_core::TopBarState;
use atomos_top_bar_core::dbus::start_dbus_listener;
use atomos_theme::{draw_battery, draw_signal_bars, AtomOSTheme, default_margin};

#[tokio::main]
async fn main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([400.0, 300.0])
            .with_title("AtomOS Top Bar Preview"),
        ..Default::default()
    };
    eframe::run_native(
        "AtomOS Top Bar",
        options,
        Box::new(|_cc| Ok(Box::new(TopBarApp::new()))),
    )
}

struct TopBarApp {
    state: Arc<Mutex<TopBarState>>,
}

impl TopBarApp {
    fn new() -> Self {
        let state = Arc::new(Mutex::new(TopBarState::default()));
        
        let dbus_state = state.clone();
        tokio::spawn(async move {
            start_dbus_listener(dbus_state).await;
        });

        Self { state }
    }
}

impl eframe::App for TopBarApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let mut state = self.state.lock().unwrap();

        let theme = AtomOSTheme { dark_mode: true }; // System-wide dark mode state would go here

        // TOP BAR OVERLAY
        egui::TopBottomPanel::top("top_bar")
            .exact_height(24.0)
            .frame(egui::Frame::NONE.fill(theme.bg_translucent()).inner_margin(default_margin()))
            .show(ctx, |ui| {
                ui.horizontal(|ui| {
                    // LEFT (Carrier / Notifications)
                    ui.with_layout(egui::Layout::left_to_right(egui::Align::Center), |ui| {
                        ui.label(egui::RichText::new("AtomOS").color(egui::Color32::WHITE).size(12.0));
                    });

                    // CENTER (Clock)
                    ui.with_layout(egui::Layout::centered_and_justified(egui::Direction::LeftToRight), |ui| {
                        ui.label(egui::RichText::new(state.current_time_str()).color(egui::Color32::WHITE).size(13.0).strong());
                    });

                    // RIGHT (System Tray)
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        draw_battery(ui, state.battery_level, state.is_charging);
                        ui.add_space(8.0);
                        draw_signal_bars(ui, state.signal_bars);
                    });
                });
            });

        // CONTROL PANEL
        egui::CentralPanel::default().show(ctx, |ui| {
            ui.heading("Developer Controls");
            ui.separator();
            ui.horizontal(|ui| {
                ui.label("Battery Level:");
                ui.add(egui::Slider::new(&mut state.battery_level, 0.0..=1.0));
            });
            ui.checkbox(&mut state.is_charging, "Is Charging");
            ui.horizontal(|ui| {
                ui.label("Signal Bars:");
                ui.add(egui::Slider::new(&mut state.signal_bars, 0..=4));
            });
            // Force redraw since clock changes
            ctx.request_repaint_after(std::time::Duration::from_secs(1));
        });
    }
}


