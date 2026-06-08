//! Session / home-target policy for fold-unfold orchestration.
//!
//! The Rust handler owns fold decisions; Phosh exposes a thin D-Bus API that
//! maps targets onto `phosh_home_set_state()`.
//!
//! Pure functions here are the contract Phosh C (`home.c`) and GTK (`launcher.rs`)
//! must follow.

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

/// Mirrors `PhoshHomeState` in Phosh `home.h` (fold / unfold / transition).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhoshHomeShellState {
    Folded,
    Unfolded,
    Transition,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhoshHomeIpc {
    None,
    SetFolded,
    SetUnfolded,
}

/// Derive whether Phosh home should fold or unfold from toplevel count changes.
pub fn derive_home_ipc(prev_count: usize, new_count: usize, ui_mode: UiMode) -> PhoshHomeIpc {
    if new_count == 0 && prev_count > 0 {
        return PhoshHomeIpc::SetUnfolded;
    }
    if new_count > 0 && prev_count == 0 && !matches!(ui_mode, UiMode::LauncherOpen) {
        return PhoshHomeIpc::SetFolded;
    }
    PhoshHomeIpc::None
}

/// D-Bus fold/unfold when the Rust launcher sheet opens or closes.
pub fn launcher_home_ipc_when_visibility_changes(visible: bool) -> PhoshHomeIpc {
    if visible {
        PhoshHomeIpc::SetUnfolded
    } else {
        PhoshHomeIpc::None
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
            PhoshHomeIpc::SetUnfolded
        );
    }

    #[test]
    fn fold_when_first_toplevel_opens_from_idle() {
        assert_eq!(
            derive_home_ipc(0, 1, UiMode::Idle),
            PhoshHomeIpc::SetFolded
        );
    }

    #[test]
    fn no_fold_while_launcher_open() {
        assert_eq!(
            derive_home_ipc(0, 1, UiMode::LauncherOpen),
            PhoshHomeIpc::None
        );
    }

    #[test]
    fn launcher_open_unfolds_home_via_dbus() {
        assert_eq!(
            launcher_home_ipc_when_visibility_changes(true),
            PhoshHomeIpc::SetUnfolded
        );
    }

    #[test]
    fn launcher_close_must_not_fold_home() {
        assert_eq!(
            launcher_home_ipc_when_visibility_changes(false),
            PhoshHomeIpc::None
        );
    }
}
