use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};

pub fn configure_mobile_overlay_surface(win: &adw::ApplicationWindow) {
    if !gtk4_layer_shell::is_supported() {
        return;
    }
    // On Phosh, render as a layer-shell surface so it participates in shell stacking.
    win.init_layer_shell();
    win.set_namespace(Some("atomos-overview-chat-ui"));
    // Use Overlay to make sure this surface can receive pointer input above
    // the shell UI. Top can be visually present but non-interactive in some stacks.
    win.set_layer(Layer::Overlay);
    win.set_anchor(Edge::Left, true);
    win.set_anchor(Edge::Right, true);
    win.set_anchor(Edge::Bottom, true);
    // Fill full height in mobile mode; content layout keeps input at bottom.
    win.set_anchor(Edge::Top, true);
    // Require input interactivity so dock/button taps are delivered.
    win.set_keyboard_mode(KeyboardMode::OnDemand);
    win.set_exclusive_zone(0);
}
