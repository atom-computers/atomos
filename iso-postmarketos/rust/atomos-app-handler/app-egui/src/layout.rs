//! Pure layout helpers for the app-switcher overlay.
//!
//! Extracted so the geometry the preview and the GTK device binary share —
//! card placement, bottom-edge handle bounds, animation easing — can be
//! covered by plain unit tests without an eframe window or a Wayland
//! compositor in the loop.

use atomos_app_handler::OverlayState;

/// A laid-out card rect in viewport-local coordinates. `opacity` carries the
/// animation curve so the front-ends don't have to re-derive it; both the
/// egui and GTK renderers can multiply their fills by this value.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct CardRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub opacity: f32,
}

/// Horizontal padding between cards.
pub const CARD_GAP_PX: f32 = 16.0;
/// Outer margin from the viewport edges.
pub const CARD_MARGIN_PX: f32 = 24.0;
/// Card aspect ratio (height : width). Chosen to read as "portrait phone
/// thumbnail" even though we don't ship thumbnails yet.
pub const CARD_ASPECT: f32 = 1.5;
/// Cap on card width so a single-toplevel session doesn't blow up the card
/// into a tablet-sized rect.
pub const CARD_MAX_WIDTH_PX: f32 = 320.0;
/// Cards never shrink below this width; they get horizontally scrollable
/// when the row gets crowded.
pub const CARD_MIN_WIDTH_PX: f32 = 200.0;

/// Animation progress in `[0.0, 1.0]` for the given overlay state. The
/// preview / GTK renderer multiplies translation and opacity by this curve.
pub fn overlay_progress(state: OverlayState) -> f32 {
    match state {
        OverlayState::Closed => 0.0,
        OverlayState::Open => 1.0,
        OverlayState::Opening { progress } => progress.clamp(0.0, 1.0),
        OverlayState::Closing { progress } => 1.0 - progress.clamp(0.0, 1.0),
    }
}

/// Returns the bottom-edge handle rect where the swipe-up gesture is
/// captured. Pure helper so both the egui preview and the GTK linux module
/// agree on the touch target; paint details live in the core `handle` module.
pub fn bottom_handle_rect(viewport_w: f32, viewport_h: f32, handle_height_px: i32) -> CardRect {
    let h = handle_height_px.max(1) as f32;
    CardRect {
        x: 0.0,
        y: (viewport_h - h).max(0.0),
        width: viewport_w.max(0.0),
        height: h.min(viewport_h.max(0.0)),
        opacity: 1.0,
    }
}

/// Lay out the card row inside the viewport.
///
/// - Cards are sized to fit `n` columns within `[CARD_MIN_WIDTH_PX,
///   CARD_MAX_WIDTH_PX]`, falling back to scrollable overflow at the min.
/// - Vertical centering, with the `anim_progress` driving the slide-in from
///   the bottom: at `progress=0` cards sit a full card-height below the
///   final position; at `progress=1` they're centered.
/// - `opacity = progress` for all cards.
pub fn lay_out_cards(
    card_count: usize,
    viewport_w: f32,
    viewport_h: f32,
    anim_progress: f32,
) -> Vec<CardRect> {
    if card_count == 0
        || !viewport_w.is_finite()
        || !viewport_h.is_finite()
        || viewport_w <= 2.0 * CARD_MARGIN_PX
        || viewport_h <= 2.0 * CARD_MARGIN_PX
    {
        return Vec::new();
    }

    let usable_w = (viewport_w - 2.0 * CARD_MARGIN_PX).max(0.0);
    let usable_h = (viewport_h - 2.0 * CARD_MARGIN_PX).max(0.0);

    let n = card_count as f32;
    let total_gap = CARD_GAP_PX * (n - 1.0).max(0.0);
    let raw_card_w = ((usable_w - total_gap) / n).max(0.0);
    let card_w = raw_card_w.clamp(CARD_MIN_WIDTH_PX, CARD_MAX_WIDTH_PX);
    let card_h = (card_w * CARD_ASPECT).min(usable_h).max(0.0);

    let row_w = card_w * n + total_gap;
    let start_x = if row_w <= usable_w {
        CARD_MARGIN_PX + (usable_w - row_w) * 0.5
    } else {
        // Overflow case: left-align so a horizontal scroll container picks
        // up the row from x = CARD_MARGIN_PX.
        CARD_MARGIN_PX
    };
    let anim = anim_progress.clamp(0.0, 1.0);
    let center_y = CARD_MARGIN_PX + (usable_h - card_h) * 0.5;
    let slide_in_offset = card_h * (1.0 - anim);
    let y = center_y + slide_in_offset;

    let mut out = Vec::with_capacity(card_count);
    for i in 0..card_count {
        let x = start_x + (card_w + CARD_GAP_PX) * (i as f32);
        out.push(CardRect {
            x,
            y,
            width: card_w,
            height: card_h,
            opacity: anim,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn progress_curve_endpoints() {
        assert_eq!(overlay_progress(OverlayState::Closed), 0.0);
        assert_eq!(overlay_progress(OverlayState::Open), 1.0);
        assert_eq!(
            overlay_progress(OverlayState::Opening { progress: 0.0 }),
            0.0
        );
        assert_eq!(
            overlay_progress(OverlayState::Opening { progress: 1.0 }),
            1.0
        );
        assert_eq!(
            overlay_progress(OverlayState::Closing { progress: 0.0 }),
            1.0
        );
        assert_eq!(
            overlay_progress(OverlayState::Closing { progress: 1.0 }),
            0.0
        );
    }

    #[test]
    fn progress_curve_monotone_during_opening() {
        let a = overlay_progress(OverlayState::Opening { progress: 0.2 });
        let b = overlay_progress(OverlayState::Opening { progress: 0.7 });
        assert!(a < b);
    }

    #[test]
    fn bottom_handle_rect_pins_to_bottom_edge() {
        let r = bottom_handle_rect(420.0, 820.0, 24);
        assert_eq!(r.x, 0.0);
        assert_eq!(r.width, 420.0);
        assert_eq!(r.height, 24.0);
        assert!((r.y - (820.0 - 24.0)).abs() < f32::EPSILON);
    }

    #[test]
    fn bottom_handle_rect_floors_height_to_one_px() {
        let r = bottom_handle_rect(420.0, 820.0, 0);
        assert_eq!(r.height, 1.0);
        let r = bottom_handle_rect(420.0, 820.0, -50);
        assert_eq!(r.height, 1.0);
    }

    #[test]
    fn empty_card_count_returns_empty() {
        assert!(lay_out_cards(0, 420.0, 820.0, 1.0).is_empty());
    }

    #[test]
    fn degenerate_viewport_returns_empty() {
        assert!(lay_out_cards(3, 0.0, 820.0, 1.0).is_empty());
        assert!(lay_out_cards(3, 420.0, 0.0, 1.0).is_empty());
        assert!(lay_out_cards(3, f32::NAN, 820.0, 1.0).is_empty());
        assert!(lay_out_cards(3, 10.0, 820.0, 1.0).is_empty(),
            "viewport too narrow for margins must return empty");
    }

    #[test]
    fn single_card_centered_horizontally() {
        let rects = lay_out_cards(1, 600.0, 800.0, 1.0);
        assert_eq!(rects.len(), 1);
        let r = rects[0];
        let center = r.x + r.width * 0.5;
        assert!(
            (center - 300.0).abs() < 1.0,
            "single card should be centered at viewport mid; got x={} w={} center={}",
            r.x,
            r.width,
            center,
        );
    }

    #[test]
    fn multiple_cards_have_uniform_gap_and_height() {
        let rects = lay_out_cards(3, 1200.0, 800.0, 1.0);
        assert_eq!(rects.len(), 3);
        let g1 = rects[1].x - (rects[0].x + rects[0].width);
        let g2 = rects[2].x - (rects[1].x + rects[1].width);
        assert!((g1 - CARD_GAP_PX).abs() < 0.5);
        assert!((g2 - CARD_GAP_PX).abs() < 0.5);
        // Same height for every card.
        assert!((rects[0].height - rects[1].height).abs() < f32::EPSILON);
        assert!((rects[1].height - rects[2].height).abs() < f32::EPSILON);
    }

    #[test]
    fn card_width_respects_min_and_max() {
        // Huge viewport with a single card: cap at CARD_MAX_WIDTH_PX.
        let rects = lay_out_cards(1, 4000.0, 2000.0, 1.0);
        assert!(rects[0].width <= CARD_MAX_WIDTH_PX + f32::EPSILON);
        // Many cards in a tight viewport: each card is at least CARD_MIN_WIDTH_PX.
        let rects = lay_out_cards(6, 400.0, 800.0, 1.0);
        for r in &rects {
            assert!(r.width >= CARD_MIN_WIDTH_PX - f32::EPSILON);
        }
    }

    #[test]
    fn opacity_tracks_anim_progress() {
        let rects = lay_out_cards(3, 1000.0, 800.0, 0.25);
        for r in &rects {
            assert!((r.opacity - 0.25).abs() < f32::EPSILON);
        }
    }

    #[test]
    fn cards_slide_up_into_view_as_progress_grows() {
        let half_y = lay_out_cards(2, 1000.0, 800.0, 0.5)[0].y;
        let full_y = lay_out_cards(2, 1000.0, 800.0, 1.0)[0].y;
        // At full progress cards sit higher (smaller y) than mid-progress.
        assert!(full_y < half_y, "cards must rise as progress grows");
    }
}
