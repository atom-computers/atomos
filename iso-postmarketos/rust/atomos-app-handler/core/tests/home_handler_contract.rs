use atomos_app_handler::{
    derive_home_ipc, launcher_home_ipc_when_visibility_changes, parse_lifecycle_action,
    LifecycleAction, PhoshHomeIpc, PhoshHomeShellState, UiMode,
};

#[test]
fn after_unlock_home_unfold_does_not_fold() {
    assert_eq!(
        derive_home_ipc(0, 1, UiMode::Idle),
        PhoshHomeIpc::SetFolded
    );
}

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

#[test]
fn toplevel_count_drives_dbus_fold_unfold() {
    assert_eq!(derive_home_ipc(0, 1, UiMode::Idle), PhoshHomeIpc::SetFolded);
    assert_eq!(derive_home_ipc(1, 0, UiMode::Idle), PhoshHomeIpc::SetUnfolded);
}

#[test]
fn hide_lifecycle_action_is_parseable() {
    assert!(matches!(
        parse_lifecycle_action(&["--hide".into()]),
        LifecycleAction::Hide
    ));
}

#[test]
fn no_fold_while_launcher_open() {
    assert_eq!(
        derive_home_ipc(0, 1, UiMode::LauncherOpen),
        PhoshHomeIpc::None
    );
}