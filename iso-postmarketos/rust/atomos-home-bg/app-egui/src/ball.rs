//! Pure bouncing-ball physics — ported from the JS animation in
//! `iso-postmarketos/data/atomos-home-bg/index.html` so the egui preview
//! shows the same motion a WebKitGTK webview would.
//!
//! Deliberately side-effect-free: the eframe app wires this into its update
//! loop, and the unit tests below pin the constants + reflection rules to
//! the same numbers the HTML uses.

/// Maximum dt passed to `step`. Matches the HTML clamp of 0.05s so a very
/// long frame (e.g. a stalled preview window) does not teleport the ball
/// across the viewport.
pub const MAX_DT_SECS: f32 = 0.05;

/// Starting radius in CSS pixels, matching the HTML placeholder.
pub const INITIAL_RADIUS: f32 = 56.0;

/// Ball physics + color state. All values in logical pixels (egui points).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BallState {
    pub x: f32,
    pub y: f32,
    pub r: f32,
    pub vx: f32,
    pub vy: f32,
    /// Hue in degrees, [0, 360).
    pub hue: f32,
}

impl BallState {
    /// Initial state aligned with the placeholder HTML defaults.
    pub const fn initial() -> Self {
        Self {
            x: 120.0,
            y: 120.0,
            r: INITIAL_RADIUS,
            vx: 220.0,
            vy: 180.0,
            hue: 200.0,
        }
    }
}

impl Default for BallState {
    fn default() -> Self {
        Self::initial()
    }
}

/// Advance ball state by `dt` seconds within a rectangle of size
/// `(width, height)`. Reflects off the four edges and rotates the hue.
pub fn step(mut state: BallState, dt_secs: f32, width: f32, height: f32) -> BallState {
    let dt = dt_secs.clamp(0.0, MAX_DT_SECS);

    state.x += state.vx * dt;
    state.y += state.vy * dt;

    if width > 2.0 * state.r {
        if state.x - state.r < 0.0 {
            state.x = state.r;
            state.vx = state.vx.abs();
        } else if state.x + state.r > width {
            state.x = width - state.r;
            state.vx = -state.vx.abs();
        }
    } else {
        state.x = width * 0.5;
        state.vx = 0.0;
    }

    if height > 2.0 * state.r {
        if state.y - state.r < 0.0 {
            state.y = state.r;
            state.vy = state.vy.abs();
        } else if state.y + state.r > height {
            state.y = height - state.r;
            state.vy = -state.vy.abs();
        }
    } else {
        state.y = height * 0.5;
        state.vy = 0.0;
    }

    state.hue = (state.hue + dt * 40.0).rem_euclid(360.0);

    state
}

#[cfg(test)]
mod tests {
    use super::*;

    fn box_(w: f32, h: f32) -> (f32, f32) {
        (w, h)
    }

    #[test]
    fn initial_state_matches_html_placeholder() {
        let b = BallState::initial();
        assert_eq!(b.x, 120.0);
        assert_eq!(b.y, 120.0);
        assert_eq!(b.r, 56.0);
        assert_eq!(b.vx, 220.0);
        assert_eq!(b.vy, 180.0);
        assert_eq!(b.hue, 200.0);
    }

    #[test]
    fn step_advances_position_linearly_inside_bounds() {
        let (w, h) = box_(1000.0, 1000.0);
        let b = step(BallState::initial(), 0.01, w, h);
        assert!((b.x - (120.0 + 220.0 * 0.01)).abs() < 1e-4);
        assert!((b.y - (120.0 + 180.0 * 0.01)).abs() < 1e-4);
    }

    #[test]
    fn step_clamps_dt_to_prevent_teleports() {
        let (w, h) = box_(10_000.0, 10_000.0);
        let a = step(BallState::initial(), 10.0, w, h);
        let b = step(BallState::initial(), MAX_DT_SECS, w, h);
        assert!((a.x - b.x).abs() < 1e-4);
        assert!((a.y - b.y).abs() < 1e-4);
    }

    #[test]
    fn step_reflects_off_right_edge() {
        let (w, h) = box_(200.0, 400.0);
        let mut state = BallState::initial();
        state.x = w - INITIAL_RADIUS - 1.0;
        state.vx = 1000.0;
        let stepped = step(state, 0.05, w, h);
        assert!(stepped.vx < 0.0);
        assert!(stepped.x + stepped.r <= w + 1e-3);
    }

    #[test]
    fn step_reflects_off_left_edge() {
        let (w, h) = box_(400.0, 400.0);
        let mut state = BallState::initial();
        state.x = INITIAL_RADIUS + 1.0;
        state.vx = -1000.0;
        let stepped = step(state, 0.05, w, h);
        assert!(stepped.vx > 0.0);
        assert!(stepped.x - stepped.r >= -1e-3);
    }

    #[test]
    fn step_reflects_off_top_and_bottom() {
        let (w, h) = box_(400.0, 300.0);
        let mut top_state = BallState::initial();
        top_state.y = INITIAL_RADIUS + 1.0;
        top_state.vy = -1000.0;
        let s = step(top_state, 0.05, w, h);
        assert!(s.vy > 0.0);

        let mut bot_state = BallState::initial();
        bot_state.y = h - INITIAL_RADIUS - 1.0;
        bot_state.vy = 1000.0;
        let s = step(bot_state, 0.05, w, h);
        assert!(s.vy < 0.0);
    }

    #[test]
    fn step_pins_to_center_when_viewport_too_narrow() {
        let (w, h) = box_(10.0, 1000.0);
        let stepped = step(BallState::initial(), 0.01, w, h);
        assert_eq!(stepped.x, w * 0.5);
        assert_eq!(stepped.vx, 0.0);
    }

    #[test]
    fn step_rotates_hue_at_40_deg_per_second() {
        let start = BallState::initial();
        let after_1s = step(start, MAX_DT_SECS, 1000.0, 1000.0);
        let expected = (start.hue + 2.0).rem_euclid(360.0);
        assert!((after_1s.hue - expected).abs() < 1e-3);
    }

    #[test]
    fn step_wraps_hue_modulo_360() {
        let mut state = BallState::initial();
        state.hue = 359.9;
        let stepped = step(state, MAX_DT_SECS, 1000.0, 1000.0);
        assert!(stepped.hue < 360.0);
        assert!(stepped.hue >= 0.0);
    }

    #[test]
    fn step_with_zero_dt_is_identity_on_position() {
        let start = BallState::initial();
        let stepped = step(start, 0.0, 1000.0, 1000.0);
        assert_eq!(stepped.x, start.x);
        assert_eq!(stepped.y, start.y);
        assert_eq!(stepped.hue, start.hue);
    }
}
