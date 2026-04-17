#[cfg(target_os = "linux")]
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};

#[cfg(target_os = "linux")]
fn prefer_on_demand_keyboard_mode() -> bool {
    matches!(
        std::env::var("ATOMOS_OVERVIEW_CHAT_UI_LAYER_KEYBOARD_ON_DEMAND").as_deref(),
        Ok("1")
    )
}

#[cfg(target_os = "linux")]
fn target_layer() -> Layer {
    match std::env::var("ATOMOS_OVERVIEW_CHAT_UI_LAYER")
        .unwrap_or_else(|_| "top".to_string())
        .to_ascii_lowercase()
        .as_str()
    {
        "overlay" => Layer::Overlay,
        "bottom" => Layer::Bottom,
        "background" => Layer::Background,
        _ => Layer::Top,
    }
}

#[cfg(target_os = "linux")]
pub fn configure_mobile_overlay_surface(win: &adw::ApplicationWindow) -> bool {
    if !gtk4_layer_shell::is_supported() {
        eprintln!("atomos-overview-chat-ui: layer-shell unsupported by compositor/session");
        return false;
    }
    // On Phosh, render as a layer-shell surface so it participates in shell stacking.
    win.init_layer_shell();
    win.set_namespace(Some("atomos-overview-chat-ui"));
    // Keep the surface behind launcher/top overlays by default.
    // Override with ATOMOS_OVERVIEW_CHAT_UI_LAYER=overlay|top|bottom|background.
    win.set_layer(target_layer());
    win.set_anchor(Edge::Left, true);
    win.set_anchor(Edge::Right, true);
    win.set_anchor(Edge::Bottom, true);
    // Fill full height in mobile mode; content layout keeps input at bottom.
    win.set_anchor(Edge::Top, true);
    // Some phosh stacks expose layer-shell v3 where OnDemand is unsupported.
    // Default to None for compatibility and allow explicit opt-in when needed.
    if prefer_on_demand_keyboard_mode() {
        eprintln!("atomos-overview-chat-ui: layer-shell keyboard=on-demand");
        win.set_keyboard_mode(KeyboardMode::OnDemand);
    } else {
        eprintln!("atomos-overview-chat-ui: layer-shell keyboard=none");
        win.set_keyboard_mode(KeyboardMode::None);
    }
    win.set_exclusive_zone(0);
    eprintln!("atomos-overview-chat-ui: layer-shell configured successfully");
    true
}

#[cfg(not(target_os = "linux"))]
pub fn configure_mobile_overlay_surface(_win: &adw::ApplicationWindow) -> bool {
    eprintln!("atomos-overview-chat-ui: layer-shell unsupported on non-linux target");
    false
}
