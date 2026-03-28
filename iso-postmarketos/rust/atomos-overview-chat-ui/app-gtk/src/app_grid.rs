use gtk::gio;
use gtk::gio::prelude::*;
use gtk::prelude::*;

fn visible_apps() -> Vec<gio::AppInfo> {
    let mut apps: Vec<_> = gio::AppInfo::all()
        .into_iter()
        .filter(|app| app.should_show())
        .collect();
    apps.sort_by_key(|app| app.display_name().to_string().to_lowercase());
    apps
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

    for app in visible_apps() {
        let tile_btn = gtk::Button::new();
        tile_btn.add_css_class("atomos-app-tile");
        tile_btn.set_can_focus(false);
        tile_btn.set_hexpand(true);

        let tile_content = gtk::Box::new(gtk::Orientation::Vertical, 4);
        tile_content.set_halign(gtk::Align::Center);
        tile_content.set_valign(gtk::Align::Center);

        let icon = if let Some(gicon) = app.icon() {
            let img = gtk::Image::from_gicon(&gicon);
            img.set_pixel_size(40);
            img
        } else {
            let img = gtk::Image::from_icon_name("application-x-executable-symbolic");
            img.set_pixel_size(40);
            img
        };

        let label = gtk::Label::new(Some(&app.display_name()));
        label.add_css_class("atomos-app-label");
        label.set_wrap(true);
        label.set_wrap_mode(gtk::pango::WrapMode::WordChar);
        label.set_justify(gtk::Justification::Center);
        label.set_max_width_chars(10);

        tile_content.append(&icon);
        tile_content.append(&label);
        tile_btn.set_child(Some(&tile_content));

        let app_for_launch = app.clone();
        tile_btn.connect_clicked(move |_| {
            if let Err(err) = app_for_launch.launch(&[], Option::<&gio::AppLaunchContext>::None) {
                eprintln!(
                    "atomos-overview-chat-ui: failed launching {}: {err}",
                    app_for_launch.display_name()
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
