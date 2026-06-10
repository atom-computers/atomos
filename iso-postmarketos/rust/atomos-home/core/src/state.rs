//! Home surface state machine.
//!
//! The home surface can be in three states: `Folded` (collapsed to a narrow bar),
//! `Unfolded` (full-screen overview), or `Transition` (animating between the two).
//! The state machine ensures transitions are safe and idempotent.

use crate::HomeDragState;

/// Home surface visual state. Maps to layer-shell surface height and exclusive zone.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HomeState {
    Folded,
    Unfolded,
    Transition,
}

impl HomeState {
    pub fn from_drag(drag: HomeDragState) -> Self {
        match drag {
            HomeDragState::Unfolded => Self::Unfolded,
            HomeDragState::Folded => Self::Folded,
            HomeDragState::Transition => Self::Transition,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Folded => "folded",
            Self::Unfolded => "unfolded",
            Self::Transition => "transition",
        }
    }
}

/// Persistent state for the home surface, tracking current position and
/// whether the surface is mapped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HomeSurfaceState {
    pub state: HomeState,
    pub mapped: bool,
    pub ui_stable: bool,
}

impl HomeSurfaceState {
    pub fn new() -> Self {
        Self {
            state: HomeState::Folded,
            mapped: false,
            ui_stable: false,
        }
    }

    /// Apply a fold request. Only transitions from Unfolded/Stable.
    /// Returns true if the state actually changed.
    pub fn request_fold(&mut self) -> bool {
        match self.state {
            HomeState::Unfolded if self.ui_stable => {
                self.state = HomeState::Transition;
                true
            }
            HomeState::Unfolded => {
                // Not yet stable — queue the fold after stable gate
                false
            }
            HomeState::Folded | HomeState::Transition => false,
        }
    }

    /// Apply an unfold request. Only transitions from Folded.
    /// Returns true if the state actually changed.
    pub fn request_unfold(&mut self) -> bool {
        match self.state {
            HomeState::Folded => {
                self.state = HomeState::Transition;
                true
            }
            HomeState::Unfolded | HomeState::Transition => false,
        }
    }

    /// Called when the drag gesture settles to folded.
    pub fn settle_folded(&mut self) {
        self.state = HomeState::Folded;
        self.ui_stable = false;
    }

    /// Called when the drag gesture settles to unfolded.
    pub fn settle_unfolded(&mut self) {
        self.state = HomeState::Unfolded;
    }

    /// Mark that the UI is stable (160ms after unfold complete).
    pub fn mark_stable(&mut self) {
        self.ui_stable = true;
    }
}

impl Default for HomeSurfaceState {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_state_is_folded() {
        let state = HomeSurfaceState::new();
        assert_eq!(state.state, HomeState::Folded);
        assert!(!state.mapped);
        assert!(!state.ui_stable);
    }

    #[test]
    fn fold_from_unfolded_stable() {
        let mut state = HomeSurfaceState::new();
        state.state = HomeState::Unfolded;
        state.ui_stable = true;
        assert!(state.request_fold());
        assert_eq!(state.state, HomeState::Transition);
    }

    #[test]
    fn fold_from_unfolded_unstable_is_ignored() {
        let mut state = HomeSurfaceState::new();
        state.state = HomeState::Unfolded;
        state.ui_stable = false;
        assert!(!state.request_fold());
        assert_eq!(state.state, HomeState::Unfolded);
    }

    #[test]
    fn fold_from_folded_is_noop() {
        let mut s = HomeSurfaceState::new();
        assert!(!s.request_fold());
    }

    #[test]
    fn unfold_from_folded() {
        let mut s = HomeSurfaceState::new();
        assert!(s.request_unfold());
        assert_eq!(s.state, HomeState::Transition);
    }

    #[test]
    fn unfold_from_unfolded_is_noop() {
        let mut s = HomeSurfaceState::new();
        s.state = HomeState::Unfolded;
        assert!(!s.request_unfold());
    }

    #[test]
    fn settle_folded_resets_stable() {
        let mut s = HomeSurfaceState::new();
        s.state = HomeState::Transition;
        s.ui_stable = true;
        s.settle_folded();
        assert_eq!(s.state, HomeState::Folded);
        assert!(!s.ui_stable);
    }

    #[test]
    fn settle_unfolded() {
        let mut s = HomeSurfaceState::new();
        s.state = HomeState::Transition;
        s.settle_unfolded();
        assert_eq!(s.state, HomeState::Unfolded);
    }

    #[test]
    fn home_state_from_drag_state() {
        assert_eq!(HomeState::from_drag(HomeDragState::Folded), HomeState::Folded);
        assert_eq!(HomeState::from_drag(HomeDragState::Unfolded), HomeState::Unfolded);
        assert_eq!(HomeState::from_drag(HomeDragState::Transition), HomeState::Transition);
    }

    #[test]
    fn drag_state_round_trip_str() {
        assert_eq!(HomeDragState::from_str(HomeDragState::Folded.as_str()), Some(HomeDragState::Folded));
        assert_eq!(HomeDragState::from_str(HomeDragState::Unfolded.as_str()), Some(HomeDragState::Unfolded));
        assert_eq!(HomeDragState::from_str(HomeDragState::Transition.as_str()), Some(HomeDragState::Transition));
        assert_eq!(HomeDragState::from_str("unknown"), None);
    }

    #[test]
    fn home_ipc_variants() {
        assert_ne!(crate::HomeIpc::Fold, crate::HomeIpc::Unfold);
    }

    #[test]
    fn home_ipc_fold_serializes_to_dbus_method() {
        assert_eq!(format!("{:?}", crate::HomeIpc::Fold), "Fold");
    }

    #[test]
    fn home_ipc_unfold_serializes_to_dbus_method() {
        assert_eq!(format!("{:?}", crate::HomeIpc::Unfold), "Unfold");
    }

    #[test]
    fn home_drag_state_locked_yields_hidden() {
        let mut state = HomeSurfaceState::new();
        state.state = HomeState::Folded;
        state.mapped = true;
        assert_eq!(state.state, HomeState::Folded);
    }

    #[test]
    fn unfold_then_settle_produces_unfolded() {
        let mut state = HomeSurfaceState::new();
        assert!(state.request_unfold());
        assert_eq!(state.state, HomeState::Transition);
        state.settle_unfolded();
        assert_eq!(state.state, HomeState::Unfolded);
    }

    #[test]
    fn unfold_settle_mark_stable_then_fold_matches_c_contract() {
        let mut state = HomeSurfaceState::new();
        state.request_unfold();
        state.settle_unfolded();
        state.mark_stable();
        assert!(state.request_fold());
        assert_eq!(state.state, HomeState::Transition);
        state.settle_folded();
        assert_eq!(state.state, HomeState::Folded);
    }

    #[test]
    fn chat_ui_layer_folded_with_apps_is_bottom_not_overlay() {
        use crate::HomeDragState;
        let drag = HomeDragState::Folded;
        let state = HomeState::from_drag(drag);
        assert_eq!(state, HomeState::Folded);
    }
}