//! Rust-side policy for launcher IPC and libexec argv parsing.
//!
//! Does **not** prove Phosh `home.c` implements the same rules — that is gated by
//! `phosh_home_c_source_contract.rs` and `tests/test_phosh_home_c_lifecycle_contract.py`.
//! The post-unlock black overlay came from Phosh C sending `--show` on unfold while
//! this Rust policy already returned `ShellLifecycleAction::None`.

use atomos_app_handler::{
    derive_home_ipc, launcher_home_ipc_when_visibility_changes, parse_lifecycle_action,
    shell_lifecycle_action_for_home_state, shell_lifecycle_argv, LifecycleAction, PhoshHomeIpc,
    PhoshHomeShellState, ShellLifecycleAction, UiMode,
};

/// Simulates: user unlocks → Phosh home unfolds → must not open switcher overlay.
#[test]
fn after_unlock_home_unfold_does_not_trigger_show_or_hide_shell_sync() {
    let action = shell_lifecycle_action_for_home_state(PhoshHomeShellState::Unfolded);
    assert_eq!(action, ShellLifecycleAction::None);
    assert!(shell_lifecycle_argv(action).is_none());
}

/// Simulates: user folds home (swipe down) → switcher overlay dismissed, handle stays.
#[test]
fn home_fold_triggers_hide_not_show() {
    let action = shell_lifecycle_action_for_home_state(PhoshHomeShellState::Folded);
    assert_eq!(action, ShellLifecycleAction::HideSwitcherOverlay);
    assert_eq!(shell_lifecycle_argv(action), Some("--hide"));
    assert_ne!(
        parse_lifecycle_action(&["--show".into()]),
        parse_lifecycle_action(&[shell_lifecycle_argv(action).unwrap().into()])
    );
}

/// Simulates: user opens Apps drawer → unfold home; closes drawer → home stays unfolded.
#[test]
fn launcher_open_close_ipc_contract() {
    assert_eq!(
        launcher_home_ipc_when_visibility_changes(true),
        PhoshHomeIpc::SetUnfolded
    );
    assert_eq!(
        launcher_home_ipc_when_visibility_changes(false),
        PhoshHomeIpc::None
    );
}

/// Simulates: launch app → fold; close last app → unfold (via Wayland toplevel count).
#[test]
fn toplevel_count_drives_dbus_fold_unfold() {
    assert_eq!(derive_home_ipc(0, 1, UiMode::Idle), PhoshHomeIpc::SetFolded);
    assert_eq!(derive_home_ipc(1, 0, UiMode::Idle), PhoshHomeIpc::SetUnfolded);
}

/// Swipe-up switcher is explicit user/gesture path, not Phosh home unfold.
#[test]
fn show_and_hide_lifecycle_actions_are_gesture_paths_not_phosh_home_sync() {
    assert!(matches!(
        parse_lifecycle_action(&["--show".into()]),
        LifecycleAction::Show
    ));
    assert!(matches!(
        parse_lifecycle_action(&["--hide".into()]),
        LifecycleAction::Hide
    ));
    assert_eq!(
        shell_lifecycle_action_for_home_state(PhoshHomeShellState::Unfolded),
        ShellLifecycleAction::None
    );
}
