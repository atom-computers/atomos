use adw::prelude::*;
use gtk::gio;

mod app_grid;
mod config;
mod input;
mod logic;
mod overlay;
mod style;
mod ui;

fn main() -> anyhow::Result<()> {
    eprintln!("atomos-overview-chat-ui: main phase=begin");
    // Use NON_UNIQUE so foreground/manual invocations are debuggable even when
    // another instance is already registered. Launcher PID-guarding still
    // prevents duplicate background processes in normal shell lifecycle usage.
    let app = adw::Application::builder()
        .application_id("org.atomos.OverviewChatUi")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();
    eprintln!("atomos-overview-chat-ui: main phase=app-built");

    app.connect_startup(|_| {
        eprintln!("atomos-overview-chat-ui: main phase=startup-signal");
    });
    app.connect_activate(|app| {
        eprintln!("atomos-overview-chat-ui: main phase=activate-signal");
        ui::build_ui(app);
    });
    eprintln!("atomos-overview-chat-ui: main phase=before-run");
    app.run();
    eprintln!("atomos-overview-chat-ui: main phase=after-run");
    Ok(())
}
