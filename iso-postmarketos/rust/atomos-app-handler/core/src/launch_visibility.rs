//! Layer visibility policy for chat-ui app-grid tile launches.
//!
//! wlr-layer-shell **OVERLAY** surfaces paint above xdg-toplevel windows. When
//! chat-ui stays on OVERLAY after a successful launch, GIO logs success but the
//! new app is invisible underneath — the regression where Console never appeared
//! while Firefox sometimes seemed to work (ActivateExisting on an already-mapped
//! toplevel, or stale layer state).

use crate::LayerTarget;

/// Env value written by app-handler after any successful tile launch.
pub const CHAT_UI_LAYER_AFTER_SUCCESSFUL_LAUNCH: &str = "bottom";

/// Layer chat-ui uses while the unfolded app-grid sheet is open (Phosh `--show`).
pub const CHAT_UI_LAYER_APP_GRID_OPEN: &str = "overlay";

/// Representative DBus-activatable app that failed the invisible-launch regression.
pub const REGRESSION_APP_DBUS_ACTIVATABLE: &str = "org.gnome.Console.desktop";

/// Representative app that could mask the regression via ActivateExisting.
pub const REGRESSION_APP_EXISTING_TOLEVEL: &str = "firefox-esr.desktop";

/// Whether a newly spawned or activated xdg-toplevel is visible above chat-ui.
///
/// In wlroots/phoc, regular toplevels render above layer-shell surfaces on
/// Background/Bottom/Top and strictly **below** OVERLAY.
pub const fn foreground_xdg_toplevel_visible_with_chat_ui_layer(layer: LayerTarget) -> bool {
    layer.z_index() < LayerTarget::Overlay.z_index()
}

/// Chat-ui must sit on BOTTOM after a tile launch so foreground apps paint above it.
pub const fn required_chat_ui_layer_after_tile_launch() -> LayerTarget {
    LayerTarget::Bottom
}

/// When chat-ui is still on OVERLAY (app sheet open), app-handler must relayer it.
pub fn chat_ui_layer_must_change_after_tile_launch(
    current: LayerTarget,
) -> Option<LayerTarget> {
    if current == LayerTarget::Overlay {
        Some(required_chat_ui_layer_after_tile_launch())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overlay_hides_foreground_apps_bottom_allows_them() {
        assert!(
            !foreground_xdg_toplevel_visible_with_chat_ui_layer(LayerTarget::Overlay),
            "OVERLAY occludes xdg-toplevel apps — the Console-hidden regression",
        );
        assert!(
            foreground_xdg_toplevel_visible_with_chat_ui_layer(LayerTarget::Bottom),
            "BOTTOM lets spawned apps paint above the chat strip",
        );
    }

    #[test]
    fn promotion_required_only_from_overlay() {
        assert_eq!(
            chat_ui_layer_must_change_after_tile_launch(LayerTarget::Overlay),
            Some(LayerTarget::Bottom),
        );
        assert_eq!(
            chat_ui_layer_must_change_after_tile_launch(LayerTarget::Bottom),
            None,
        );
    }
}
