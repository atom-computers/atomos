//! Bottom-edge swipe handle layout and paint contract.
//!
//! Kept free of GTK / Cairo so geometry, colors, and phosh parity can be
//! unit-tested on any host. The GTK binary maps [`HandlePaintPlan`] onto a
//! Cairo context; the egui preview uses the same numbers for fills.

/// Width of phosh `input-powerbar-symbolic.svg`.
pub const PILL_WIDTH_PX: f64 = 150.0;
/// Visual height of the pill path inside phosh's 15 px home-bar box.
pub const PILL_HEIGHT_PX: f64 = 4.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rgba {
    pub r: f64,
    pub g: f64,
    pub b: f64,
    pub a: f64,
}

/// Subtle strip scrim so the handle reads over light and dark apps.
pub const STRIP_SCRIM: Rgba = Rgba {
    r: 0.0,
    g: 0.0,
    b: 0.0,
    a: 0.22,
};

/// Centered powerbar pill fill.
pub const PILL_FILL: Rgba = Rgba {
    r: 1.0,
    g: 1.0,
    b: 1.0,
    a: 0.58,
};

/// Opt-in maintainer tint (`ATOMOS_APP_HANDLER_DEBUG_TINT=1`).
pub const DEBUG_TINT: Rgba = Rgba {
    r: 1.0,
    g: 0.0,
    b: 0.0,
    a: 0.35,
};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RectPx {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct HandlePaintPlan {
    pub strip: RectPx,
    pub pill: RectPx,
}

impl Rgba {
    /// Straight-alpha `[r, g, b, a]` in 0..=255 for UI front-ends.
    pub fn to_u8_components(self) -> [u8; 4] {
        [
            (self.r.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.g.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.b.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.a.clamp(0.0, 1.0) * 255.0).round() as u8,
        ]
    }

    /// Premultiplied RGBA for egui `Color32::from_rgba_premultiplied`.
    pub fn to_premultiplied_u8(self) -> [u8; 4] {
        let a = self.a.clamp(0.0, 1.0);
        [
            (self.r * a * 255.0).round() as u8,
            (self.g * a * 255.0).round() as u8,
            (self.b * a * 255.0).round() as u8,
            (a * 255.0).round() as u8,
        ]
    }
}

/// Layout the full-width strip and centered pill for a mapped handle surface.
pub fn layout_handle_paint(strip_w: f64, strip_h: f64) -> Option<HandlePaintPlan> {
    if !strip_w.is_finite() || !strip_h.is_finite() || strip_w <= 0.0 || strip_h <= 0.0 {
        return None;
    }

    let pill_w = PILL_WIDTH_PX.min(strip_w);
    let pill_h = PILL_HEIGHT_PX.min(strip_h);
    Some(HandlePaintPlan {
        strip: RectPx {
            x: 0.0,
            y: 0.0,
            width: strip_w,
            height: strip_h,
        },
        pill: RectPx {
            x: (strip_w - pill_w) / 2.0,
            y: (strip_h - pill_h) / 2.0,
            width: pill_w,
            height: pill_h,
        },
    })
}

/// Corner radius for the stadium-shaped pill path.
pub fn capsule_corner_radius(pill_w: f64, pill_h: f64) -> f64 {
    (pill_h / 2.0).min(pill_w / 2.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pill_width_matches_phosh_powerbar_svg() {
        assert_eq!(PILL_WIDTH_PX, 150.0);
        assert_eq!(PILL_HEIGHT_PX, 4.0);
    }

    #[test]
    fn layout_rejects_non_positive_and_non_finite_inputs() {
        assert!(layout_handle_paint(0.0, 24.0).is_none());
        assert!(layout_handle_paint(420.0, 0.0).is_none());
        assert!(layout_handle_paint(f64::NAN, 24.0).is_none());
        assert!(layout_handle_paint(420.0, f64::INFINITY).is_none());
    }

    #[test]
    fn layout_centers_pill_in_default_phone_strip() {
        let plan = layout_handle_paint(420.0, 24.0).expect("valid strip");
        assert_eq!(plan.strip.width, 420.0);
        assert_eq!(plan.strip.height, 24.0);
        assert_eq!(plan.pill.width, 150.0);
        assert_eq!(plan.pill.height, 4.0);
        assert!((plan.pill.x - 135.0).abs() < f64::EPSILON);
        assert!((plan.pill.y - 10.0).abs() < f64::EPSILON);
    }

    #[test]
    fn layout_clamps_pill_on_narrow_strips() {
        let plan = layout_handle_paint(80.0, 8.0).expect("valid strip");
        assert_eq!(plan.pill.width, 80.0);
        assert_eq!(plan.pill.height, 4.0);
        assert!((plan.pill.x - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn layout_clamps_pill_height_on_short_strips() {
        let plan = layout_handle_paint(420.0, 2.0).expect("valid strip");
        assert_eq!(plan.pill.height, 2.0);
        assert!((plan.pill.y - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn capsule_corner_radius_is_half_height_for_wide_pills() {
        assert!((capsule_corner_radius(150.0, 4.0) - 2.0).abs() < f64::EPSILON);
    }

    #[test]
    fn capsule_corner_radius_is_half_width_for_tall_pills() {
        assert!((capsule_corner_radius(6.0, 20.0) - 3.0).abs() < f64::EPSILON);
    }

    #[test]
    fn strip_scrim_and_pill_fill_are_visible_not_transparent() {
        assert!(STRIP_SCRIM.a > 0.0);
        assert!(PILL_FILL.a > 0.0);
        assert!(PILL_FILL.r > 0.0);
    }

    #[test]
    fn premultiplied_components_match_egui_preview_values() {
        assert_eq!(STRIP_SCRIM.to_premultiplied_u8(), [0, 0, 0, 56]);
        assert_eq!(PILL_FILL.to_premultiplied_u8(), [148, 148, 148, 148]);
    }

    #[test]
    fn debug_tint_is_distinct_from_production_scrim() {
        assert_ne!(DEBUG_TINT, STRIP_SCRIM);
        assert!(DEBUG_TINT.r > STRIP_SCRIM.r);
    }
}
