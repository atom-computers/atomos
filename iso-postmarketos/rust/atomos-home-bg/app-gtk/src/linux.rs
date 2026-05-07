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

    // Transparent webview background lets the underlying GTK widget /
    // layer-shell surface show through pixels the webview does not paint.
    // The shipped placeholder paints an opaque #0a0a0a base via CSS, so
    // the user sees solid dark even before WebGL uploads its first frame.
    let transparent = gdk::RGBA::new(0.0, 0.0, 0.0, 0.0);
    webview.set_background_color(&transparent);

    apply_webview_settings(&webview);

    webview.load_uri(url);
    webview
}

/// Configure `WebKitSettings` to actually let `event-horizon.js` get a
/// WebGL context and pipe console.log/console.error into our log file.
///
/// Without this, webkit2gtk-6.0's defaults combined with the launcher's
/// `LIBGL_ALWAYS_SOFTWARE=1` + `WEBKIT_DISABLE_DMABUF_RENDERER=1` cause
/// `hardware-acceleration-policy=ON_DEMAND` to refuse to set up the
/// GPU process — at which point `canvas.getContext("webgl")` returns
/// `null` and the home-bg surface is just the CSS dark base.
///
/// Each setting below is named (rather than collapsed into a builder)
/// so the failure mode is greppable in `/run/user/<uid>/atomos-home-bg.log`
/// when `enable-write-console-messages-to-stdout` later forwards JS
/// diagnostics there.
fn apply_webview_settings(webview: &webkit6::WebView) {
    // `WebViewExt::settings()` returns the *live* settings object
    // already attached to the webview; mutating it applies in place.
    // (`Option` wrapper is theoretical — webkit2gtk always populates
    // it during `WebView::new()`.) If we somehow get None we attach a
    // fresh one so the caller's set_* calls are not silently lost.
    let settings = match webkit6::prelude::WebViewExt::settings(webview) {
        Some(s) => s,
        None => {
            let s = webkit6::Settings::new();
            webview.set_settings(&s);
            s
        }
    };

    // Explicit even though the webkit2gtk-6.0 default is `true` — being
    // explicit guards against future webkit version drift / Alpine
    // packaging variations turning WebGL off.
    settings.set_enable_webgl(true);

    // Force GL even when WebKit's GPU heuristics would prefer
    // non-accelerated mode (which silently disables WebGL). Without
    // ALWAYS, software-only GL stacks (QEMU virt, headless Mesa) get
    // classified as "unhealthy" and the GPU process never starts.
    settings.set_hardware_acceleration_policy(webkit6::HardwareAccelerationPolicy::Always);

    // Forward `console.log` / `console.warn` / `console.error` from
    // event-horizon.js into stdout, which the launcher captures into
    // `$XDG_RUNTIME_DIR/atomos-home-bg.log`. Critical for diagnosing
    // the on-device failure modes the JS reports.
    settings.set_enable_write_console_messages_to_stdout(true);

    // Developer extras (right-click → inspect, remote inspector when
    // WEBKIT_INSPECTOR_SERVER is set) cost nothing on a non-interactive
    // surface and make on-device debugging tractable.
    settings.set_enable_developer_extras(true);

    // Permit JS — the placeholder content depends on it.
    settings.set_enable_javascript(true);

    eprintln!(
        "atomos-home-bg: webkit settings: webgl={} hw-accel={:?} \
         console-to-stdout={} dev-extras={} js={}",
        settings.enables_webgl(),
        settings.hardware_acceleration_policy(),
        settings.enables_write_console_messages_to_stdout(),
        settings.enables_developer_extras(),
        settings.enables_javascript(),
    );
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
