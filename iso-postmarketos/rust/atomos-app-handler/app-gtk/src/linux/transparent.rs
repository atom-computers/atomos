//! Install the GTK CSS that keeps the handle and gesture surfaces transparent.
//!
//! The layer-shell windows must have a transparent CSS background so the
//! foreground app remains visible through them. The switcher backdrop CSS
//! has been removed (swipe-up now closes the app directly, no overlay), but
//! the transparent-window class is still required for the gesture capture
//! surface and the handle strip.

use gtk::gdk;

const CSS_PROVIDER_NAME_MARKER: &str = "atomos-app-handler-transparent";

pub fn install_css() {
    let css = format!(
        ".atomos-app-handler-transparent-window {{ background: transparent; }} \
         #atomos-app-handler-handle {{ background: transparent; min-height: 1px; }} \
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
            "atomos-app-handler: no default gdk::Display available; transparent CSS not installed"
        );
    }
}