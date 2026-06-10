//! Pure-logic core for `atomos-home`.
//!
//! Home surface state machine, drag gesture thresholds, and fold/unfold
//! decision logic. No GTK or Wayland dependencies — exhaustively unit-testable
//! on any host.

pub mod drag;
pub mod state;

/// D-Bus well-known name and object path for the home surface service.
pub const HOME_DBUS_NAME: &str = "org.atomos.Home";
pub const HOME_DBUS_PATH: &str = "/org/atomos/Home";

/// Home surface drag state. Mirrors `PhoshDragSurfaceState` and
/// `atomos_lifecycle::HomeDragState`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HomeDragState {
    Folded,
    Unfolded,
    Transition,
}

impl HomeDragState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Folded => "folded",
            Self::Unfolded => "unfolded",
            Self::Transition => "transition",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "folded" => Some(Self::Folded),
            "unolded" | "unfolded" => Some(Self::Unfolded),
            "transition" | "dragged" => Some(Self::Transition),
            _ => None,
        }
    }
}

/// D-Bus IPC commands that external processes can send to the home surface.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HomeIpc {
    Fold,
    Unfold,
}

#[cfg(test)]
mod contract {
    use super::*;

    #[test]
    fn dbus_well_known_name_is_org_atomos_home() {
        assert_eq!(HOME_DBUS_NAME, "org.atomos.Home");
    }

    #[test]
    fn dbus_object_path_is_org_atomos_home() {
        assert_eq!(HOME_DBUS_PATH, "/org/atomos/Home");
    }

    #[test]
    fn dbus_interface_name_equals_well_known_name() {
        assert_eq!(HOME_DBUS_NAME, HOME_DBUS_PATH.trim_start_matches('/').replace('/', "."));
    }

    #[test]
    fn drag_state_folded_serializes_to_dbus_signal_body() {
        assert_eq!(HomeDragState::Folded.as_str(), "folded");
    }

    #[test]
    fn drag_state_unfolded_serializes_to_dbus_signal_body() {
        assert_eq!(HomeDragState::Unfolded.as_str(), "unfolded");
    }

    #[test]
    fn drag_state_transition_serializes_to_dbus_signal_body() {
        assert_eq!(HomeDragState::Transition.as_str(), "transition");
    }

    #[test]
    fn drag_state_from_dbus_signal_body_round_trips() {
        for state in [HomeDragState::Folded, HomeDragState::Unfolded, HomeDragState::Transition] {
            assert_eq!(
                HomeDragState::from_str(state.as_str()),
                Some(state),
                "round-trip failed for {:?}",
                state
            );
        }
    }

    #[test]
    fn drag_state_from_str_rejects_unknown() {
        assert!(HomeDragState::from_str("unknown").is_none());
        assert!(HomeDragState::from_str("").is_none());
        assert!(HomeDragState::from_str("DRAGGING").is_none());
    }

    #[test]
    fn home_ipc_dbus_method_names_match_xml_interface() {
        assert_eq!(format!("{:?}", HomeIpc::Fold), "Fold");
        assert_eq!(format!("{:?}", HomeIpc::Unfold), "Unfold");
    }

    #[test]
    fn home_state_as_str_matches_drag_state_for_stable_states() {
        assert_eq!(state::HomeState::Folded.as_str(), HomeDragState::Folded.as_str());
        assert_eq!(state::HomeState::Unfolded.as_str(), HomeDragState::Unfolded.as_str());
    }
}