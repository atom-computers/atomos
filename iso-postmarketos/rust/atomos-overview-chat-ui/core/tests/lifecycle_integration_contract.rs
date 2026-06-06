//! Cross-artifact integration contracts for overview-chat-ui visibility on Phosh:
//!
//! - Unfolded home must use wlr-layer-shell **overlay** (not top/bottom under phosh-home).
//! - Locked session must **hide** chat-ui (overlay would paint on the lock screen).
//! - Session autostart must use **`--start`** (not `--show`, which reset layer after unfold).
//! - GTK default layer and install/verify scripts must stay aligned.
//!
//! Runs via `cargo test -p atomos-overview-chat-ui` on any host (reads sources only).

use std::path::PathBuf;

fn repo_relative(path: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(path)
}

fn read_repo_file(path: &str) -> String {
    let p = repo_relative(path);
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("read {}: {e}", p.display()))
}

fn assert_contains(haystack: &str, needle: &str, context: &str) {
    assert!(
        haystack.contains(needle),
        "{context}: expected substring missing: {needle:?}"
    );
}

fn assert_not_contains(haystack: &str, needle: &str, context: &str) {
    assert!(
        !haystack.contains(needle),
        "{context}: forbidden substring present: {needle:?}"
    );
}

// --- Rust / GTK surface defaults -------------------------------------------------

#[test]
fn core_default_layer_is_overlay_for_unfolded_home() {
    assert_eq!(
        atomos_overview_chat_ui::DEFAULT_LAYER_NAME,
        "overlay",
        "when Phosh has not set ATOMOS_OVERVIEW_CHAT_UI_LAYER, unfolded home must default above phosh-home (TOP)"
    );
}

#[test]
fn gtk_overlay_rs_maps_overlay_bottom_and_defaults_to_core_constant() {
    let overlay_rs = read_repo_file("../app-gtk/src/overlay.rs");
    assert_contains(&overlay_rs, "\"overlay\" => Layer::Overlay", "overlay.rs layer map");
    assert_contains(&overlay_rs, "\"bottom\" => Layer::Bottom", "overlay.rs layer map");
    assert_contains(
        &overlay_rs,
        "atomos_overview_chat_ui::DEFAULT_LAYER_NAME",
        "overlay.rs must default to core DEFAULT_LAYER_NAME (overlay)",
    );
    assert_not_contains(
        &overlay_rs,
        "unwrap_or_else(|_| \"top\".into())",
        "overlay.rs must not default to top (invisible under phosh-home)",
    );
}

#[test]
fn style_rs_has_gtk4_no_important_regression_test() {
    let style_rs = read_repo_file("../app-gtk/src/style.rs");
    assert_contains(
        &style_rs,
        "css_strings_must_not_use_important_keyword_gtk4_rejects_it",
        "style.rs must keep the GTK4 !important regression test",
    );
    let transparency_fn = style_rs
        .split("fn transparency_stylesheet()")
        .nth(1)
        .and_then(|tail| tail.split("\"#").next())
        .unwrap_or("");
    assert_not_contains(
        transparency_fn,
        "!important",
        "transparency CSS must not use !important",
    );
}

// --- Launcher install script ----------------------------------------------------

#[test]
fn install_script_autostart_uses_start_not_show() {
    let install = read_repo_file("../../../scripts/overview-chat-ui/install-overview-chat-ui.sh");
    assert_contains(
        &install,
        "Exec=/usr/libexec/atomos-overview-chat-ui --start",
        "autostart",
    );
    assert_contains(
        &install,
        "ATOMOS_OVERVIEW_CHAT_UI_AUTOSTART_SPAWN=0",
        "autostart must not spawn bottom-layer GTK before Phosh overlay --show",
    );
    assert_not_contains(
        &install,
        "Exec=/usr/libexec/atomos-overview-chat-ui --show",
        "autostart must not use --show (restarts on bottom and races Phosh overlay promotion)",
    );
}

#[test]
fn install_script_launcher_start_is_idempotent_show_restarts_for_layer() {
    let install = read_repo_file("../../../scripts/overview-chat-ui/install-overview-chat-ui.sh");
    assert_contains(&install, "    --start)", "launcher");
    assert_contains(
        &install,
        "if is_running; then",
        "launcher --start",
    );
    assert_contains(&install, "    --show)", "launcher");
    assert_contains(
        &install,
        "already running",
        "launcher --show must skip restart when layer unchanged",
    );
    assert_contains(
        &install,
        "stop_ui",
        "launcher --show must restart when ATOMOS_OVERVIEW_CHAT_UI_LAYER changes",
    );
    assert_contains(&install, "log_action", "launcher must log to atomos-overview-chat-ui.log");
    assert_contains(&install, "exec \"$BIN\"", "pidfile must track GTK binary not launcher shell");
    assert_contains(
        &install,
        "*/usr/local/bin/atomos-overview-chat-ui*",
        "is_running cmdline check",
    );
}

#[test]
fn hotfix_script_autostart_matches_install_start_contract() {
    let hotfix = read_repo_file("../../../scripts/overview-chat-ui/hotfix-overview-chat-ui.sh");
    assert_contains(
        &hotfix,
        "Exec=/usr/libexec/atomos-overview-chat-ui --start",
        "hotfix autostart",
    );
}

// --- Image verify / diagnose scripts --------------------------------------------

#[test]
fn lib_verify_and_build_qemu_expect_autostart_start() {
    for path in [
        "../../../scripts/_lib-verify.sh",
        "../../../scripts/build-qemu.sh",
        "../../../scripts/build-image.sh",
    ] {
        let text = read_repo_file(path);
        assert_contains(
            &text,
            "Exec=/usr/libexec/atomos-overview-chat-ui --start",
            path,
        );
        assert_not_contains(
            &text,
            "Exec=/usr/libexec/atomos-overview-chat-ui --show",
            path,
        );
    }
}

#[test]
fn diagnose_remote_script_has_no_single_quotes_inside_remote_blob() {
    let diagnose = read_repo_file("../../../scripts/app-handler/diagnose-app-handler.sh");
    let start = diagnose
        .find("REMOTE_SCRIPT='")
        .expect("REMOTE_SCRIPT opening quote");
    let body_start = start + "REMOTE_SCRIPT='".len();
    let body_end = diagnose[body_start..]
        .find("\n'\n")
        .map(|i| body_start + i)
        .expect("REMOTE_SCRIPT closing quote");
    let body = &diagnose[body_start..body_end];
    assert!(
        !body.contains('\''),
        "single quotes inside REMOTE_SCRIPT break the host-side assignment and corrupt SSH diagnose"
    );
    assert_contains(
        body,
        "ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay",
        "diagnose manual fix hint",
    );
}

// --- Phosh home.c (duplicate critical guards; full suite in atomos-app-handler) -

#[test]
fn smoke_chat_ui_post_unlock_script_exists_and_drives_dbus_unfold() {
    let smoke = read_repo_file("../../../scripts/overview-chat-ui/smoke-chat-ui-post-unlock.sh");
    let remote = read_repo_file("../../../scripts/overview-chat-ui/_lib-chat-ui-smoke.remote.sh");
    assert_contains(&smoke, "smoke-chat-ui-post-unlock", "smoke script");
    assert_contains(&smoke, "atomos_chat_ui_smoke_drive_unfold_and_assert_overlay", "smoke script");
    assert_contains(&remote, "SetUnfolded", "remote smoke");
    assert_contains(&remote, "ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay", "remote smoke");
    assert_contains(&remote, "action=show.*layer=overlay", "remote smoke log check");
    assert_contains(&remote, "atomos_chat_ui_layer_from_environ", "remote smoke");
}

#[test]
fn phosh_home_c_chat_ui_stack_contract_summary() {
    let home_c = read_repo_file("../../phosh/phosh/src/home.c");
    assert_contains(
        &home_c,
        "atomos_phosh_sync_overview_chat_ui_lifecycle",
        "home.c",
    );
    assert_contains(&home_c, "layer = \"overlay\"", "home.c unfold layer");
    assert_contains(&home_c, "phosh_shell_get_locked", "home.c lock gate");
    assert_contains(
        &home_c,
        "atomos_phosh_sync_overview_chat_ui_after_map_idle",
        "home.c map idle",
    );
    assert_contains(
        &home_c,
        "mark_ui_stable_for_popups_timeout",
        "home.c unfold stable gate",
    );
    assert_contains(
        &home_c,
        "on_shell_locked_changed_atomos_chat_ui",
        "home.c unlock resync",
    );
    // home-bg still uses top on unfold; only chat-ui must avoid top.
    let chat_lifecycle = home_c
        .split("atomos_phosh_sync_overview_chat_ui_lifecycle")
        .nth(1)
        .and_then(|tail| tail.split("atomos_phosh_bottom_edge_drag_disabled").next())
        .unwrap_or("");
    assert_not_contains(
        chat_lifecycle,
        "layer = \"top\"",
        "chat-ui lifecycle must not use top",
    );
}

#[test]
fn gtk_overlay_rs_uses_keyboard_mode_override() {
    let overlay_rs = read_repo_file("../app-gtk/src/overlay.rs");
    assert_contains(
        &overlay_rs,
        "crate::config::keyboard_mode_override()",
        "overlay.rs must read config::keyboard_mode_override",
    );
    assert_contains(&overlay_rs, "KeyboardMode::Exclusive", "overlay.rs must support exclusive keyboard mode");
    assert_contains(&overlay_rs, "KeyboardMode::OnDemand", "overlay.rs must support on-demand keyboard mode");
    assert_contains(&overlay_rs, "KeyboardMode::None", "overlay.rs must support none keyboard mode");
}

#[test]
fn test_no_capture_gesture_on_window_to_prevent_osk_blocking() {
    let ui_rs = read_repo_file("../app-gtk/src/ui.rs");
    // Intercepting taps at the window level in the capture phase blocks focus events
    // on child widgets (like TextView), which prevents Squeekboard/OSK from triggering.
    assert_not_contains(
        &ui_rs,
        "PropagationPhase::Capture",
        "Window must not intercept taps in Capture phase as it blocks child widget focus and OSK activation",
    );
}
