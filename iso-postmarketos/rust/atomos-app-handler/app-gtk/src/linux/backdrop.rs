//! Install the GTK CSS that paints the switcher surface opaque `#0a0a0a`.
//!
//! Keeping the policy out of the orchestrator file leaves
//! [`super::build_ui`] readable and lets the install step stay idempotent —
//! later calls overwrite the provider attached to the default display
//! rather than stacking new ones.

use gtk::gdk;

const CSS_PROVIDER_NAME_MARKER: &str = "atomos-app-handler-backdrop";

/// Install GTK CSS so:
/// - the full-screen switcher root (`.atomos-app-handler-root`) paints
///   the home-bg base color edge-to-edge, and
/// - the bottom-edge handle (`#atomos-app-handler-handle`) keeps a
///   transparent CSS background; the visible pill is painted in Cairo by
///   [`super::handle::install_handle_paint`].
///
/// `hex_color` is the `#0a0a0a` string from the core crate
/// (`BACKDROP_BASE_COLOR_HEX`) — passing it in keeps the CSS contract
/// trivially auditable: only one place to grep for the dark color.
pub fn install_css(hex_color: &str) {
    let css = format!(
        ".atomos-app-handler-root {{ background: {hex_color}; }} \
         .atomos-app-handler-card {{ \
            background: rgba(20, 20, 20, 0.92); \
            border-radius: 18px; \
            padding: 16px; \
            min-width: 180px; \
            min-height: 240px; \
            color: #f5f5f5; \
         }} \
         .atomos-app-handler-card.activated {{ \
            border: 2px solid rgba(128, 224, 178, 0.85); \
         }} \
         .atomos-app-handler-card-title {{ font-size: 14px; font-weight: 600; }} \
         .atomos-app-handler-card-appid {{ font-size: 10px; opacity: 0.55; }} \
         .atomos-app-handler-card-swatch {{ border-radius: 12px; }} \
         #atomos-app-handler-handle {{ background: transparent; min-height: 1px; }} \
         /* opt-in debug paint for the bottom-edge handle so a maintainer */ \
         /* can confirm at a glance whether the layer-shell surface is */ \
         /* actually mapped — wired from ATOMOS_APP_HANDLER_DEBUG_TINT=1 */ \
         /* in linux.rs::build_handle_window. */ \
         #atomos-app-handler-handle.atomos-app-handler-handle-debug-tint, \
         .atomos-app-handler-handle-debug-tint {{ \
            background: rgba(255, 0, 0, 0.35); \
            min-height: 1px; \
         }} \
         /* tag for sanity-grep: {CSS_PROVIDER_NAME_MARKER} */",
    );

    let provider = gtk::CssProvider::new();
    provider.load_from_data(&css);

    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    } else {
        eprintln!(
            "atomos-app-handler: no default gdk::Display available; backdrop CSS not installed"
        );
    }
}
