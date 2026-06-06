#![allow(deprecated, dead_code)]
use eframe::egui;
use atomos_theme::{AtomOSTheme, BORDER_RADIUS, draw_wifi_icon, draw_bluetooth_icon};

fn dummy_main() -> eframe::Result<()> {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([400.0, 500.0])
            .with_title("AtomOS Quick Settings"),
        ..Default::default()
    };
    eframe::run_native(
        "AtomOS Quick Settings",
        options,
        Box::new(|_cc| Ok(Box::new(QuickSettingsApp::default()))),
    )
}

pub struct QuickSettingsApp {
    wifi_enabled: bool,
    bluetooth_enabled: bool,
    dark_mode: bool,
    flashlight: bool,
    brightness: f32,
    volume: f32,
}

impl Default for QuickSettingsApp {
    fn default() -> Self {
        Self {
            wifi_enabled: true,
            bluetooth_enabled: false,
            dark_mode: true,
            flashlight: false,
            brightness: 0.8,
            volume: 0.5,
        }
    }
}

impl eframe::App for QuickSettingsApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let theme = AtomOSTheme { dark_mode: self.dark_mode };
        ctx.set_visuals(if self.dark_mode { egui::Visuals::dark() } else { egui::Visuals::light() });

        // Main Background Panel
        egui::Area::new(egui::Id::new("qs_area")).order(egui::Order::Foreground).show(ctx, |ui| {
            egui::Frame::NONE.fill(egui::Color32::TRANSPARENT).show(ui, |ui| {
                ui.set_min_size(ctx.screen_rect().size());
                let rect = ui.max_rect();
                let painter = ui.painter();
                painter.rect_filled(rect, BORDER_RADIUS, theme.bg_translucent());

                ui.add_space(32.0);
                
                // Toggles Grid
                ui.horizontal(|ui| {
                    ui.add_space(24.0);
                    ui.vertical(|ui| {
                        let button_size = egui::vec2(160.0, 60.0);
                        
                        // Row 1
                        ui.horizontal(|ui| {
                            toggle_button(ui, "Wi-Fi", &mut self.wifi_enabled, button_size, &theme, Some(draw_wifi_icon));
                            ui.add_space(16.0);
                            toggle_button(ui, "Bluetooth", &mut self.bluetooth_enabled, button_size, &theme, Some(draw_bluetooth_icon));
                        });
                        
                        ui.add_space(16.0);
                        
                        // Row 2
                        ui.horizontal(|ui| {
                            toggle_button(ui, "Dark Mode", &mut self.dark_mode, button_size, &theme, None);
                            ui.add_space(16.0);
                            toggle_button(ui, "Flashlight", &mut self.flashlight, button_size, &theme, None);
                        });
                    });
                });

                ui.add_space(32.0);

                // Sliders
                ui.horizontal(|ui| {
                    ui.add_space(24.0);
                    ui.vertical(|ui| {
                        ui.label(egui::RichText::new("Brightness").color(theme.text_primary()).size(16.0));
                        ui.add_space(8.0);
                        let (slider_rect, _) = ui.allocate_exact_size(egui::vec2(352.0, 40.0), egui::Sense::hover());
                        draw_custom_slider(ui, slider_rect, &mut self.brightness, "brightness", &theme);
                        
                        ui.add_space(24.0);
                        
                        ui.label(egui::RichText::new("Volume").color(theme.text_primary()).size(16.0));
                        ui.add_space(8.0);
                        let (slider_rect, _) = ui.allocate_exact_size(egui::vec2(352.0, 40.0), egui::Sense::hover());
                        draw_custom_slider(ui, slider_rect, &mut self.volume, "volume", &theme);
                    });
                });
            });
            });
    }
}

fn toggle_button(
    ui: &mut egui::Ui, 
    text: &str, 
    active: &mut bool, 
    size: egui::Vec2, 
    theme: &AtomOSTheme, 
    draw_icon: Option<fn(&mut egui::Ui, egui::Rect, egui::Color32)>
) {
    let (rect, response) = ui.allocate_exact_size(size, egui::Sense::click());
    
    if response.clicked() {
        *active = !*active;
    }
    
    let painter = ui.painter();
    
    let bg_color = if *active {
        theme.active_bg()
    } else {
        theme.inactive_bg()
    };
    
    painter.rect_filled(rect, BORDER_RADIUS, bg_color);
    
    let text_color = if *active {
        theme.active_fg()
    } else {
        theme.inactive_fg()
    };
    
    if let Some(draw_fn) = draw_icon {
        let icon_rect = egui::Rect::from_center_size(rect.center(), egui::vec2(24.0, 24.0));
        draw_fn(ui, icon_rect, text_color);
    } else {
        painter.text(
            rect.center(),
            egui::Align2::CENTER_CENTER,
            text,
            egui::FontId::proportional(16.0),
            text_color,
        );
    }
}

fn draw_custom_slider(ui: &mut egui::Ui, rect: egui::Rect, value: &mut f32, id: &str, theme: &AtomOSTheme) {
    let response = ui.interact(rect, ui.id().with(id), egui::Sense::drag());
    
    if response.dragged() {
        let delta = response.drag_delta().x;
        *value += delta / rect.width();
        *value = value.clamp(0.0, 1.0);
    }
    
    let painter = ui.painter();
    
    // Background track
    painter.rect_filled(rect, BORDER_RADIUS, theme.inactive_bg());
    
    // Fill
    let mut fill_rect = rect;
    fill_rect.set_width(rect.width() * *value);
    painter.rect_filled(fill_rect, BORDER_RADIUS, theme.active_bg());
}
