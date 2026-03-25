use std::process::Command;

use atomos_overview_chat_ui::{enter_action, layout_state_for_text, EnterKeyAction, MAX_LINES};
use adw::prelude::*;
use gtk::gdk;
use gtk::gdk::prelude::MonitorExt;
use gtk::gio::prelude::ListModelExt;
use gtk::glib;
use gtk::glib::prelude::Cast;

const WIDTH_REQUEST: i32 = 640;
/// Large monitor (desktop / laptop): tall window and visible chrome.
const HEIGHT_DESKTOP_LIKE: i32 = 420;
/// Phone-sized overlay: short strip; input at bottom of overview.
const HEIGHT_OVERLAY_STRIP: i32 = 120;

/// Use GDK primary/largest monitor geometry (logical px). Phones stay in strip mode.
fn session_looks_like_desktop() -> bool {
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

fn main() -> anyhow::Result<()> {
    let app = adw::Application::builder()
        .application_id("org.atomos.OverviewChatUi")
        .build();

    app.connect_activate(build_ui);
    app.run();
    Ok(())
}

fn build_ui(app: &adw::Application) {
    let desktop_like = session_looks_like_desktop();
    let root_bg = if desktop_like {
        "background-color: alpha(#0b0f17, 0.92);"
    } else {
        "background-color: rgba(0, 0, 0, 0);"
    };
    let input_extra = if desktop_like {
        "outline: 1px solid alpha(#ffffff, 0.22); outline-offset: -1px;"
    } else {
        ""
    };

    let css = gtk::CssProvider::new();
    css.load_from_data(&format!(
        "
window.atomos-chat-root {{
  {root_bg}
}}
box.atomos-chat-wrap {{
  padding: 12px;
}}
scrolledwindow.atomos-chat-input {{
  border-radius: 16px;
  background: alpha(#151923, 0.74);
  {input_extra}
}}
textview.atomos-chat-input {{
  background-color: transparent;
  color: #ffffff;
}}
",
        root_bg = root_bg,
        input_extra = input_extra
    ));
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    let default_h = if desktop_like {
        HEIGHT_DESKTOP_LIKE
    } else {
        HEIGHT_OVERLAY_STRIP
    };
    let win = adw::ApplicationWindow::builder()
        .application(app)
        .title("AtomOS Overview Chat")
        .default_width(WIDTH_REQUEST)
        .default_height(default_h)
        .build();
    win.add_css_class("atomos-chat-root");
    win.set_decorated(desktop_like);

    let outer = gtk::Box::new(gtk::Orientation::Vertical, 0);
    outer.set_vexpand(true);
    let spacer = gtk::Box::new(gtk::Orientation::Vertical, 0);
    spacer.set_vexpand(true);
    outer.append(&spacer);

    let wrap = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    wrap.add_css_class("atomos-chat-wrap");
    wrap.set_hexpand(true);

    let input_scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Never)
        .min_content_height(38)
        .max_content_height(38 * MAX_LINES)
        .hexpand(true)
        .build();
    input_scroller.add_css_class("atomos-chat-input");

    let input = gtk::TextView::new();
    input.add_css_class("atomos-chat-input");
    input.set_wrap_mode(gtk::WrapMode::WordChar);
    input.set_left_margin(14);
    input.set_right_margin(14);
    input.set_top_margin(10);
    input.set_bottom_margin(10);
    input.set_accepts_tab(false);
    input_scroller.set_child(Some(&input));
    wrap.append(&input_scroller);
    outer.append(&wrap);
    win.set_content(Some(&outer));

    let input_scroller_clone = input_scroller.clone();
    let buffer = input.buffer();
    buffer.connect_changed(move |buf| {
        let start = buf.start_iter();
        let end = buf.end_iter();
        let text = buf.text(&start, &end, true);
        let state = layout_state_for_text(text.as_str());
        input_scroller_clone.set_min_content_height(state.min_content_height);
        input_scroller_clone.set_max_content_height(state.max_content_height);
        let needs_scroll = state.needs_scroll;
        input_scroller_clone.set_vscrollbar_policy(if needs_scroll {
            gtk::PolicyType::Automatic
        } else {
            gtk::PolicyType::Never
        });
    });

    let key = gtk::EventControllerKey::new();
    let input_for_key = input.clone();
    key.connect_key_pressed(move |_controller, keyval, _keycode, state| {
        if keyval == gdk::Key::Return {
            let buf = input_for_key.buffer();
            let start = buf.start_iter();
            let end = buf.end_iter();
            let message = buf.text(&start, &end, true).to_string();
            return match enter_action(&message, state.contains(gdk::ModifierType::SHIFT_MASK)) {
                EnterKeyAction::Submit(payload) => {
                    let _ = Command::new("/usr/libexec/atomos-overview-chat-submit")
                        .arg(payload)
                        .status();
                    buf.set_text("");
                    glib::Propagation::Stop
                }
                EnterKeyAction::Noop => glib::Propagation::Stop,
                EnterKeyAction::InsertNewline => glib::Propagation::Proceed,
            };
        }
        glib::Propagation::Proceed
    });
    input.add_controller(key);

    if desktop_like {
        let input_focus = input.clone();
        win.connect_map(move |_w| {
            let input_focus = input_focus.clone();
            glib::idle_add_local_once(move || {
                input_focus.grab_focus();
            });
        });
    }

    win.present();
}
