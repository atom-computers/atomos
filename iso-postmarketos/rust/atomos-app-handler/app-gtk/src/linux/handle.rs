//! Paint the bottom-edge swipe handle so it is visible over a running app.
//!
//! Two concerns live here:
//!
//!   1. The static visible chrome — a 24 px scrim + capsule "pill" — pinned
//!      to the bottom `strip_height_px` of the canvas. Geometry and colours
//!      come from [`atomos_app_handler::handle`] so the egui preview, the
//!      headless unit tests, and the GTK device build all paint pixel-for-
//!      pixel identical strips.
//!
//!   2. The drag-time backdrop fade — a dark overlay over the foreground app
//!      content rectangle (excluding the top bar and bottom handle insets)
//!      whose alpha is computed by [`atomos_app_handler::handle_drag_progress`]
//!      off the live `GestureDrag` accumulator. The fade surface is full-screen
//!      `Layer::Overlay` (see `build_fade_window` in `linux.rs`) so the
//!      implicit pointer grab survives the entire upward drag.
//!
//! The visible handle chrome is painted on `Layer::Bottom` by
//! `build_handle_strip_window`. The gesture overlay's Wayland input region
//! is narrowed to the bottom strip; taps in the transparent fade area fall
//! through to the app.
//!
//! The closure-passed `get_drag_progress` lets `linux.rs` keep
//! `OverlayController` private to this crate's module tree without forcing a
//! direct dependency from `handle.rs` back onto it.

use atomos_app_handler::handle::{
    capsule_corner_radius, layout_app_content_fade_rect, layout_handle_paint, HandlePaintPlan,
    DEBUG_TINT, PILL_FILL, STRIP_SCRIM,
};
use atomos_app_handler::{BACKDROP_BASE_COLOR_RGB, TOP_BAR_HEIGHT_PX};
use gtk::prelude::*;
use std::f64::consts::PI;

/// Install the draw function for the full-screen handle canvas.
///
/// * `canvas` — the single `DrawingArea` that covers the entire wayland
///   surface (full-screen overlay).
/// * `strip_height_px` — visible bottom strip height in CSS pixels (matches
///   `controller.gestures.handle_height_px`).
/// * `get_drag_progress` — `0.0..=1.0` alpha for the backdrop fade overlay.
///   Read fresh on every redraw; `linux.rs` mutates it from
///   `connect_drag_update` / `connect_drag_end` and calls
///   `canvas.queue_draw()` so the fade follows the finger in real time.
/// * `debug_tint` — when true, paints the strip area in the loud
///   [`DEBUG_TINT`] colour so the hit-region is visible on device. Independent
///   of the fade overlay.
pub fn install_fade_paint<F, F2>(
    canvas: &gtk::DrawingArea,
    handle_height_px: i32,
    get_drag_progress: F,
    get_drag_dy: F2,
) where
    F: Fn() -> f32 + 'static,
    F2: Fn() -> f64 + 'static,
{
    canvas.set_draw_func(move |_area, cr, width, height| {
        paint_backdrop_fade(
            cr,
            width,
            height,
            TOP_BAR_HEIGHT_PX,
            handle_height_px,
            get_drag_progress(),
            get_drag_dy(),
        );
    });
}

pub fn install_handle_paint(
    canvas: &gtk::DrawingArea,
    debug_tint: bool,
) {
    canvas.set_draw_func(move |_area, cr, width, height| {
        if let Some(plan) = layout_handle_paint(width as f64, height as f64) {
            paint_plan(cr, plan, debug_tint);
        }
    });
}

fn paint_backdrop_fade(
    cr: &gtk::cairo::Context,
    width: i32,
    height: i32,
    _top_bar_height_px: i32,
    handle_height_px: i32,
    progress: f32,
    drag_dy: f64,
) {
    if width <= 0 || height <= 0 {
        return;
    }
    let alpha = progress.clamp(0.0, 1.0) as f64;
    if alpha <= 0.0 {
        return;
    }
    let upward_drag = (-drag_dy).max(0.0);
    let Some(rect) = atomos_app_handler::handle::layout_dynamic_swipe_overlay_rect(
        width as f64,
        height as f64,
        handle_height_px,
        upward_drag,
    ) else {
        return;
    };
    let r = BACKDROP_BASE_COLOR_RGB[0] as f64 / 255.0;
    let g = BACKDROP_BASE_COLOR_RGB[1] as f64 / 255.0;
    let b = BACKDROP_BASE_COLOR_RGB[2] as f64 / 255.0;
    cr.set_source_rgba(r, g, b, alpha);
    cr.rectangle(rect.x, rect.y, rect.width, rect.height);
    let _ = cr.fill();
}

fn paint_plan(cr: &gtk::cairo::Context, plan: HandlePaintPlan, debug_tint: bool) {
    if debug_tint {
        let c = DEBUG_TINT;
        cr.set_source_rgba(c.r, c.g, c.b, c.a);
        let _ = cr.paint();
    } else {
        let c = STRIP_SCRIM;
        cr.set_source_rgba(c.r, c.g, c.b, c.a);
        cr.rectangle(
            plan.strip.x,
            plan.strip.y,
            plan.strip.width,
            plan.strip.height,
        );
        let _ = cr.fill();
    }

    let c = PILL_FILL;
    cr.set_source_rgba(c.r, c.g, c.b, c.a);
    trace_capsule(cr, &plan.pill);
    let _ = cr.fill();
}

fn trace_capsule(cr: &gtk::cairo::Context, pill: &atomos_app_handler::handle::RectPx) {
    let r = capsule_corner_radius(pill.width, pill.height);
    cr.new_path();
    cr.arc(pill.x + r, pill.y + r, r, PI, 3.0 * PI / 2.0);
    cr.arc(pill.x + pill.width - r, pill.y + r, r, 3.0 * PI / 2.0, 0.0);
    cr.arc(
        pill.x + pill.width - r,
        pill.y + pill.height - r,
        r,
        0.0,
        PI / 2.0,
    );
    cr.arc(pill.x + r, pill.y + pill.height - r, r, PI / 2.0, PI);
    cr.close_path();
}
