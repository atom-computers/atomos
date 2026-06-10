//! Session / home-target policy for fold-unfold orchestration.
//!
//! The Rust handler owns fold decisions; the home surface exposes a D-Bus API
//! (`org.atomos.Home`) that maps targets onto fold/unfold state changes.
//!
//! Pure functions here are the contract the GTK binary must follow.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UiMode {
    Idle,
    LauncherOpen,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HomeTarget {
    Folded,
    Unfolded,
}

/// Mirrors `HomeDragState` / `PhoshHomeState` (fold / unfold / transition).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HomeShellState {
    Folded,
    Unfolded,
    Transition,
}

impl HomeShellState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Folded => "folded",
            Self::Unfolded => "unfolded",
            Self::Transition => "transition",
        }
    }
}

/// Legacy alias — prefer `HomeShellState`.
#[deprecated(note = "Use HomeShellState instead")]
pub type PhoshHomeShellState = HomeShellState;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HomeIpc {
    None,
    SetFolded,
    SetUnfolded,
}

/// Legacy alias — prefer `HomeIpc`.
#[deprecated(note = "Use HomeIpc instead")]
pub type PhoshHomeIpc = HomeIpc;

/// Derive whether the home surface should fold or unfold from toplevel count changes.
pub fn derive_home_ipc(prev_count: usize, new_count: usize, ui_mode: UiMode) -> HomeIpc {
    if new_count == 0 && prev_count > 0 {
        return HomeIpc::SetUnfolded;
    }
    if new_count > 0 && prev_count == 0 && !matches!(ui_mode, UiMode::LauncherOpen) {
        return HomeIpc::SetFolded;
    }
    HomeIpc::None
}

/// D-Bus fold/unfold when the Rust launcher sheet opens or closes.
pub fn launcher_home_ipc_when_visibility_changes(visible: bool) -> HomeIpc {
    if visible {
        HomeIpc::SetUnfolded
    } else {
        HomeIpc::None
    }
}

pub fn home_target_name(target: HomeTarget) -> &'static str {
    match target {
        HomeTarget::Folded => "folded",
        HomeTarget::Unfolded => "unfolded",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unfold_when_last_toplevel_closes() {
        assert_eq!(
            derive_home_ipc(1, 0, UiMode::Idle),
            HomeIpc::SetUnfolded
        );
    }

    #[test]
    fn fold_when_first_toplevel_opens_from_idle() {
        assert_eq!(
            derive_home_ipc(0, 1, UiMode::Idle),
            HomeIpc::SetFolded
        );
    }

    #[test]
    fn no_fold_while_launcher_open() {
        assert_eq!(
            derive_home_ipc(0, 1, UiMode::LauncherOpen),
            HomeIpc::None
        );
    }

    #[test]
    fn launcher_open_unfolds_home_via_dbus() {
        assert_eq!(
            launcher_home_ipc_when_visibility_changes(true),
            HomeIpc::SetUnfolded
        );
    }

    #[test]
    fn launcher_close_must_not_fold_home() {
        assert_eq!(
            launcher_home_ipc_when_visibility_changes(false),
            HomeIpc::None
        );
    }
}
