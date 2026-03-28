use gtk::gdk;
use gtk::gdk::prelude::DisplayExt;
use gtk::gdk::prelude::MonitorExt;
use gtk::gio::prelude::ListModelExt;
use gtk::glib::prelude::Cast;

pub const WIDTH_REQUEST: i32 = 640;
/// Large monitor (desktop / laptop): tall window and visible chrome.
pub const HEIGHT_DESKTOP_LIKE: i32 = 420;
/// Phone-sized overlay: short strip; input at bottom of overview.
pub const HEIGHT_OVERLAY_STRIP: i32 = 120;
/// Keep TextView CSS padding and scroller content height in sync.
pub const INPUT_VERTICAL_INSET_PX: i32 = 20;

pub fn layer_shell_enabled() -> bool {
    matches!(
        std::env::var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_LAYER_SHELL").as_deref(),
        Ok("1")
    )
}

pub fn touch_dismiss_enabled() -> bool {
    matches!(
        std::env::var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_TOUCH_DISMISS").as_deref(),
        Ok("1")
    )
}

/// Use GDK primary/largest monitor geometry (logical px). Phones stay in strip mode.
pub fn session_looks_like_desktop() -> bool {
    let Some((w, h)) = largest_monitor_size_logical() else {
        return false;
    };
    let lo = w.min(h);
    let hi = w.max(h);
    lo >= 600 && hi >= 900
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
