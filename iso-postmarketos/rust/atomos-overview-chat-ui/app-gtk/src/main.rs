use adw::prelude::*;

mod app_grid;
mod config;
mod input;
mod overlay;
mod style;
mod ui;

fn main() -> anyhow::Result<()> {
    let app = adw::Application::builder()
        .application_id("org.atomos.OverviewChatUi")
        .build();

    app.connect_activate(ui::build_ui);
    app.run();
    Ok(())
}
