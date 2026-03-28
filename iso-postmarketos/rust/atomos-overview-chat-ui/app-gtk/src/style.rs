use gtk::gdk;
use gtk::prelude::*;

pub fn install_css(desktop_like: bool) {
    let top_row_padding_top = 8;
    let root_bg = if desktop_like {
        "background-color: alpha(#0b0f17, 0.92);"
    } else {
        // Mobile/overlay surfaces sit on top of existing UI; keep the root as a subtle
        // darkening rather than an obvious colored tint.
        "background-color: alpha(#000000, 0.22);"
    };
    let input_extra = "outline: 1px solid alpha(#ffffff, 0.22); outline-offset: -1px;";

    let css = gtk::CssProvider::new();
    css.load_from_data(&format!(
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
    ));
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}

pub fn apply_theme_class(win: &adw::ApplicationWindow) {
    let prefers_dark = gtk::Settings::default()
        .map(|settings| settings.property::<bool>("gtk-application-prefer-dark-theme"))
        .unwrap_or(true);
    if prefers_dark {
        win.add_css_class("atomos-dark");
    } else {
        win.add_css_class("atomos-light");
    }
}
