//! Paint the bottom-edge swipe handle so it is visible over a running app.
//!
//! Geometry and colors live in the core [`atomos_app_handler::handle`] module;
//! this file only maps a [`HandlePaintPlan`] onto Cairo via GTK.

use atomos_app_handler::handle::{
    capsule_corner_radius, layout_handle_paint, HandlePaintPlan, DEBUG_TINT, PILL_FILL,
    STRIP_SCRIM,
};
use gtk::prelude::*;
use std::f64::consts::PI;

pub fn install_handle_paint(strip: &gtk::DrawingArea, debug_tint: bool) {
    strip.set_draw_func(move |_, cr, width, height| {
        let Some(plan) = layout_handle_paint(width as f64, height as f64) else {
            return;
        };
        paint_plan(cr, plan, debug_tint);
    });
}

fn paint_plan(cr: &gtk::cairo::Context, plan: HandlePaintPlan, debug_tint: bool) {
    if debug_tint {
        let c = DEBUG_TINT;
        cr.set_source_rgba(c.r, c.g, c.b, c.a);
        let _ = cr.paint();
    } else {
        let c = STRIP_SCRIM;
        cr.set_source_rgba(c.r, c.g, c.b, c.a);
        let _ = cr.rectangle(
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
