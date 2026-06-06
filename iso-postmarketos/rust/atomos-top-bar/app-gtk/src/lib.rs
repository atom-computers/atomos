use atomos_top_bar_core::TopBarState;
use atomos_top_bar_core::dbus::start_dbus_listener;
use gtk::prelude::*;
use std::sync::{Arc, Mutex};

pub struct TopBarWidget {
    pub widget: gtk::Box,
}

impl TopBarWidget {
    pub fn new() -> Self {
        let state = Arc::new(Mutex::new(TopBarState::default()));

        // Spawn dbus listener in background
        let dbus_state = state.clone();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(start_dbus_listener(dbus_state));
        });

        let root = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        root.add_css_class("atomos-top-bar");
        root.set_height_request(32);

        // Install custom CSS for background, text, and icons
        install_css();

        // Dynamically track system dark/light theme preference
        let style_manager = adw::StyleManager::default();
        let root_clone = root.clone();
        let update_theme = move |manager: &adw::StyleManager| {
            let prefers_dark = manager.is_dark();
            if prefers_dark {
                root_clone.add_css_class("atomos-dark");
                root_clone.remove_css_class("atomos-light");
            } else {
                root_clone.add_css_class("atomos-light");
                root_clone.remove_css_class("atomos-dark");
            }
        };
        update_theme(&style_manager);
        style_manager.connect_dark_notify(update_theme);

        // LEFT: Signal + Carrier
        let left_box = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        let signal_icon = gtk::Image::from_icon_name("network-cellular-signal-none-symbolic");
        let carrier_label = gtk::Label::new(Some(""));
        carrier_label.add_css_class("caption");
        left_box.append(&signal_icon);
        left_box.append(&carrier_label);

        // CENTER: Spacer (empty)
        let center_box = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        center_box.set_hexpand(true);

        // RIGHT: Clock + Battery
        let right_box = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        right_box.set_halign(gtk::Align::End);
        let clock_label = gtk::Label::new(Some("00:00"));
        clock_label.add_css_class("caption");
        let battery_icon = gtk::Image::from_icon_name("battery-full-symbolic");
        right_box.append(&clock_label);
        right_box.append(&battery_icon);

        root.append(&left_box);
        root.append(&center_box);
        root.append(&right_box);

        // Update loop
        let signal_icon_clone = signal_icon.clone();
        let carrier_label_clone = carrier_label.clone();
        let clock_label_clone = clock_label.clone();
        let battery_icon_clone = battery_icon.clone();

        glib::timeout_add_seconds_local(1, move || {
            let s = state.lock().unwrap();

            // Update clock
            clock_label_clone.set_label(&s.current_time_str());

            // Update carrier
            carrier_label_clone.set_label(&s.carrier_name);

            // Update signal
            let sig_icon_name = match s.signal_bars {
                0 => "network-cellular-signal-none-symbolic",
                1 => "network-cellular-signal-weak-symbolic",
                2 => "network-cellular-signal-ok-symbolic",
                3 => "network-cellular-signal-good-symbolic",
                _ => "network-cellular-signal-excellent-symbolic",
            };
            signal_icon_clone.set_icon_name(Some(sig_icon_name));

            // Update battery
            let pct = (s.battery_level * 100.0) as i32;
            let level = if pct > 90 {
                "full"
            } else if pct > 60 {
                "good"
            } else if pct > 20 {
                "low"
            } else {
                "empty"
            };
            let charge = if s.is_charging { "-charging" } else { "" };
            let bat_icon_name = format!("battery-{}{}-symbolic", level, charge);
            battery_icon_clone.set_icon_name(Some(&bat_icon_name));

            glib::ControlFlow::Continue
        });

        Self { widget: root }
    }
}

fn install_css() {
    let css = r#"
        .atomos-top-bar {
            border-radius: 0px;
            padding: 0 28px;
        }

        /* Light Mode */
        .atomos-top-bar.atomos-light {
            background-color: rgba(242, 242, 242, 0.8);
            border: 1px solid rgba(242, 242, 242, 0);
        }
        .atomos-top-bar.atomos-light label,
        .atomos-top-bar.atomos-light image {
            color:rgb(0, 0, 0);
        }

        /* Dark Mode */
        .atomos-top-bar.atomos-dark {
            background-color: rgb(0, 0, 0);            
            border: 1px solid rgba(255, 255, 255, 0);
        }
        .atomos-top-bar.atomos-dark label,
        .atomos-top-bar.atomos-dark image {
            color: rgb(255, 255, 255);
        }
    "#;

    let provider = gtk::CssProvider::new();
    provider.load_from_data(css);

    if let Some(display) = gtk::gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    } else {
        eprintln!("atomos-top-bar: no default display available; CSS not installed");
    }
}
