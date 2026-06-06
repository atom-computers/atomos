use adw::prelude::*;
use gtk::prelude::*;
use gtk::gio;
use gtk4_layer_shell::{Edge, Layer, LayerShell};
use atomos_top_bar_app_gtk::TopBarWidget;

pub fn run() -> anyhow::Result<()> {
    let app = adw::Application::builder()
        .application_id("org.atomos.TopBar")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();

    app.connect_activate(|app| {
        let window = gtk::ApplicationWindow::builder()
            .application(app)
            .title("AtomOS Top Bar")
            .build();

        if gtk4_layer_shell::is_supported() {
            window.init_layer_shell();
            window.set_namespace(Some("atomos-top-bar"));
            window.set_layer(Layer::Top);
            
            window.set_anchor(Edge::Top, true);
            window.set_anchor(Edge::Left, true);
            window.set_anchor(Edge::Right, true);
            window.set_anchor(Edge::Bottom, false);
            
            // Set exclusive zone so window manager leaves space for it
            window.set_exclusive_zone(32);
        } else {
            eprintln!("atomos-top-bar: layer shell unsupported");
        }

        let top_bar = TopBarWidget::new();
        window.set_child(Some(&top_bar.widget));
        window.present();
    });

    app.run();
    Ok(())
}
