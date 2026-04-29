//! Pure layout helpers for the chat-strip overlay.
//!
//! Extracted so the sizing policy (the thing that previously broke when the
//! strip was invisible) is covered by plain unit tests rather than relying
//! on a live eframe window.

/// Compute how tall the bottom chat-strip should be given the window height.
pub fn chat_strip_height(viewport_height: f32) -> f32 {
    if viewport_height.is_nan() || viewport_height <= 0.0 {
        return 0.0;
    }
    (viewport_height * 0.35).min(160.0).max(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_never_exceeds_160_px_on_tall_windows() {
        assert_eq!(chat_strip_height(820.0), 160.0);
        assert_eq!(chat_strip_height(10_000.0), 160.0);
    }

    #[test]
    fn strip_caps_at_35_percent_on_short_windows() {
        assert!((chat_strip_height(300.0) - 105.0).abs() < 1e-4);
        assert!((chat_strip_height(400.0) - 140.0).abs() < 1e-4);
    }

    #[test]
    fn strip_zero_on_degenerate_viewport() {
        assert_eq!(chat_strip_height(0.0), 0.0);
        assert_eq!(chat_strip_height(-10.0), 0.0);
        assert_eq!(chat_strip_height(f32::NAN), 0.0);
        assert_eq!(chat_strip_height(f32::INFINITY), 160.0);
    }

    #[test]
    fn strip_nonzero_for_any_realistic_phone_viewport() {
        for h in [720.0_f32, 800.0, 900.0, 1080.0] {
            assert_eq!(chat_strip_height(h), 160.0, "failed for viewport_h={h}");
        }
        assert!(820.0 - chat_strip_height(820.0) > 600.0);
    }
}
