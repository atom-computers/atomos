use atomos_app_handler::{
    derive_home_ipc, launcher_home_ipc_when_visibility_changes, parse_lifecycle_action,
    LifecycleAction, HomeIpc, HomeShellState, UiMode,
};

#[test]
fn after_unlock_home_unfold_does_not_fold() {
    assert_eq!(
        derive_home_ipc(0, 1, UiMode::Idle),
        HomeIpc::SetFolded
    );
}

#[test]
fn launcher_open_close_ipc_contract() {
    assert_eq!(
        launcher_home_ipc_when_visibility_changes(true),
        HomeIpc::SetUnfolded
    );
    assert_eq!(
        launcher_home_ipc_when_visibility_changes(false),
        HomeIpc::None
    );
}

#[test]
fn toplevel_count_drives_dbus_fold_unfold() {
    assert_eq!(derive_home_ipc(0, 1, UiMode::Idle), HomeIpc::SetFolded);
    assert_eq!(derive_home_ipc(1, 0, UiMode::Idle), HomeIpc::SetUnfolded);
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
        HomeIpc::None
    );
}