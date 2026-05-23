//! Session / home-target policy for fold-unfold orchestration.
//!
//! The Rust handler owns fold decisions; Phosh exposes a thin D-Bus API that
//! maps targets onto `phosh_home_set_state()`.
//!
//! Pure functions here are the contract Phosh C (`home.c`) and GTK (`launcher.rs`)
//! must follow — unit tests gate regressions such as sending `--show` on unlock.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UiMode {
    Idle,
    SwitcherOpen,
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

/// Libexec launcher actions driven from Phosh `atomos_phosh_sync_app_handler_lifecycle`.
/// Must stay disjoint from [`crate::LifecycleAction::Show`] (SIGUSR1 opens the switcher).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellLifecycleAction {
    /// Do not spawn the libexec wrapper for this home-state transition.
    None,
    /// `atomos-app-handler --hide` / SIGUSR2 — dismiss switcher overlay only.
    HideSwitcherOverlay,
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
    if new_count > 0
        && prev_count == 0
        && !matches!(ui_mode, UiMode::LauncherOpen | UiMode::SwitcherOpen)
    {
        return PhoshHomeIpc::SetFolded;
    }
    PhoshHomeIpc::None
}

/// Phosh `home.c` must only hide the switcher when home folds — never `--show` on
/// unfold (that covered the home UI right after unlock).
pub fn shell_lifecycle_action_for_home_state(state: PhoshHomeShellState) -> ShellLifecycleAction {
    match state {
        PhoshHomeShellState::Folded => ShellLifecycleAction::HideSwitcherOverlay,
        PhoshHomeShellState::Unfolded | PhoshHomeShellState::Transition => {
            ShellLifecycleAction::None
        }
    }
}

/// Libexec argv fragment for [`ShellLifecycleAction`], if any.
pub fn shell_lifecycle_argv(action: ShellLifecycleAction) -> Option<&'static str> {
    match action {
        ShellLifecycleAction::None => None,
        ShellLifecycleAction::HideSwitcherOverlay => Some("--hide"),
    }
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
    use crate::LifecycleAction;

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
    fn no_fold_while_switcher_open() {
        assert_eq!(
            derive_home_ipc(0, 1, UiMode::SwitcherOpen),
            PhoshHomeIpc::None
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
    fn phosh_unfold_must_not_hide_or_show_switcher_via_shell_lifecycle() {
        assert_eq!(
            shell_lifecycle_action_for_home_state(PhoshHomeShellState::Unfolded),
            ShellLifecycleAction::None
        );
        assert_eq!(
            shell_lifecycle_argv(shell_lifecycle_action_for_home_state(
                PhoshHomeShellState::Unfolded
            )),
            None
        );
    }

    #[test]
    fn phosh_transition_must_not_show_switcher_via_shell_lifecycle() {
        assert_eq!(
            shell_lifecycle_action_for_home_state(PhoshHomeShellState::Transition),
            ShellLifecycleAction::None
        );
    }

    #[test]
    fn phosh_fold_hides_switcher_overlay_only() {
        assert_eq!(
            shell_lifecycle_action_for_home_state(PhoshHomeShellState::Folded),
            ShellLifecycleAction::HideSwitcherOverlay
        );
        assert_eq!(
            shell_lifecycle_argv(ShellLifecycleAction::HideSwitcherOverlay),
            Some("--hide")
        );
    }

    #[test]
    fn shell_lifecycle_hide_is_not_lifecycle_action_show() {
        let argv = shell_lifecycle_argv(ShellLifecycleAction::HideSwitcherOverlay).unwrap();
        assert_eq!(argv, "--hide");
        assert_ne!(
            crate::parse_lifecycle_action(&[argv.to_string()]),
            LifecycleAction::Show
        );
        assert_eq!(
            crate::parse_lifecycle_action(&["--show".into()]),
            LifecycleAction::Show
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
