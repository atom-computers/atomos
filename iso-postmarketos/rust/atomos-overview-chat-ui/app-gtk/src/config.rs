use gtk::gdk;
use gtk::gdk::prelude::DisplayExt;
use gtk::gdk::prelude::MonitorExt;
use gtk::gio::prelude::ListModelExt;
use gtk::glib::prelude::Cast;

use crate::logic::{env_flag_enabled, parse_bool_env_value, resolve_desktop_like_mode};

pub const WIDTH_REQUEST: i32 = 640;
/// Large monitor (desktop / laptop): tall window and visible chrome.
pub const HEIGHT_DESKTOP_LIKE: i32 = 420;
/// Phone-sized overlay: short strip; input at bottom of overview.
pub const HEIGHT_OVERLAY_STRIP: i32 = 120;
/// Keep TextView CSS padding and scroller content height in sync.
pub const INPUT_VERTICAL_INSET_PX: i32 = 20;

pub fn layer_shell_enabled() -> bool {
    env_flag_enabled(std::env::var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL"))
}

pub fn touch_dismiss_enabled() -> bool {
    env_flag_enabled(std::env::var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS"))
}

/// Use GDK primary/largest monitor geometry (logical px). Phones stay in strip mode.
pub fn session_looks_like_desktop() -> bool {
    if env_flag_enabled(std::env::var(
        "ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE",
    )) {
        return false;
    }
    resolve_desktop_like_mode(desktop_like_override(), largest_monitor_size_logical())
}

fn desktop_like_override() -> Option<bool> {
    parse_bool_env_value(std::env::var("ATOMOS_OVERVIEW_CHAT_UI_DESKTOP_LIKE_OVERRIDE"))
}

fn largest_monitor_size_logical() -> Option<(i32, i32)> {
    let display = gdk::Display::default()?;
    let monitors = display.monitors();
    let n = monitors.n_items();
    if n == 0 {
        return None;
    }
    let mut best: Option<(i32, i32)> = None;
    let mut best_area = 0i32;
    for i in 0..n {
        let obj = monitors.item(i)?;
        let mon = obj.downcast::<gdk::Monitor>().ok()?;
        let rect = mon.geometry();
        let w = rect.width();
        let h = rect.height();
        let area = w.saturating_mul(h);
        if area > best_area {
            best_area = area;
            best = Some((w, h));
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::{
        desktop_like_override, layer_shell_enabled, session_looks_like_desktop,
        touch_dismiss_enabled,
    };
    use std::sync::Mutex;

    // Tests in this module mutate process env vars; cargo test runs test fns
    // in parallel by default, so same-var mutators must serialize or they
    // race their own remove_var/set_var pairs. PoisonError is ignored
    // because assertion panics can leave the lock poisoned without
    // invalidating the guard's state.
    static DESKTOP_LIKE_OVERRIDE_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn desktop_like_override_unset() {
        let _g = DESKTOP_LIKE_OVERRIDE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::remove_var("ATOMOS_OVERVIEW_CHAT_UI_DESKTOP_LIKE_OVERRIDE");
        assert_eq!(desktop_like_override(), None);
    }

    #[test]
    fn desktop_like_override_true() {
        let _g = DESKTOP_LIKE_OVERRIDE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("ATOMOS_OVERVIEW_CHAT_UI_DESKTOP_LIKE_OVERRIDE", "1");
        assert_eq!(desktop_like_override(), Some(true));
        std::env::remove_var("ATOMOS_OVERVIEW_CHAT_UI_DESKTOP_LIKE_OVERRIDE");
    }

    #[test]
    fn desktop_like_override_false() {
        let _g = DESKTOP_LIKE_OVERRIDE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("ATOMOS_OVERVIEW_CHAT_UI_DESKTOP_LIKE_OVERRIDE", "0");
        assert_eq!(desktop_like_override(), Some(false));
        std::env::remove_var("ATOMOS_OVERVIEW_CHAT_UI_DESKTOP_LIKE_OVERRIDE");
    }

    #[test]
    fn layer_shell_enabled_honors_flag() {
        std::env::set_var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL", "1");
        assert!(layer_shell_enabled());
        std::env::set_var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL", "0");
        assert!(!layer_shell_enabled());
        std::env::remove_var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL");
    }

    #[test]
    fn touch_dismiss_enabled_honors_flag() {
        std::env::set_var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS", "1");
        assert!(touch_dismiss_enabled());
        std::env::set_var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS", "0");
        assert!(!touch_dismiss_enabled());
        std::env::remove_var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS");
    }

    #[test]
    fn skip_monitor_probe_forces_mobile_mode() {
        std::env::set_var("ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE", "1");
        assert!(!session_looks_like_desktop());
        std::env::remove_var("ATOMOS_OVERVIEW_CHAT_UI_SKIP_MONITOR_PROBE");
    }
}
