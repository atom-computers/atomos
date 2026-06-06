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
         /* Default theme styling: fallback to dark */ \
         .atomos-top-bar {{ \
            color: #ffffff; \
         }} \
         .atomos-top-bar label {{ \
            color: #ffffff; \
         }} \
         .atomos-top-bar image {{ \
            color: #ffffff; \
         }} \
         .atomos-app-handler-card {{ \
            background: rgba(20, 20, 20, 0.92); \
            border-radius: 18px; \
            padding: 16px; \
            min-width: 180px; \
            min-height: 240px; \
            color: #f5f5f5; \
         }} \
         \
         /* DARK theme overrides */ \
         .atomos-app-handler-root.atomos-dark {{ \
            background: {hex_color}; \
         }} \
         .atomos-top-bar.atomos-dark, \
         .atomos-top-bar.atomos-dark label, \
         .atomos-top-bar.atomos-dark image, \
         .atomos-app-handler-root.atomos-dark .atomos-top-bar, \
         .atomos-app-handler-root.atomos-dark .atomos-top-bar label, \
         .atomos-app-handler-root.atomos-dark .atomos-top-bar image {{ \
            color: #ffffff; \
         }} \
         .atomos-app-handler-root.atomos-dark .atomos-app-handler-card {{ \
            background: rgba(20, 20, 20, 0.92); \
            color: #f5f5f5; \
         }} \
         \
         /* LIGHT theme overrides */ \
         .atomos-app-handler-root.atomos-light {{ \
            background: #f2f2f2; \
         }} \
         .atomos-top-bar.atomos-light, \
         .atomos-top-bar.atomos-light label, \
         .atomos-top-bar.atomos-light image, \
         .atomos-app-handler-root.atomos-light .atomos-top-bar, \
         .atomos-app-handler-root.atomos-light .atomos-top-bar label, \
         .atomos-app-handler-root.atomos-light .atomos-top-bar image {{ \
            color: #121212; \
         }} \
         .atomos-app-handler-root.atomos-light .atomos-app-handler-card {{ \
            background: rgba(240, 240, 240, 0.92); \
            color: #121212; \
            border: 1px solid rgba(0, 0, 0, 0.12); \
         }} \
         \
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
         .atomos-app-handler-transparent-window {{ background: transparent; }} \
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
