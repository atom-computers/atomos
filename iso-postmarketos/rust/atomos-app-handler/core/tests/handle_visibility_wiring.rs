//! Source-level contract that pins the egui-parity layout the device
//! GTK binary owes the user:
//!
//! - On the home screen (no app in the foreground) only
//!   `atomos-overview-chat-ui` is visible — the app-handler must not
//!   map the bottom-edge handle bar, must not have a separate app
//!   launcher window, and must not surface an "Apps" button on the
//!   handle.
//! - When at least one app is open the handle bar appears at the
//!   bottom edge and the user swipes up to bring the switcher cards
//!   (the egui preview's exact behavior).
//!
//! Reads `app-gtk/src/linux.rs` via `include_str!` and `app-gtk/src/`
//! via `Path::new(...).read_dir()` so a regression that re-introduces
//! the deleted `linux/launcher.rs` module trips a named test rather
//! than only showing up as a visual mismatch with the egui preview.

use std::path::Path;

const LINUX_RS: &str = include_str!("../../app-gtk/src/linux.rs");

#[test]
fn linux_does_not_reference_deleted_launcher_module() {
    assert!(
        !LINUX_RS.contains("mod launcher;"),
        "app-gtk/src/linux.rs must not declare `mod launcher;` — the \
         egui-parity contract is that chat-ui owns the app launcher; \
         atomos-app-handler only paints the handle + switcher"
    );
    assert!(
        !LINUX_RS.contains("launcher::"),
        "app-gtk/src/linux.rs must not call any `launcher::` items; \
         the launcher window has been removed"
    );
    assert!(
        !LINUX_RS.contains("LauncherController"),
        "app-gtk/src/linux.rs must not reference LauncherController; \
         chat-ui owns the launcher UI"
    );
    assert!(
        !LINUX_RS.contains("build_launcher_window"),
        "app-gtk/src/linux.rs must not call build_launcher_window"
    );
    assert!(
        !LINUX_RS.contains("toggle_launcher"),
        "app-gtk/src/linux.rs must not toggle a launcher window"
    );
    assert!(
        !LINUX_RS.contains("set_launcher_visible"),
        "app-gtk/src/linux.rs must not flip a launcher window visibility"
    );
    assert!(
        !LINUX_RS.contains("launcher_window"),
        "app-gtk/src/linux.rs must not own a launcher_window field — \
         the surface has been deleted"
    );
}

#[test]
fn linux_does_not_add_apps_dock_button_to_handle() {
    // The egui handle is just the strip + pill. The GTK handle must
    // match — no additional buttons that have no egui counterpart.
    assert!(
        !LINUX_RS.contains("with_label(\"Apps\")"),
        "app-gtk/src/linux.rs must not add a `gtk::Button::with_label(\"Apps\")` \
         to the handle bar — chat-ui's app-grid is the only launcher"
    );
}

#[test]
fn launcher_rs_file_is_deleted() {
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    let launcher_path = Path::new(manifest_dir)
        .join("..")
        .join("app-gtk")
        .join("src")
        .join("linux")
        .join("launcher.rs");
    assert!(
        !launcher_path.exists(),
        "app-gtk/src/linux/launcher.rs must be deleted — the chat-ui \
         owns the launcher UI; this file existing means a stray module \
         shipped that violates the egui-parity contract"
    );
}

#[test]
fn linux_ties_handle_visibility_to_toplevel_count() {
    assert!(
        LINUX_RS.contains("should_show_handle"),
        "app-gtk/src/linux.rs must call atomos_app_handler::should_show_handle \
         to gate handle_window visibility on the toplevel count, so the \
         home screen (count=0) shows only atomos-overview-chat-ui"
    );
}

#[test]
fn linux_does_not_unconditionally_present_handle_window_at_startup() {
    // Capture the bug shape "handle_window.present()" appearing as a
    // standalone statement at session-start (i.e. before any toplevel
    // exists). Calling `present()` on `set_visible(true)` from inside
    // on_toplevel_count_changed is fine; the prohibited form is the
    // unconditional call right after the window is built.
    let bare_present = LINUX_RS.lines().any(|line| {
        let trimmed = line.trim_start();
        if trimmed.starts_with("//") || trimmed.starts_with("///") {
            return false;
        }
        trimmed == "handle_window.present();"
    });
    assert!(
        !bare_present,
        "app-gtk/src/linux.rs must not call `handle_window.present();` \
         unconditionally at session start — the handle is hidden on the \
         home screen and only appears when a toplevel opens"
    );
}
