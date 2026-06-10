//! AtomOS home surface GTK4 binary.
//!
//! Layer-shell home surface that replaces Phosh's PhoshHome widget.
//! Provides fold/unfold drag gesture, chat entry, home bar, and D-Bus IPC.

mod linux;

fn main() {
    use gtk::prelude::*;

    eprintln!("atomos-home: starting");

    let app = gtk::Application::builder()
        .application_id("org.atomos.Home")
        .build();

    app.connect_activate(|app| {
        let _window = linux::home_surface::create_home_window(app);
        eprintln!("atomos-home: window created");
    });

    app.run();
}