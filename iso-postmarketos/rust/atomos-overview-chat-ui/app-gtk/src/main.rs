use adw::prelude::*;

mod app_grid;
mod config;
mod input;
mod logic;
mod overlay;
mod style;
mod ui;

fn main() -> anyhow::Result<()> {
    eprintln!("atomos-overview-chat-ui: main phase=begin");
    let app = adw::Application::builder()
        .application_id("org.atomos.OverviewChatUi")
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
