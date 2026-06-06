//! Wayland input/opaque region helpers for layer-shell surfaces.
//!
//! GTK widget `can_target(false)` only affects in-process hit testing. The
//! compositor still delivers pointer events to the full gdk::Surface unless
//! `gdk_surface_set_input_region` is narrowed. The gesture fade overlay is
//! full-screen (for implicit-grab survival during upward drags) but must pass
//! clicks through to the foreground app everywhere except the bottom handle
//! strip.

use gtk::gdk::prelude::*;
use gtk::prelude::*;
use gtk::cairo::{RectangleInt, Region};

fn log_surface_op(window: &gtk::ApplicationWindow, msg: &str) {
    let title = window.title().unwrap_or_default();
    eprintln!("atomos-app-handler: {title}: {msg}");
}

fn defer_until_surface<F>(window: &gtk::ApplicationWindow, label: &str, apply: F)
where
    F: Fn(&gtk::ApplicationWindow) -> bool + Copy + 'static,
{
    if apply(window) {
        return;
    }
    let label = label.to_string();
    window.connect_map(move |w| {
        if !apply(w) {
            log_surface_op(
                w,
                &format!("map fired without gdk::Surface; skipping {label}"),
            );
        }
    });
}

fn set_input_region_empty(window: &gtk::ApplicationWindow) -> bool {
    let Some(surface) = window.surface() else {
        return false;
    };
    let region = Region::create();
    surface.set_input_region(&region);
    log_surface_op(window, "input region cleared (non-interactive)");
    true
}

fn set_input_region_bottom_strip(
    window: &gtk::ApplicationWindow,
    handle_height_px: i32,
) -> bool {
    let Some(surface) = window.surface() else {
        return false;
    };
    let alloc = window.allocation();
    let width = alloc.width();
    let height = alloc.height();
    if width <= 0 || height <= 0 || handle_height_px <= 0 {
        return false;
    }
    let y = height.saturating_sub(handle_height_px);
    let rect = RectangleInt::new(0, y, width, handle_height_px);
    let region = Region::create_rectangle(&rect);
    surface.set_input_region(&region);
    log_surface_op(
        window,
        &format!(
            "input region set to bottom strip y={y} width={width} height={handle_height_px}"
        ),
    );
    true
}

fn set_opaque_region_empty(window: &gtk::ApplicationWindow) -> bool {
    let Some(surface) = window.surface() else {
        return false;
    };
    let region = Region::create();
    surface.set_opaque_region(Some(&region));
    log_surface_op(window, "opaque region cleared (translucent hint)");
    true
}

/// Clear the input region so pointer/touch events fall through this surface.
pub fn apply_non_interactive_input_region(
    window: &gtk::ApplicationWindow,
    canvas: &gtk::DrawingArea,
) {
    let w = window.clone();
    canvas.connect_resize(move |_, _, _| {
        if let Some(surface) = w.surface() {
            let region = Region::create();
            surface.set_input_region(&region);
            eprintln!("atomos-app-handler: non-interactive input region cleared via canvas resize");
        }
    });

    defer_until_surface(window, "non-interactive input region", set_input_region_empty);
}

/// Restrict input to the bottom `handle_height_px` strip so the rest of the
/// full-screen overlay is click-through to the foreground app.
pub fn apply_bottom_strip_input_region(
    window: &gtk::ApplicationWindow,
    canvas: &gtk::DrawingArea,
    handle_height_px: i32,
) {
    let w = window.clone();
    canvas.connect_resize(move |_, width, height| {
        let y = height.saturating_sub(handle_height_px);
        let rect = RectangleInt::new(0, y, width, handle_height_px);
        let region = Region::create_rectangle(&rect);
        if let Some(surface) = w.surface() {
            surface.set_input_region(&region);
            eprintln!(
                "atomos-app-handler: input region updated via canvas resize y={y} width={width} height={handle_height_px}"
            );
        }
    });

    defer_until_surface(window, "bottom strip input region", move |win| {
        set_input_region_bottom_strip(win, handle_height_px)
    });
}

/// Dynamically set the input region of the window to a bottom rectangle of the specified height.
pub fn set_input_region_height(window: &gtk::ApplicationWindow, height_px: i32) {
    if let Some(surface) = window.surface() {
        let alloc = window.allocation();
        let width = alloc.width();
        let height = alloc.height();
        if width > 0 && height > 0 && height_px > 0 {
            let y = height.saturating_sub(height_px);
            let rect = RectangleInt::new(0, y, width, height_px);
            let region = Region::create_rectangle(&rect);
            surface.set_input_region(&region);
            eprintln!("atomos-app-handler: input region updated dynamically to height={height_px}");
        }
    }
}

/// Mark the surface fully translucent so the compositor can blend through
/// to lower layers in the idle (progress=0) state.
pub fn apply_translucent_opaque_hint(window: &gtk::ApplicationWindow) {
    defer_until_surface(window, "translucent opaque hint", set_opaque_region_empty);
}
