//! CSS provider for atomos-home dark/light theme.
//!
//! Mirrors the Phosh C CSS (ATOMOS_OVERVIEW_CHAT_UI_CSS) so the Rust
//! home surface visually matches the original PhoshHome.

#![cfg(target_os = "linux")]

const ATOMOS_HOME_CSS: &str = include_str!("../../../data/atomos-home.css");

pub fn load_css_provider() -> gtk::CssProvider {
    let provider = gtk::CssProvider::new();
    provider.load_from_data(ATOMOS_HOME_CSS);

    if let Some(display) = gtk::gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION + 20,
        );
    }

    provider
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn css_is_valid_utf8() {
        assert!(ATOMOS_HOME_CSS.contains("atomos-chat-input"));
    }

    #[test]
    fn css_contains_dark_and_light_themes() {
        assert!(ATOMOS_HOME_CSS.contains("atomos-dark"));
        assert!(ATOMOS_HOME_CSS.contains("atomos-light"));
    }

    #[test]
    fn css_contains_home_bar_class() {
        assert!(ATOMOS_HOME_CSS.contains("atomos-home-bar"));
    }

    #[test]
    fn css_contains_dock_btn_class() {
        assert!(ATOMOS_HOME_CSS.contains("atomos-dock-btn"));
    }

    #[test]
    fn css_contains_app_sheet_class() {
        assert!(ATOMOS_HOME_CSS.contains("atomos-app-sheet"));
    }
}