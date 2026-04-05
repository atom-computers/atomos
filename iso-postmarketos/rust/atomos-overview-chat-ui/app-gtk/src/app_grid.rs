use gtk::gio;
use gtk::gio::prelude::*;
use gtk::prelude::*;

fn app_label(app: &gio::AppInfo) -> String {
    app.id()
        .map(|id| id.trim_end_matches(".desktop").to_string())
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| "Application".to_string())
}

fn visible_apps() -> Vec<gio::AppInfo> {
    let mut apps: Vec<_> = gio::AppInfo::all()
        .into_iter()
        .filter(|app| app.should_show())
        .collect();
    // Some images expose malformed desktop entries. Avoid metadata accessors
    // that can fault in GLib for broken records and sort by safe id-derived label.
    apps.sort_by_key(|app| app_label(app).to_lowercase());
    apps
}

fn app_icons_enabled() -> bool {
    matches!(
        std::env::var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS").as_deref(),
        Ok("1")
    )
}

pub fn build_app_grid_sheet() -> gtk::ScrolledWindow {
    let flow = gtk::FlowBox::new();
    flow.set_selection_mode(gtk::SelectionMode::None);
    flow.set_homogeneous(false);
    flow.set_halign(gtk::Align::Fill);
    flow.set_row_spacing(4);
    flow.set_column_spacing(1);
    flow.set_min_children_per_line(4);
    flow.set_max_children_per_line(4);
    flow.set_margin_top(14);
    flow.set_margin_bottom(14);
    flow.set_margin_start(0);
    flow.set_margin_end(0);

    let load_icons = app_icons_enabled();
    for app in visible_apps() {
        let app_name = app_label(&app);
        let tile_btn = gtk::Button::new();
        tile_btn.add_css_class("atomos-app-tile");
        tile_btn.set_can_focus(false);
        tile_btn.set_hexpand(true);

        let tile_content = gtk::Box::new(gtk::Orientation::Vertical, 4);
        tile_content.set_halign(gtk::Align::Center);
        tile_content.set_valign(gtk::Align::Center);

        // Some device images include malformed icon metadata. Keep runtime safe
        // by defaulting to a known icon and requiring explicit opt-in for gicon.
        let icon = if load_icons {
            if let Some(gicon) = app.icon() {
                let img = gtk::Image::from_gicon(&gicon);
                img.set_pixel_size(40);
                img
            } else {
                let img = gtk::Image::from_icon_name("application-x-executable-symbolic");
                img.set_pixel_size(40);
                img
            }
        } else {
            let img = gtk::Image::from_icon_name("application-x-executable-symbolic");
            img.set_pixel_size(40);
            img
        };

        let label = gtk::Label::new(Some(&app_name));
        label.add_css_class("atomos-app-label");
        label.set_wrap(true);
        label.set_wrap_mode(gtk::pango::WrapMode::WordChar);
        label.set_justify(gtk::Justification::Center);
        label.set_max_width_chars(10);

        tile_content.append(&icon);
        tile_content.append(&label);
        tile_btn.set_child(Some(&tile_content));

        let app_for_launch = app.clone();
        let app_name_for_launch = app_name.clone();
        tile_btn.connect_clicked(move |_| {
            if let Err(err) = app_for_launch.launch(&[], Option::<&gio::AppLaunchContext>::None) {
                eprintln!(
                    "atomos-overview-chat-ui: failed launching {}: {err}",
                    app_name_for_launch
                );
            }
        });
        flow.insert(&tile_btn, -1);
    }

    let scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .min_content_height(220)
        .hexpand(true)
        .vexpand(true)
        .build();
    scroller.set_propagate_natural_width(false);
    scroller.set_min_content_width(0);
    scroller.add_css_class("atomos-app-sheet");
    scroller.set_child(Some(&flow));
    scroller
}
