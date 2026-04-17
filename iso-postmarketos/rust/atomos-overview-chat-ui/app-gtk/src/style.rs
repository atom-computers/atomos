use gtk::gdk;
use gtk::prelude::*;

use crate::logic::{env_flag_enabled, theme_class};

fn force_transparent_root() -> bool {
    env_flag_enabled(std::env::var(
        "ATOMOS_OVERVIEW_CHAT_UI_FORCE_TRANSPARENT_ROOT",
    ))
}

fn custom_css_disabled() -> bool {
    env_flag_enabled(std::env::var("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS"))
}

fn stylesheet(desktop_like: bool) -> String {
    let top_row_padding_top = 8;
    let root_bg = if force_transparent_root() {
        "background-color: alpha(#000000, 0.22);"
    } else if desktop_like {
        "background-color: alpha(#0b0f17, 0.92);"
    } else {
        // Mobile/overlay surfaces sit on top of existing UI; keep the root as a subtle
        // darkening rather than an obvious colored tint.
        "background-color: alpha(#000000, 0.22);"
    };
    let input_extra = "border: 1px solid alpha(#ffffff, 0.22); box-shadow: none;";
    format!(
        "
window.atomos-chat-root {{
  {root_bg}
}}
box.atomos-chat-wrap {{
  padding: 12px;
}}
scrolledwindow.atomos-chat-input {{
  border-radius: 16px;
  background: alpha(#151923, 0.58);
  {input_extra}
}}
textview.atomos-chat-input {{
  background-color: transparent;
  color: #ffffff;
  padding: 10px 14px;
  border: none;
  outline: none;
  box-shadow: none;
}}
textview.atomos-chat-input:focus {{
  padding: 10px 14px;
  border: none;
  outline: none;
  box-shadow: none;
}}
box.atomos-top-row {{
  padding: {top_row_padding_top}px 12px 0 12px;
}}
box.atomos-top-dock {{
  padding: 8px;
  border-radius: 24px;
  outline: 1px solid alpha(#ffffff, 0.16);
  outline-offset: -1px;
}}
button.atomos-dock-btn {{
  min-width: 42px;
  min-height: 42px;
  border-radius: 9999px;
  padding: 0;
  border: 1px solid #303132;
}}
button.atomos-dock-btn image {{
  -gtk-icon-size: 22px;
}}
window.atomos-chat-root.atomos-dark box.atomos-top-dock {{
  background: #121212;
}}
window.atomos-chat-root.atomos-dark button.atomos-dock-btn {{
  background: #121212;
  color: #ffffff;
}}
window.atomos-chat-root.atomos-light box.atomos-top-dock {{
  background: #f2f2f2;
  outline: 1px solid alpha(#000000, 0.15);
}}
window.atomos-chat-root.atomos-light button.atomos-dock-btn {{
  background: #f2f2f2;
  color: #121212;
}}
box.atomos-app-sheet-wrap {{
  margin: 18px 0 0 0;
  border-radius: 40px;
  border: 1px solid #303132;
}}
window.atomos-chat-root.atomos-dark box.atomos-app-sheet-wrap {{
  background: #121212;
}}
window.atomos-chat-root.atomos-light box.atomos-app-sheet-wrap {{
  background: #f2f2f2;
}}
scrolledwindow.atomos-app-sheet {{
  border-radius: 40px;
  background: transparent;
}}
button.atomos-app-tile {{
  min-width: 0;
  min-height: 0;
  padding: 0;
  background: transparent;
  color: inherit;
  border: none;
  box-shadow: none;
}}
button.atomos-app-tile:hover,
button.atomos-app-tile:active {{
  background: transparent;
  box-shadow: none;
}}
label.atomos-app-label {{
  color: inherit;
  font-size: 10px;
}}
",
        root_bg = root_bg,
        input_extra = input_extra,
        top_row_padding_top = top_row_padding_top
    )
}

pub fn install_css(desktop_like: bool) {
    if custom_css_disabled() {
        eprintln!("atomos-overview-chat-ui: custom CSS disabled by env");
        return;
    }
    let css = gtk::CssProvider::new();
    css.load_from_data(&stylesheet(desktop_like));
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::{custom_css_disabled, stylesheet};

    #[test]
    fn stylesheet_avoids_focus_within_selector_for_target_compat() {
        let desktop_css = stylesheet(true);
        let mobile_css = stylesheet(false);
        assert!(
            !desktop_css.contains(":focus-within"),
            "desktop CSS contains :focus-within, which crashes on target images"
        );
        assert!(
            !mobile_css.contains(":focus-within"),
            "mobile CSS contains :focus-within, which crashes on target images"
        );
    }

    #[test]
    fn input_frame_uses_border_not_outline() {
        let css = stylesheet(false);
        assert!(css.contains("scrolledwindow.atomos-chat-input"));
        assert!(css.contains("border: 1px solid alpha(#ffffff, 0.22);"));
    }

    #[test]
    fn css_disable_flag_defaults_to_off() {
        std::env::remove_var("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS");
        assert!(!custom_css_disabled());
    }

    #[test]
    fn css_disable_flag_honors_env() {
        std::env::set_var("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS", "1");
        assert!(custom_css_disabled());
        std::env::remove_var("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS");
    }
}

pub fn apply_theme_class(win: &adw::ApplicationWindow) {
    if env_flag_enabled(std::env::var(
        "ATOMOS_OVERVIEW_CHAT_UI_DISABLE_THEME_CLASS",
    )) {
        eprintln!("atomos-overview-chat-ui: theme class disabled by env");
        return;
    }
    // Avoid string-typed GObject property access here. Some target stacks emit
    // unstable GLib errors during early startup when querying settings this way.
    let prefers_dark = adw::StyleManager::default().is_dark();
    win.add_css_class(theme_class(prefers_dark));
}
