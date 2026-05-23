//! Source-level wiring contract for the chat-ui app-grid tile click
//! handler. Mirrors the Phosh-side
//! `test_app_grid_button_launches_via_handler_not_tracker` Python test in
//! [`iso-postmarketos/tests/test_lock_parity_scripts.py`](../../../../tests/test_lock_parity_scripts.py),
//! but co-located with the chat-ui Rust crate so `cargo test
//! -p atomos-overview-chat-ui` is enough to catch a regression on any host
//! (macOS / Linux without GTK installed).
//!
//! These assertions reproduce — and pin the fix to — the bug:
//! _"clicked an app icon in the chat-ui sheet, the app opens, but the
//! atomos-app-handler swipe-up-to-switcher gesture is never armed because
//! the launch bypassed `/usr/libexec/atomos-app-handler launch <id>`."_
//!
//! Today's `app_grid.rs` calls `gio::AppInfo::launch(&[], None)` directly,
//! which trips the negative regex below and fails the positive
//! `assert!(contains(...))` line that requires routing through
//! `decide_launch_invocation` + the app-handler launcher path.

const APP_GRID_RS: &str = include_str!("../../app-gtk/src/app_grid.rs");

#[test]
fn app_grid_tile_click_dispatches_through_decide_launch_invocation() {
    assert!(
        APP_GRID_RS.contains("decide_launch_invocation"),
        "app-gtk/src/app_grid.rs must call \
         atomos_overview_chat_ui::decide_launch_invocation so the tile-click \
         decision is shared with the chat-ui core unit tests and the \
         atomos-app-handler combined_stack round-trip; today the click \
         handler still calls `app.launch(&[], None)` unconditionally and \
         bypasses the lifecycle (the bug)",
    );
}

#[test]
fn app_grid_tile_click_references_app_handler_launcher_path_constant() {
    assert!(
        APP_GRID_RS.contains("APP_HANDLER_LAUNCHER_PATH")
            || APP_GRID_RS.contains("/usr/libexec/atomos-app-handler"),
        "app-gtk/src/app_grid.rs must resolve the app-handler launcher via \
         atomos_overview_chat_ui::APP_HANDLER_LAUNCHER_PATH (or the \
         documented literal) so the tile-click dispatches to the same \
         launcher Phosh's app-grid-button.c spawns",
    );
}

#[test]
fn app_grid_tile_click_must_not_invoke_gio_launch_on_app_info_directly() {
    // Captures today's bypass: `app.launch(&[], None)` and equivalents in
    // the click closure. We allow the symbol to appear inside a
    // `LaunchInvocation::DirectGioFallback` arm (for the Phosh-parity
    // warn-and-skip path on hosts without the launcher) but it must not be
    // the unconditional thing the click handler does.
    let direct_call_in_click_handler = APP_GRID_RS
        .lines()
        .any(|line| {
            let trimmed = line.trim_start();
            trimmed.starts_with("if let Err(err) = app_for_launch.launch(")
                || trimmed.starts_with("let _ = app_for_launch.launch(")
                || trimmed.starts_with("app_for_launch.launch(")
        });
    assert!(
        !direct_call_in_click_handler,
        "app-gtk/src/app_grid.rs must not call `app_for_launch.launch(...)` \
         directly from the tile-click closure — that's the bug. Route \
         through decide_launch_invocation / launch_invocation_argv \
         (matching Phosh `app-grid-button.c:activate_cb`) and only fall \
         back to gio inside the `LaunchInvocation::DirectGioFallback` arm \
         when the launcher path is missing on disk",
    );
}
