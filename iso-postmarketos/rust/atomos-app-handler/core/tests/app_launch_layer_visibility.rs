//! Source-level contract that the app-handler launch path no longer
//! orchestrates Phosh home fold/unfold or chat-ui layer promotion.
//! Swipe-up closes the foreground app — the app handler does not call
//! SetFolded/SetUnfolded or spawn chat-ui --show.

use atomos_app_handler as sw;

const LINUX_RS: &str = include_str!("../../app-gtk/src/linux.rs");

#[test]
fn run_launch_once_does_not_call_phosh_home_ipc() {
    assert!(
        !LINUX_RS.contains("apply_home_ipc"),
        "run_launch_once must not call Phosh home fold/unfold D-Bus",
    );
    assert!(
        !LINUX_RS.contains("promote_overview_chat_ui_to_bottom_layer"),
        "run_launch_once must not promote overview-chat-ui layer",
    );
}

#[test]
fn run_launch_once_does_not_spawn_overview_chat_ui() {
    assert!(
        !LINUX_RS.contains("OVERVIEW_CHAT_UI_LAUNCHER"),
        "app-handler must not spawn overview-chat-ui on launch",
    );
    assert!(
        !LINUX_RS.contains("--show"),
        "app-handler must not pass --show to any chat-ui process",
    );
}

#[test]
fn on_toplevel_count_changed_does_not_call_phosh_home_fold() {
    assert!(
        !LINUX_RS.contains("derive_home_ipc"),
        "on_toplevel_count_changed must not call Phosh home fold/unfold IPC",
    );
}