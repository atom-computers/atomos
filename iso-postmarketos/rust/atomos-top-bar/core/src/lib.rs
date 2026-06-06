pub mod dbus;

pub struct TopBarState {
    pub battery_level: f32, // 0.0 to 1.0
    pub is_charging: bool,
    pub signal_bars: u8, // 0 to 4
    pub carrier_name: String,
    pub override_time: Option<String>,
}

impl Default for TopBarState {
    fn default() -> Self {
        Self {
            battery_level: 0.85,
            is_charging: false,
            signal_bars: 0,
            carrier_name: String::new(),
            override_time: None,
        }
    }
}

impl TopBarState {
    pub fn current_time_str(&self) -> String {
        if let Some(ref t) = self.override_time {
            t.clone()
        } else {
            chrono::Local::now().format("%H:%M").to_string()
        }
    }
}
