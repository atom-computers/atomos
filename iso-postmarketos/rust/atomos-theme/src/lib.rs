use egui::{Color32, StrokeKind, Margin};

// Globals
pub const ATOMOS_GREEN: Color32 = Color32::from_rgb(52, 199, 89);
pub const ATOMOS_RED: Color32 = Color32::from_rgb(255, 59, 48);
pub const BORDER_RADIUS: f32 = 12.0;

pub struct AtomOSTheme {
    pub dark_mode: bool,
}

impl AtomOSTheme {
    pub fn bg_translucent(&self) -> Color32 {
        if self.dark_mode {
            Color32::from_black_alpha(204) // 0.8 opacity black
        } else {
            Color32::from_white_alpha(204) // 0.8 opacity white
        }
    }
    
    pub fn active_bg(&self) -> Color32 {
        if self.dark_mode {
            Color32::from_gray(80) // Darker grey for active pill in dark mode
        } else {
            Color32::from_gray(220) // Light grey
        }
    }
    
    pub fn inactive_bg(&self) -> Color32 {
        if self.dark_mode {
            Color32::from_white_alpha(30)
        } else {
            Color32::from_black_alpha(30)
        }
    }
    
    pub fn active_fg(&self) -> Color32 {
        if self.dark_mode {
            Color32::WHITE
        } else {
            Color32::BLACK
        }
    }
    
    pub fn inactive_fg(&self) -> Color32 {
        if self.dark_mode {
            Color32::from_gray(140) // Darker light grey for inactive icons
        } else {
            Color32::BLACK
        }
    }
    
    pub fn text_primary(&self) -> Color32 {
        if self.dark_mode { Color32::WHITE } else { Color32::BLACK }
    }
}

pub fn draw_wifi_icon(ui: &mut egui::Ui, rect: egui::Rect, color: Color32) {
    let painter = ui.painter();
    let center = egui::pos2(rect.center().x, rect.max.y - 8.0);
    
    // Dot
    painter.circle_filled(center, 2.0, color);
    
    // Arcs
    for i in 1..=3 {
        let radius = 2.0 + 5.0 * i as f32;
        let mut points = vec![];
        for angle in -45..=45 {
            let rad = (angle as f32 - 90.0) * std::f32::consts::PI / 180.0;
            points.push(center + egui::vec2(rad.cos() * radius, rad.sin() * radius));
        }
        painter.add(egui::Shape::line(points, egui::Stroke::new(2.0, color)));
    }
}

pub fn draw_bluetooth_icon(ui: &mut egui::Ui, rect: egui::Rect, color: Color32) {
    let painter = ui.painter();
    let stroke = egui::Stroke::new(2.0, color);
    
    let cx = rect.center().x;
    let cy = rect.center().y;
    let h = 8.0;
    let w = 6.0;
    
    // Continuous BT logo path
    let points = vec![
        egui::pos2(cx - w, cy + h / 2.0), // Left mid-bottom
        egui::pos2(cx + w, cy - h / 2.0), // Right mid-top
        egui::pos2(cx, cy - h),           // Top
        egui::pos2(cx, cy + h),           // Bottom
        egui::pos2(cx + w, cy + h / 2.0), // Right mid-bottom
        egui::pos2(cx - w, cy - h / 2.0), // Left mid-top
    ];
    
    painter.add(egui::Shape::line(points, stroke));
}


pub fn default_margin() -> Margin {
    Margin::symmetric(16, 4)
}

pub fn draw_battery(ui: &mut egui::Ui, level: f32, is_charging: bool) {
    let (rect, _response) = ui.allocate_exact_size(egui::vec2(24.0, 12.0), egui::Sense::hover());
    if ui.is_rect_visible(rect) {
        let painter = ui.painter();
        
        let outline_color = egui::Color32::from_gray(200);
        let fill_color = if is_charging {
            ATOMOS_GREEN
        } else if level <= 0.2 {
            ATOMOS_RED
        } else {
            egui::Color32::WHITE
        };

        let body_rect = egui::Rect::from_min_max(rect.min, rect.max - egui::vec2(3.0, 0.0));
        painter.rect_stroke(body_rect, 3.0, (1.0, outline_color), StrokeKind::Middle);
        
        let tip_rect = egui::Rect::from_min_max(
            egui::pos2(rect.max.x - 2.0, rect.min.y + 3.0),
            egui::pos2(rect.max.x, rect.max.y - 3.0)
        );
        painter.rect_filled(tip_rect, 1.0, outline_color);

        let inner_rect = body_rect.shrink(2.0);
        let fill_width = inner_rect.width() * level.clamp(0.0, 1.0);
        if fill_width > 0.0 {
            let mut level_rect = inner_rect;
            level_rect.set_width(fill_width);
            painter.rect_filled(level_rect, 1.0, fill_color);
        }
    }
}

pub fn draw_signal_bars(ui: &mut egui::Ui, bars: u8) {
    let (rect, _response) = ui.allocate_exact_size(egui::vec2(16.0, 12.0), egui::Sense::hover());
    if ui.is_rect_visible(rect) {
        let painter = ui.painter();
        let bar_width = 3.0;
        let spacing = 1.0;
        let mut x = rect.min.x;
        
        for i in 1..=4 {
            let height = 3.0 * i as f32;
            let bar_rect = egui::Rect::from_min_max(
                egui::pos2(x, rect.max.y - height),
                egui::pos2(x + bar_width, rect.max.y)
            );
            
            let color = if i <= bars {
                egui::Color32::WHITE
            } else {
                egui::Color32::from_white_alpha(70)
            };
            
            painter.rect_filled(bar_rect, 1.0, color);
            x += bar_width + spacing;
        }
    }
}
