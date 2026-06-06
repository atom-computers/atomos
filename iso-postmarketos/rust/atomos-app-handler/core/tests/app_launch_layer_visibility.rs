//! Presence / layering integration contracts for chat-ui tile launches.
//!
//! Pins the regression where GIO logged `[launch: spawned]` for Console (and
//! similar apps) but nothing appeared on screen because chat-ui stayed on
//! wlr-layer-shell OVERLAY with the app-grid sheet open. Firefox could appear
//! to work when ActivateExisting focused an already-mapped toplevel — not
//! because the launch path skipped the bug.

use atomos_app_handler as sw;
use atomos_home_bg as bg;
use atomos_overview_chat_ui as chat;

const LINUX_RS: &str = include_str!("../../app-gtk/src/linux.rs");
const APP_GRID_RS: &str =
    include_str!("../../../atomos-overview-chat-ui/app-gtk/src/app_grid.rs");
const UI_RS: &str = include_str!("../../../atomos-overview-chat-ui/app-gtk/src/ui.rs");
const DIAGNOSE_LAUNCH_SH: &str =
    include_str!("../../../../scripts/app-handler/diagnose-app-launch.sh");

#[test]
fn wlr_layer_z_order_pins_overlay_above_bottom() {
    let overlay = bg::LayerTarget::Overlay;
    let bottom = bg::LayerTarget::Bottom;
    assert!(
        overlay.z_index() > bottom.z_index(),
        "OVERLAY must draw above BOTTOM so chat-ui on overlay hides xdg-toplevel apps",
    );
}

#[test]
fn core_policy_overlay_hides_foreground_apps_bottom_allows_them() {
    assert!(
        !sw::foreground_xdg_toplevel_visible_with_chat_ui_layer(sw::LayerTarget::Overlay),
        "app grid on OVERLAY must not leave spawned apps visible",
    );
    assert!(
        sw::foreground_xdg_toplevel_visible_with_chat_ui_layer(sw::LayerTarget::Bottom),
        "post-launch BOTTOM must let Console/Firefox paint above chat-ui",
    );
}

#[test]
fn chat_ui_default_layer_for_app_grid_is_overlay() {
    assert_eq!(
        chat::DEFAULT_LAYER_NAME,
        sw::CHAT_UI_LAYER_APP_GRID_OPEN,
        "unfolded app sheet and Phosh --show use overlay",
    );
}

#[test]
fn successful_tile_launch_must_promote_chat_ui_from_overlay_to_bottom() {
    assert_eq!(
        sw::chat_ui_layer_must_change_after_tile_launch(sw::LayerTarget::Overlay),
        Some(sw::required_chat_ui_layer_after_tile_launch()),
    );
    assert_eq!(
        sw::required_chat_ui_layer_after_tile_launch(),
        sw::LayerTarget::Bottom,
    );
    assert_eq!(
        sw::CHAT_UI_LAYER_AFTER_SUCCESSFUL_LAUNCH,
        "bottom",
        "promotion env must match LayerTarget::Bottom name",
    );
}

#[test]
fn run_launch_once_promotes_on_both_spawn_and_activate_paths() {
    let body = LINUX_RS
        .split("fn run_launch_once")
        .nth(1)
        .and_then(|tail| tail.split("\nfn promote_overview_chat_ui_to_bottom_layer").next())
        .unwrap_or("");
    assert!(
        body.contains("let finish_launch"),
        "run_launch_once must centralize post-success relayering",
    );
    assert!(
        body.matches("finish_launch(").count() >= 2,
        "both ActivateExisting and spawn paths must call finish_launch (Firefox vs Console parity)",
    );
    assert!(
        body.contains("promote_overview_chat_ui_to_bottom_layer()"),
        "finish_launch must promote chat-ui to bottom",
    );
}

#[test]
fn promotion_uses_core_layer_constant_not_ad_hoc_string() {
    assert!(
        LINUX_RS.contains("CHAT_UI_LAYER_AFTER_SUCCESSFUL_LAUNCH"),
        "linux.rs must use launch_visibility constant for ATOMOS_OVERVIEW_CHAT_UI_LAYER",
    );
    assert!(
        LINUX_RS.contains("launch: promoting overview-chat-ui to bottom layer"),
        "promotion must log a stable trace for diagnose-app-launch.sh",
    );
}

#[test]
fn launch_path_has_no_per_app_layer_exceptions() {
    let body = LINUX_RS
        .split("fn run_launch_once")
        .nth(1)
        .and_then(|tail| tail.split("\nfn promote_overview_chat_ui_to_bottom_layer").next())
        .unwrap_or("");
    for needle in [
        sw::REGRESSION_APP_DBUS_ACTIVATABLE,
        sw::REGRESSION_APP_EXISTING_TOLEVEL,
        "firefox",
        "Console",
    ] {
        assert!(
            !body.contains(needle),
            "run_launch_once must not special-case {needle:?} — overlay hiding affects all apps",
        );
    }
}

#[test]
fn tile_click_dismisses_app_sheet_before_spawn() {
    let tile_handler = APP_GRID_RS
        .split("tile_btn.connect_clicked")
        .nth(1)
        .and_then(|tail| tail.split("flow.insert").next())
        .unwrap_or("");
    assert!(
        tile_handler.contains("dismiss_for_tile()"),
        "tile click must collapse overlay sheet before launch",
    );
    let dismiss_order = tile_handler
        .find("dismiss_for_tile()")
        .zip(tile_handler.find("tile_click_launch("));
    assert!(
        dismiss_order.map(|(d, l)| d < l).unwrap_or(false),
        "dismiss must run before tile_click_launch",
    );
    assert!(
        UI_RS.contains("dismissing app sheet for launch"),
        "dismiss helper must log for diagnose-app-launch.sh",
    );
}

#[test]
fn app_grid_comments_document_overlay_occlusion_regression() {
    assert!(
        APP_GRID_RS.contains("wlr-layer-shell OVERLAY"),
        "app_grid must document why dismiss-before-launch matters",
    );
}

#[test]
fn diagnose_script_warns_when_overlay_persists_after_successful_launch() {
    assert!(
        DIAGNOSE_LAUNCH_SH.contains("Chat-ui layer vs foreground app (overlay hides xdg-toplevel)"),
        "diagnose must include a layer-vs-foreground section",
    );
    assert!(
        DIAGNOSE_LAUNCH_SH.contains("chat-ui still on overlay after successful launch"),
        "diagnose must warn when layer file stays overlay after launch success",
    );
    assert!(
        DIAGNOSE_LAUNCH_SH.contains("launch: promoting overview-chat-ui to bottom layer"),
        "diagnose must check for app-handler promotion log line",
    );
    assert!(
        DIAGNOSE_LAUNCH_SH.contains("dismissing app sheet for launch"),
        "diagnose must mention chat-ui sheet dismiss trace",
    );
}

#[test]
fn presence_contract_requires_both_dismiss_and_promotion_for_visibility() {
    assert!(
        sw::chat_ui_layer_must_change_after_tile_launch(sw::LayerTarget::Overlay).is_some(),
        "app-handler promotion required when chat-ui on overlay",
    );
    assert!(
        APP_GRID_RS.contains("dismiss_for_tile()"),
        "overview-chat-ui must dismiss sheet on tile tap",
    );
}
