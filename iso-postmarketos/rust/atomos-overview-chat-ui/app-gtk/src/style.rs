use gtk::gdk;
use gtk::prelude::*;

use crate::logic::{env_flag_enabled, theme_class};

fn custom_css_disabled() -> bool {
    env_flag_enabled(std::env::var("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS"))
}

/// Always-on CSS for the layer stack under the chat UI. The window node
/// alone is not enough: the content `GtkBox` / `GtkOverlay` / `GtkRevealer`
/// are often painted with the theme's solid `.view` / default fill (reads
/// as a black sheet over `atomos-home-bg`).
///
/// We do *not* use `!important` here — GTK4's CSS parser is a strict
/// subset of CSS3 and rejects `!important` as junk after the value,
/// silently dropping the entire declaration (the
/// `Gtk-WARNING: Theme parser error: <data>:N:M-M+1: Junk at end of value
/// for background` lines you'll see in
/// `/run/user/<uid>/atomos-overview-chat-ui.log` if `!important` is
/// reintroduced). To beat Adwaita's per-widget background we instead
/// rely on the provider's registration priority: this CSS is installed
/// at `STYLE_PROVIDER_PRIORITY_APPLICATION` (600) which is strictly
/// higher than `STYLE_PROVIDER_PRIORITY_THEME` (200), so any matching
/// selector here wins regardless of `!important`. A regression test in
/// the `tests` module pins this — see
/// `css_strings_must_not_use_important_keyword_gtk4_rejects_it`.
///
/// The hardware-safety `DISABLE_CUSTOM_CSS` flag does not gate this — it
/// only skips the decorative/themed `stylesheet()`.
fn transparency_stylesheet() -> &'static str {
    r#"
window.atomos-chat-root {
  background-color: transparent;
}
window.atomos-chat-root box.atomos-chat-outer {
  background: transparent;
  background-color: transparent;
}
window.atomos-chat-root box.atomos-chat-fill {
  background: transparent;
}
window.atomos-chat-root overlay {
  background: transparent;
}
window.atomos-chat-root revealer {
  background: transparent;
}
window.atomos-chat-root box.atomos-top-row {
  background: transparent;
}
"#
}

fn stylesheet(_desktop_like: bool) -> String {
    let top_row_padding_top = 8;
    // Keep the full layer-shell window transparent; atomos-home-bg owns the
    // visual background. Individual controls/sheets below provide their own
    // local tint.
    let root_bg = "background-color: transparent;";
    let input_extra = "box-shadow: none;";
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
  background: alpha(#ffffff, 0.92);
  border: 1px solid alpha(#000000, 0.18);
  {input_extra}
}}
textview.atomos-chat-input {{
  background-color: transparent;
  color: #121212;
  caret-color: #121212;
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
window.atomos-chat-root.atomos-dark scrolledwindow.atomos-chat-input {{
  background: alpha(#151923, 0.58);
  border: 1px solid alpha(#ffffff, 0.22);
}}
window.atomos-chat-root.atomos-dark textview.atomos-chat-input {{
  color: #ffffff;
  caret-color: #ffffff;
}}
window.atomos-chat-root.atomos-dark button.atomos-dock-btn {{
  background: #121212;
  color: #ffffff;
}}
window.atomos-chat-root.atomos-light box.atomos-top-dock {{
  background: #f2f2f2;
  outline: 1px solid alpha(#000000, 0.15);
}}
window.atomos-chat-root.atomos-light scrolledwindow.atomos-chat-input {{
  background: alpha(#ffffff, 0.92);
  border: 1px solid alpha(#000000, 0.18);
}}
window.atomos-chat-root.atomos-light textview.atomos-chat-input {{
  color: #121212;
  caret-color: #121212;
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
    let Some(display) = gdk::Display::default() else {
        return;
    };

    // Provider 1: always-on real transparency. Registered at `APPLICATION` so
    // it *wins over* `THEME` (FALLBACK is too low: theme’s opaque @window_bg
    // would paint on top and hide atomos-home-bg’s webview). When decorative
    // CSS is enabled, the second provider loads the same priority after this
    // and overrides `window.atomos-chat-root` with a subtle alpha tint.
    let transparency = gtk::CssProvider::new();
    transparency.load_from_data(transparency_stylesheet());
    gtk::style_context_add_provider_for_display(
        &display,
        &transparency,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    if custom_css_disabled() {
        eprintln!(
            "atomos-overview-chat-ui: decorative CSS disabled by env (transparency stays on)"
        );
        return;
    }

    // Same priority as transparency: added after so more specific / same
    // selector rules in `stylesheet` override the default transparent root.
    let css = gtk::CssProvider::new();
    css.load_from_data(&stylesheet(desktop_like));
    gtk::style_context_add_provider_for_display(
        &display,
        &css,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
}

#[cfg(test)]
mod tests {
    use super::{custom_css_disabled, stylesheet, transparency_stylesheet};
    use std::sync::Mutex;

    static DISABLE_CUSTOM_CSS_LOCK: Mutex<()> = Mutex::new(());

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
        assert!(css.contains("window.atomos-chat-root.atomos-dark scrolledwindow.atomos-chat-input"));
        assert!(css.contains("window.atomos-chat-root.atomos-light scrolledwindow.atomos-chat-input"));
        assert!(css.contains("border: 1px solid alpha(#ffffff, 0.22);"));
        assert!(css.contains("border: 1px solid alpha(#000000, 0.18);"));
    }

    #[test]
    fn css_strings_must_not_use_important_keyword_gtk4_rejects_it() {
        // GTK4's CSS parser is a strict subset of CSS3 — it does NOT
        // accept `!important`. When the parser hits ` !important;`, it
        // emits `Theme parser error: <data>:N:M-M+1: Junk at end of
        // value for background` to stderr AND **discards the entire
        // declaration**. The result is the chat-ui layer-shell window
        // ends up with the Adwaita default solid `.view` background
        // painted over the supposedly-transparent layer, hiding
        // atomos-home-bg's webview behind an opaque sheet — i.e. the
        // exact "chat-ui doesn't load on reboot" symptom captured in
        // /run/user/<uid>/atomos-overview-chat-ui.log:
        //
        //     Gtk-WARNING: Theme parser error: <data>:6:27-28:
        //                  Junk at end of value for background
        //
        // The provider is already registered at
        // STYLE_PROVIDER_PRIORITY_APPLICATION (600) which beats
        // PRIORITY_THEME (200), so `!important` adds nothing that
        // priority + selector specificity don't already deliver — and
        // by being rejected outright it actively breaks the rule.
        // Pin both CSS strings against the literal so a future edit
        // can't reintroduce the keyword.
        let transparency = transparency_stylesheet();
        let decorative_mobile = stylesheet(false);
        let decorative_desktop = stylesheet(true);
        for (label, body) in [
            ("transparency_stylesheet()", transparency),
            ("stylesheet(mobile)", decorative_mobile.as_str()),
            ("stylesheet(desktop)", decorative_desktop.as_str()),
        ] {
            assert!(
                !body.contains("!important"),
                "{label} contains `!important`, which GTK4's CSS parser \
                 rejects as junk and silently discards the whole \
                 declaration — see /run/user/<uid>/atomos-overview-chat-ui.log \
                 for `Theme parser error: <data>:N:M: Junk at end of value`. \
                 Use STYLE_PROVIDER_PRIORITY_APPLICATION + selector \
                 specificity instead."
            );
        }
    }

    #[test]
    fn transparency_stylesheet_is_minimal_and_translucent() {
        // The always-on provider: root + main layout nodes stay non-opaque so
        // atomos-home-bg shows through. Decorative / crashy selectors stay in
        // `stylesheet()`.
        let css = transparency_stylesheet();
        assert!(css.contains("window.atomos-chat-root"));
        assert!(css.contains("box.atomos-chat-outer"));
        assert!(css.contains("overlay"));
        assert!(
            css.contains("background-color: transparent"),
            "root must be transparent; decorative CSS adds tint when enabled"
        );
        assert!(!css.contains(":focus-within"));
        assert!(!css.contains("@keyframes"));
    }

    #[test]
    fn decorative_stylesheet_keeps_root_transparent() {
        let desktop_css = stylesheet(true);
        let mobile_css = stylesheet(false);

        assert!(desktop_css.contains("window.atomos-chat-root"));
        assert!(desktop_css.contains("background-color: transparent;"));
        assert!(mobile_css.contains("window.atomos-chat-root"));
        assert!(mobile_css.contains("background-color: transparent;"));
        assert!(!mobile_css.contains("alpha(#000000, 0.22)"));
        assert!(!desktop_css.contains("alpha(#0b0f17, 0.92)"));
    }

    #[test]
    fn css_disable_flag_defaults_to_off() {
        let _g = DISABLE_CUSTOM_CSS_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::remove_var("ATOMOS_OVERVIEW_CHAT_UI_DISABLE_CUSTOM_CSS");
        assert!(!custom_css_disabled());
    }

    #[test]
    fn css_disable_flag_honors_env() {
        let _g = DISABLE_CUSTOM_CSS_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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
