//! Drag gesture thresholds and evaluation.
//!
//! Pure functions for deciding whether a drag gesture should trigger a
//! fold or unfold transition. Mirrors the thresholds in Phosh home.c but
//! is unit-testable on any host.

/// Minimum vertical drag distance (px) to trigger an unfold from
/// the folded home bar. Matches Phosh's edge-swipe threshold.
pub const UNFOLD_THRESHOLD_PX: f64 = 30.0;

/// Maximum horizontal deviation (px) before a drag is rejected
/// as not-vertical-enough.
pub const SWIPE_SLOP_PX: f64 = 8.0;

/// Result of evaluating a drag gesture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DragOutcome {
    /// The drag did not exceed thresholds — do nothing.
    Ignore,
    /// The drag exceeded the vertical threshold — unfold the home surface.
    Unfold,
}

/// Evaluate whether a drag delta should trigger an unfold.
///
/// `dy` is the vertical displacement in pixels. Positive values mean
/// upward (toward the top of the screen). A drag is interpreted as an
/// unfold gesture when `dy >= UNFOLD_THRESHOLD_PX`.
pub fn evaluate_drag(dy: f64, dx: f64) -> DragOutcome {
    if dy.is_nan() || dx.is_nan() || dy.is_infinite() || dx.is_infinite() {
        return DragOutcome::Ignore;
    }
    if dy >= UNFOLD_THRESHOLD_PX && dx.abs() <= SWIPE_SLOP_PX * 3.0 {
        return DragOutcome::Unfold;
    }
    DragOutcome::Ignore
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn vertical_swipe_up_triggers_unfold() {
        assert_eq!(evaluate_drag(50.0, 0.0), DragOutcome::Unfold);
    }

    #[test]
    fn small_swipe_ignored() {
        assert_eq!(evaluate_drag(10.0, 0.0), DragOutcome::Ignore);
    }

    #[test]
    fn diagonal_swipe_ignored() {
        assert_eq!(evaluate_drag(50.0, 100.0), DragOutcome::Ignore);
    }

    #[test]
    fn downward_swipe_ignored() {
        assert_eq!(evaluate_drag(-50.0, 0.0), DragOutcome::Ignore);
    }

    #[test]
    fn nan_swipe_ignored() {
        assert_eq!(evaluate_drag(f64::NAN, 0.0), DragOutcome::Ignore);
        assert_eq!(evaluate_drag(50.0, f64::NAN), DragOutcome::Ignore);
    }

    #[test]
    fn infinite_swipe_ignored() {
        assert_eq!(evaluate_drag(f64::INFINITY, 0.0), DragOutcome::Ignore);
    }

    #[test]
    fn threshold_boundary() {
        assert_eq!(evaluate_drag(UNFOLD_THRESHOLD_PX, 0.0), DragOutcome::Unfold);
        assert_eq!(evaluate_drag(UNFOLD_THRESHOLD_PX - 0.1, 0.0), DragOutcome::Ignore);
    }
}