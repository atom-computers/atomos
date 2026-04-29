//! Linux implementation: GTK4 + webkit2gtk-6.0 surface on wlr-layer-shell.
//!
//! The whole thing is deliberately small — all policy lives in the core crate
//! (`atomos_home_bg`). This file just wires policy → live widgets.

use atomos_home_bg::{
    compose_surface_config, parse_lifecycle_action, EnvInputs, InputPolicy, LayerTarget,
    LifecycleAction, SurfaceConfig, LAYER_SHELL_NAMESPACE,
};
use gtk::cairo;
use gtk::gdk;
use gtk::gio;
use gtk::prelude::*;
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use webkit6::prelude::*;

pub fn run() -> anyhow::Result<()> {
    let action = parse_lifecycle_action(std::env::args().nth(1).as_deref());
    eprintln!("atomos-home-bg: lifecycle={:?}", action);

    // Lifecycle parity with overview-chat-ui: --hide exits cleanly so launcher
    // stop paths work even if we later add a running-instance guard.
    if matches!(action, LifecycleAction::Hide) {
        eprintln!("atomos-home-bg: --hide received; exiting");
        return Ok(());
    }
    let _ = action; // Show == Run for a wallpaper-style surface.

    let cfg = compose_surface_config(&EnvInputs::from_process_env());
    eprintln!(
        "atomos-home-bg: cfg url={:?} layer={:?} input={:?} runtime_enabled={}",
        cfg.url, cfg.layer, cfg.input, cfg.runtime_enabled
    );

    if !cfg.runtime_enabled {
        eprintln!(
            "atomos-home-bg: ATOMOS_HOME_BG_ENABLE_RUNTIME!=1; exiting without presenting a surface"
        );
        return Ok(());
    }

    let app = gtk::Application::builder()
        .application_id("org.atomos.HomeBg")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();

    let cfg_for_activate = cfg.clone();
    app.connect_activate(move |app| build_ui(app, &cfg_for_activate));

    app.run();
    Ok(())
}

fn build_ui(app: &gtk::Application, cfg: &SurfaceConfig) {
    let window = gtk::ApplicationWindow::builder()
        .application(app)
        .title("AtomOS Home Background")
        .build();

    if !gtk4_layer_shell::is_supported() {
        eprintln!(
            "atomos-home-bg: layer-shell unsupported by this compositor; exiting to avoid \
             falling back to a decorated toplevel window"
        );
        app.quit();
        return;
    }

    configure_layer_shell(&window, cfg.layer);

    let webview = build_webview(&cfg.url);
    window.set_child(Some(&webview));

    // Input policy must be applied after the surface exists. On Wayland
    // `gdk::Surface` only shows up once the window is realized/mapped.
    if matches!(cfg.input, InputPolicy::NonInteractive) {
        apply_non_interactive_input_region(&window);
    }

    window.present();
    eprintln!("atomos-home-bg: presented");
}

fn configure_layer_shell(window: &gtk::ApplicationWindow, layer: LayerTarget) {
    window.init_layer_shell();
    window.set_namespace(Some(LAYER_SHELL_NAMESPACE));

    let gtk_layer = match layer {
        LayerTarget::Background => Layer::Background,
        LayerTarget::Bottom => Layer::Bottom,
        LayerTarget::Top => Layer::Top,
        LayerTarget::Overlay => Layer::Overlay,
    };
    window.set_layer(gtk_layer);

    for edge in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right] {
        window.set_anchor(edge, true);
    }

    // -1 tells the compositor not to reserve usable area for us. Positive
    // would push other surfaces; 0 would keep it in the "no exclusion" zone
    // but still participate. -1 is the correct wallpaper choice.
    window.set_exclusive_zone(-1);

    // Keep keyboard events routed to the app above us (phosh/overview-chat-ui).
    window.set_keyboard_mode(KeyboardMode::None);

    eprintln!(
        "atomos-home-bg: layer-shell configured successfully (namespace={LAYER_SHELL_NAMESPACE} layer={layer:?})"
    );
}

fn build_webview(url: &str) -> webkit6::WebView {
    let webview = webkit6::WebView::new();

    let transparent = gdk::RGBA::new(0.0, 0.0, 0.0, 0.0);
    webview.set_background_color(&transparent);

    webview.load_uri(url);
    webview
}

fn apply_non_interactive_input_region(window: &gtk::ApplicationWindow) {
    // `cairo::Region::create()` in gtk4-rs's cairo wrapper is infallible —
    // it always returns an empty Region. An empty Wayland input region means
    // pointer/touch events fall through this surface to whatever lower
    // layer-shell layer is below us in the compositor stack.
    let try_apply = |w: &gtk::ApplicationWindow| -> bool {
        let Some(surface) = w.surface() else {
            return false;
        };
        let region = cairo::Region::create();
        surface.set_input_region(&region);
        eprintln!("atomos-home-bg: input region cleared (non-interactive)");
        true
    };

    // Surface may already exist if the widget tree was realized synchronously.
    if try_apply(window) {
        return;
    }

    // Otherwise wait for map — gdk::Surface only materializes once the window
    // has been placed on a Wayland output.
    let window_for_map = window.clone();
    window.connect_map(move |_| {
        if !try_apply(&window_for_map) {
            eprintln!(
                "atomos-home-bg: map fired without gdk::Surface available; skipping input region"
            );
        }
    });
}
