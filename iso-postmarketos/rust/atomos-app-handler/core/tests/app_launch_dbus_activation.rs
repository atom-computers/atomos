//! TDD contracts for the Firefox-opens / Console-doesn't DBusActivatable split.
//!
//! GIO `app.launch(..., None)` returns Ok for Console because D-Bus Activate
//! succeeds, but without GdkAppLaunchContext the compositor never receives an
//! XDG activation token so the window stays invisible. Firefox uses Exec= and
//! inherits Wayland env from the spawned child process.

use atomos_app_handler as sw;

const LAUNCH_EXEC_RS: &str = include_str!("../../app-gtk/src/linux/launch_exec.rs");
const APP_TRACKER_RS: &str = include_str!("../../../phosh/phosh/src/app-tracker.c");

#[test]
fn regression_fixture_firefox_is_exec_only() {
    assert!(sw::desktop_entry_has_exec(sw::FIXTURE_FIREFOX_ESR_DESKTOP));
    assert!(!sw::launch_requires_gdk_app_launch_context(sw::FIXTURE_FIREFOX_ESR_DESKTOP));
}

#[test]
fn regression_fixture_gnome_console_is_dbus_activatable() {
    assert!(sw::launch_requires_gdk_app_launch_context(
        sw::FIXTURE_GNOME_CONSOLE_DESKTOP
    ));
    assert!(sw::desktop_entry_has_exec(sw::FIXTURE_GNOME_CONSOLE_DESKTOP));
    assert_eq!(
        sw::parse_desktop_entry_primary_exec(sw::FIXTURE_GNOME_CONSOLE_DESKTOP).as_deref(),
        Some("kgx"),
    );
}

#[test]
fn phosh_app_tracker_uses_gdk_app_launch_context_not_none() {
    let body = APP_TRACKER_RS
        .split("phosh_app_tracker_launch_app_info")
        .nth(1)
        .unwrap_or("");
    assert!(
        body.contains("gdk_display_get_app_launch_context"),
        "Phosh app-tracker must pass GdkAppLaunchContext to GIO",
    );
    assert!(
        body.contains("g_desktop_app_info_launch_uris_as_manager"),
        "Phosh app-tracker must launch through GAppLaunchContext-aware API",
    );
}

#[test]
fn spawn_desktop_app_uses_gdk_display_app_launch_context() {
    assert!(
        LAUNCH_EXEC_RS.contains("display_app_launch_context"),
        "launch_exec must build GdkAppLaunchContext from the default display",
    );
    assert!(
        !LAUNCH_EXEC_RS.contains("Option::<&gio::AppLaunchContext>::None"),
        "launch_exec must not pass None — DBusActivatable apps silently fail to appear",
    );
    let body = LAUNCH_EXEC_RS
        .split("pub fn spawn_desktop_app")
        .nth(1)
        .and_then(|tail| tail.split("\nfn ").next())
        .unwrap_or("");
    assert!(
        body.contains("launch_uris_as_manager"),
        "spawn_desktop_app must use Phosh launch_uris_as_manager API for Exec apps",
    );
    assert!(
        body.contains("dbus activatable spawning desktop Exec"),
        "DBusActivatable apps with a window Exec= (Console/kgx) must spawn that, not dbus daemon only",
    );
    assert!(
        body.contains("dbus activatable via launch_uris_as_manager"),
        "DBusActivatable apps without a window Exec= still use launch_uris_as_manager",
    );
    assert!(
        body.contains("should_spawn_dbus_service_exec_directly"),
        "direct service Exec spawn must skip --gapplication-service daemons",
    );
    assert!(
        body.contains("sync_session_env_to_dbus_activation"),
        "DBusActivatable apps need dbus-update-activation-environment before launch",
    );
}

#[test]
fn spawn_desktop_app_documents_console_vs_firefox_split() {
    assert!(
        LAUNCH_EXEC_RS.contains("DBusActivatable") || LAUNCH_EXEC_RS.contains("activation token"),
        "launch_exec must document why GdkAppLaunchContext is required",
    );
}

#[test]
fn launch_path_has_no_console_or_firefox_special_cases() {
    let body = LAUNCH_EXEC_RS
        .split("pub fn spawn_desktop_app")
        .nth(1)
        .and_then(|tail| tail.split("\nfn ").next())
        .unwrap_or("");
    for needle in [sw::APP_ID_GNOME_CONSOLE, sw::APP_ID_FIREFOX_ESR, "firefox-esr"] {
        assert!(
            !body.contains(needle),
            "spawn_desktop_app must treat all apps uniformly, not special-case {needle:?}",
        );
    }
}
