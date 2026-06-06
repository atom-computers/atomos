use adw::prelude::*;
use gtk::glib;
use std::cell::Cell;
use std::rc::Rc;

use crate::app_grid::build_app_grid_sheet;
use crate::config::{
    layer_shell_enabled, session_looks_like_desktop, touch_dismiss_enabled, HEIGHT_DESKTOP_LIKE,
    HEIGHT_OVERLAY_STRIP, WIDTH_REQUEST,
};
use crate::input::{build_input_scroller, wire_enter_submit_behavior, wire_input_layout_behavior};
use crate::logic::should_use_layer_shell;
use crate::overlay::configure_mobile_overlay_surface;
use crate::style::{apply_theme_class, install_css};

fn startup_trace_enabled() -> bool {
    matches!(
        std::env::var("ATOMOS_OVERVIEW_CHAT_UI_STARTUP_TRACE").as_deref(),
        Ok("1")
    )
}

fn startup_trace(phase: &str) {
    if startup_trace_enabled() {
        eprintln!("atomos-overview-chat-ui: startup phase={phase}");
    }
}

fn eager_app_grid_enabled() -> bool {
    matches!(
        std::env::var("ATOMOS_OVERVIEW_CHAT_UI_EAGER_APP_GRID").as_deref(),
        Ok("1")
    )
}

pub fn build_ui(app: &adw::Application) {
    startup_trace("begin");
    startup_trace("session_looks_like_desktop:before");
    let desktop_like = session_looks_like_desktop();
    startup_trace("session_looks_like_desktop:after");
    startup_trace("install_css:before");
    install_css(desktop_like);
    startup_trace("install_css:after");

    let default_h = if desktop_like {
        HEIGHT_DESKTOP_LIKE
    } else {
        HEIGHT_OVERLAY_STRIP
    };
    startup_trace("window_builder:before");
    let win = adw::ApplicationWindow::builder()
        .application(app)
        .title("AtomOS Overview Chat")
        .default_width(WIDTH_REQUEST)
        .default_height(default_h)
        .build();
    startup_trace("window_builder:after");
    win.add_css_class("atomos-chat-root");
    startup_trace("apply_theme_class:before");
    apply_theme_class(&win);
    startup_trace("apply_theme_class:after");

    let use_layer_shell = should_use_layer_shell(desktop_like, layer_shell_enabled());
    eprintln!(
        "atomos-overview-chat-ui: desktop_like={desktop_like} layer_shell_enabled={use_layer_shell}"
    );
    win.set_decorated(desktop_like || !use_layer_shell);
    if !desktop_like {
        // Some target images crash in layer-shell setup. Keep a safe default and
        // avoid creating a regular toplevel that gets treated as an app window.
        if use_layer_shell {
            let configured = configure_mobile_overlay_surface(&win);
            if !configured {
                eprintln!(
                    "atomos-overview-chat-ui: layer-shell requested but unavailable; exiting to avoid toplevel fallback"
                );
                app.quit();
                return;
            }
        } else {
            // Debug-friendly fallback on QEMU: force a standard toplevel that
            // should be clearly visible even if layer-shell placement fails.
            win.maximize();
        }
    }
    startup_trace("widget_tree:before");

    let outer = gtk::Box::new(gtk::Orientation::Vertical, 0);
    outer.add_css_class("atomos-chat-outer");
    outer.set_vexpand(true);

    let top_row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    top_row.add_css_class("atomos-top-row");
    top_row.set_hexpand(true);

    let top_dock = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    top_dock.add_css_class("atomos-top-dock");
    top_dock.set_halign(gtk::Align::Start);
    top_dock.set_can_target(true);

    let app_grid_icon = gtk::Image::from_icon_name("view-app-grid-symbolic");
    app_grid_icon.set_pixel_size(22);
    let app_grid_btn = gtk::Button::new();
    app_grid_btn.add_css_class("atomos-dock-btn");
    app_grid_btn.set_tooltip_text(Some("Toggle app grid"));
    app_grid_btn.set_child(Some(&app_grid_icon));
    top_dock.append(&app_grid_btn);

    let top_spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    top_spacer.set_hexpand(true);
    top_row.append(&top_dock);
    top_row.append(&top_spacer);
    outer.append(&top_row);

    let center_overlay = gtk::Overlay::new();
    center_overlay.set_vexpand(true);
    center_overlay.set_hexpand(true);
    let spacer = gtk::Box::new(gtk::Orientation::Vertical, 0);
    spacer.add_css_class("atomos-chat-fill");
    spacer.set_vexpand(true);
    center_overlay.set_child(Some(&spacer));

    let app_sheet_wrap = gtk::Box::new(gtk::Orientation::Vertical, 0);
    app_sheet_wrap.add_css_class("atomos-app-sheet-wrap");
    app_sheet_wrap.set_halign(gtk::Align::Fill);
    app_sheet_wrap.set_hexpand(true);
    app_sheet_wrap.set_vexpand(true);
    app_sheet_wrap.set_margin_start(20);
    app_sheet_wrap.set_margin_end(20);
    app_sheet_wrap.set_margin_top(18);
    app_sheet_wrap.set_margin_bottom(18);
    app_sheet_wrap.set_height_request(240);
    let app_sheet_revealer = gtk::Revealer::new();
    app_sheet_revealer.set_transition_type(gtk::RevealerTransitionType::SlideDown);
    app_sheet_revealer.set_transition_duration(180);
    app_sheet_revealer.set_hexpand(true);
    app_sheet_revealer.set_vexpand(true);
    app_sheet_revealer.set_margin_start(0);
    app_sheet_revealer.set_margin_end(0);
    app_sheet_revealer.set_halign(gtk::Align::Fill);
    app_sheet_revealer.set_valign(gtk::Align::Fill);
    app_sheet_revealer.set_child(Some(&app_sheet_wrap));
    app_sheet_revealer.set_reveal_child(false);
    center_overlay.add_overlay(&app_sheet_revealer);
    outer.append(&center_overlay);

    let wrap = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    wrap.add_css_class("atomos-chat-wrap");
    wrap.set_hexpand(true);

    let input_scroller = build_input_scroller();
    input_scroller.add_css_class("atomos-chat-input");
    let input = gtk::TextView::new();
    input.add_css_class("atomos-chat-input");
    input.set_wrap_mode(gtk::WrapMode::WordChar);
    input.set_accepts_tab(false);
    input_scroller.set_child(Some(&input));
    wrap.append(&input_scroller);
    outer.append(&wrap);
    win.set_content(Some(&outer));
    let app_sheet_built = Rc::new(Cell::new(false));
    let dismiss_app_sheet = {
        let app_sheet_revealer = app_sheet_revealer.clone();
        let app_grid_icon = app_grid_icon.clone();
        let wrap = wrap.clone();
        Rc::new(move || {
            if app_sheet_revealer.reveals_child() {
                eprintln!("atomos-overview-chat-ui: dismissing app sheet for launch");
                app_sheet_revealer.set_reveal_child(false);
                app_grid_icon.set_icon_name(Some("view-app-grid-symbolic"));
                wrap.set_visible(true);
            }
        })
    };
    if eager_app_grid_enabled() {
        startup_trace("app_grid:eager-build:before");
        // Headless/CI repro: still defer so startup does not block the main loop.
        schedule_app_grid_build(
            &app_sheet_wrap,
            app_sheet_built.clone(),
            dismiss_app_sheet.clone(),
        );
        startup_trace("app_grid:eager-build:scheduled");
    }

    connect_dock_toggle(
        &win,
        &app_grid_btn,
        &app_sheet_revealer,
        &app_sheet_wrap,
        &app_grid_icon,
        &wrap,
        &input,
        app_sheet_built.clone(),
        dismiss_app_sheet,
    );
    if touch_dismiss_enabled() {
        connect_touch_dismiss(&outer, &input_scroller, &win);
    }

    wire_input_layout_behavior(&input_scroller, &input);
    wire_enter_submit_behavior(&input);

    let should_grab_focus = desktop_like || !matches!(
        std::env::var("ATOMOS_OVERVIEW_CHAT_UI_LAYER").as_deref(),
        Ok("bottom" | "background")
    );

    if should_grab_focus {
        let input_focus = input.clone();
        win.connect_map(move |_w| {
            let input_focus = input_focus.clone();
            glib::idle_add_local_once(move || {
                input_focus.grab_focus();
            });
        });
    }

    crate::overlay::apply_translucent_toplevel_compositor_hint(&win);
    win.present();
    startup_trace("present:after");
}

/// Building the app grid runs `gio::AppInfo::all()` on the GTK main thread.
/// On the phone that can block touch for hundreds of ms (or wedge on a broken
/// `.desktop`), which feels like a frozen launcher — unrelated to "many apps".
/// Defer to idle and show a placeholder so the sheet is not an empty panel.
fn schedule_app_grid_build(
    app_sheet_wrap: &gtk::Box,
    app_sheet_built: Rc<Cell<bool>>,
    on_tile_launch: Rc<dyn Fn()>,
) {
    if app_sheet_built.get() {
        return;
    }
    let loading = gtk::Label::new(Some("Loading apps…"));
    loading.add_css_class("atomos-app-grid-loading");
    loading.set_halign(gtk::Align::Center);
    loading.set_valign(gtk::Align::Center);
    loading.set_vexpand(true);
    app_sheet_wrap.append(&loading);

    let wrap = app_sheet_wrap.clone();
    let built = app_sheet_built;
    glib::idle_add_local_once(move || {
        if built.get() {
            return;
        }
        eprintln!("atomos-overview-chat-ui: app-grid building on idle");
        let app_sheet = build_app_grid_sheet(move || on_tile_launch());
        while let Some(child) = wrap.first_child() {
            wrap.remove(&child);
        }
        wrap.append(&app_sheet);
        built.set(true);
        eprintln!("atomos-overview-chat-ui: app-grid build complete");
    });
}

fn connect_dock_toggle(
    win: &adw::ApplicationWindow,
    app_grid_btn: &gtk::Button,
    app_sheet_revealer: &gtk::Revealer,
    app_sheet_wrap: &gtk::Box,
    app_grid_icon: &gtk::Image,
    wrap: &gtk::Box,
    input: &gtk::TextView,
    app_sheet_built: Rc<Cell<bool>>,
    dismiss_app_sheet: Rc<dyn Fn()>,
) {
    let app_sheet_revealer_for_btn = app_sheet_revealer.clone();
    let input_for_app_toggle = input.clone();
    let wrap_for_app_toggle = wrap.clone();
    let app_grid_icon_for_toggle = app_grid_icon.clone();
    let win_for_click = win.clone();
    let app_sheet_wrap_for_toggle = app_sheet_wrap.clone();
    let app_sheet_built_for_toggle = app_sheet_built.clone();
    let dismiss_for_schedule = dismiss_app_sheet;

    app_grid_btn.connect_clicked(move |_btn| {
        let next = !app_sheet_revealer_for_btn.reveals_child();
        eprintln!("atomos-overview-chat-ui: app-sheet toggled={next}");
        app_sheet_revealer_for_btn.set_reveal_child(next);
        if next && !app_sheet_built_for_toggle.get() {
            schedule_app_grid_build(
                &app_sheet_wrap_for_toggle,
                app_sheet_built_for_toggle.clone(),
                dismiss_for_schedule.clone(),
            );
        }
        if next {
            app_grid_icon_for_toggle.set_icon_name(Some("window-close-symbolic"));
            wrap_for_app_toggle.set_visible(false);
            // Opening the app sheet should dismiss OSK if the input had focus.
            adw::prelude::GtkWindowExt::set_focus(&win_for_click, Option::<&gtk::Widget>::None);
        } else {
            app_grid_icon_for_toggle.set_icon_name(Some("view-app-grid-symbolic"));
            wrap_for_app_toggle.set_visible(true);
        }
        if !next {
            input_for_app_toggle.grab_focus();
        }
    });
}

fn connect_touch_dismiss(
    outer: &gtk::Box,
    input_scroller: &gtk::ScrolledWindow,
    win: &adw::ApplicationWindow,
) {
    // Optional: dismiss OSK when tapping outside the text input on touch devices.
    // Some target GTK/libadwaita combinations can misbehave in gesture callbacks.
    let dismiss_focus = gtk::GestureClick::new();
    dismiss_focus.set_button(0);
    dismiss_focus.set_exclusive(false);
    dismiss_focus.set_propagation_phase(gtk::PropagationPhase::Bubble);
    let input_scroller_for_dismiss = input_scroller.clone();
    let outer_for_dismiss = outer.clone();
    let win_for_dismiss = win.clone();
    dismiss_focus.connect_pressed(move |_gesture, _n_press, x, y| {
        let Some(bounds) = input_scroller_for_dismiss.compute_bounds(&outer_for_dismiss) else {
            return;
        };
        let x0 = f64::from(bounds.x());
        let y0 = f64::from(bounds.y());
        let x1 = x0 + f64::from(bounds.width());
        let y1 = y0 + f64::from(bounds.height());
        let inside_input = x >= x0 && x <= x1 && y >= y0 && y <= y1;
        if !inside_input {
            adw::prelude::GtkWindowExt::set_focus(&win_for_dismiss, Option::<&gtk::Widget>::None);
        }
    });
    outer.add_controller(dismiss_focus);
}
