//! Launch-path integration contracts for chat-ui tile taps → app-handler
//! `launch <id>` → GIO spawn.
//!
//! Reproduces device regressions:
//!   - _only Firefox opens_ — DesktopAppInfo lookup mismatch (fixed via
//!     enumerated AppInfo fallback in launch_exec.rs).
//!   - _log says [launch: spawned] but nothing visible_ — chat-ui stayed on
//!     wlr-layer-shell OVERLAY with the app sheet open; xdg-toplevel apps
//!     paint underneath.

const LAUNCH_EXEC_RS: &str = include_str!("../../app-gtk/src/linux/launch_exec.rs");
const LINUX_RS: &str = include_str!("../../app-gtk/src/linux.rs");

#[test]
fn spawn_desktop_app_prefers_enumerated_app_info_before_desktop_lookup() {
    assert!(
        LAUNCH_EXEC_RS.contains("find_enumerated_desktop_app_info"),
        "launch_exec must scan gio::AppInfo::all() before DesktopAppInfo::new",
    );
    assert!(
        LAUNCH_EXEC_RS.contains("app_ids_match"),
        "launch_exec must compare ids the same way plan_launch does \
         (strip .desktop suffix)",
    );
    let body = LAUNCH_EXEC_RS
        .split("pub fn spawn_desktop_app")
        .nth(1)
        .and_then(|tail| tail.split("\nfn ").next())
        .unwrap_or("");
    assert!(
        body.contains("find_enumerated_desktop_app_info(app_id)"),
        "spawn_desktop_app must try enumerated DesktopAppInfo first",
    );
    assert!(
        body.contains("DesktopAppInfo::new"),
        "DesktopAppInfo::new remains as fallback after enumeration miss",
    );
}

#[test]
fn run_launch_once_promotes_chat_ui_to_bottom_after_success() {
    let body = LINUX_RS
        .split("fn run_launch_once")
        .nth(1)
        .and_then(|tail| tail.split("\nfn promote_overview_chat_ui_to_bottom_layer").next())
        .unwrap_or("");
    assert!(
        body.contains("promote_overview_chat_ui_to_bottom_layer()"),
        "successful launch must relayer chat-ui from OVERLAY to BOTTOM",
    );
    assert!(
        LINUX_RS.contains("ATOMOS_OVERVIEW_CHAT_UI_LAYER")
            && LINUX_RS.contains("--show"),
        "promotion must use the overview-chat-ui launcher --show path",
    );
}
