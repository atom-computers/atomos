use std::path::Path;
use std::process::Command;

use atomos_overview_chat_ui::{
    decide_launch_invocation, launch_invocation_argv, resolve_app_handler_launcher,
    LaunchInvocation, APP_HANDLER_LAUNCHER_ENV, APP_HANDLER_LAUNCHER_PATH,
};
use gtk::gio;
use gtk::gio::prelude::*;
use gtk::prelude::*;

fn normalized_id_label(id: &str) -> String {
    let base = id.trim_end_matches(".desktop");
    let last = base.rsplit('.').next().unwrap_or(base);
    let cleaned = last
        .replace(['-', '_'], " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if cleaned.is_empty() {
        return "Application".to_string();
    }
    let mut chars = cleaned.chars();
    let Some(first) = chars.next() else {
        return "Application".to_string();
    };
    let mut out = String::new();
    out.extend(first.to_uppercase());
    out.push_str(chars.as_str());
    out
}

fn app_label(app: &gio::AppInfo) -> String {
    let display_name = app.display_name();
    if !display_name.trim().is_empty() {
        return display_name.to_string();
    }
    let name = app.name();
    if !name.trim().is_empty() {
        return name.to_string();
    }
    app.id()
        .map(|id| normalized_id_label(&id))
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
    !matches!(
        std::env::var("ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS").as_deref(),
        Ok("0")
    )
}

#[cfg(target_os = "linux")]
fn app_icon_from_desktop_id(id: &str) -> Option<gio::Icon> {
    let desktop = gio::DesktopAppInfo::new(id)?;
    desktop.icon()
}

#[cfg(not(target_os = "linux"))]
fn app_icon_from_desktop_id(_id: &str) -> Option<gio::Icon> {
    None
}

fn app_icon(app: &gio::AppInfo) -> Option<gio::Icon> {
    if let Some(icon) = app.icon() {
        return Some(icon);
    }
    let id = app.id()?;
    // Some images expose AppInfo without icon metadata on the first object.
    // Retry via DesktopAppInfo using both raw id and normalized .desktop id.
    if let Some(icon) = app_icon_from_desktop_id(&id) {
        return Some(icon);
    }
    if !id.ends_with(".desktop") {
        let desktop_id = format!("{id}.desktop");
        if let Some(icon) = app_icon_from_desktop_id(&desktop_id) {
            return Some(icon);
        }
    }
    None
}

/// Dispatch a tile click to either the `atomos-app-handler` launcher
/// (preferred — round-trips through the same lifecycle Phosh's
/// `app-grid-button.c:activate_cb` uses) or `gio::AppInfo::launch`
/// (warn-and-skip fallback for hosts without the rootfs overlay).
fn tile_click_launch(app: &gio::AppInfo, app_name: &str) {
    let env_override = std::env::var(APP_HANDLER_LAUNCHER_ENV).ok();
    let launcher = resolve_app_handler_launcher(env_override.as_deref(), |p: &Path| p.is_file());

    let app_id = app.id().map(|s| s.to_string()).unwrap_or_default();
    if app_id.is_empty() {
        eprintln!(
            "atomos-overview-chat-ui: tile click for '{app_name}' has empty app id; \
             skipping atomos-app-handler dispatch"
        );
        gio_fallback_launch(app, app_name);
        return;
    }

    let invocation = decide_launch_invocation(&app_id, launcher.as_deref());
    match invocation {
        LaunchInvocation::DispatchAppHandler { .. } => {
            let argv = launch_invocation_argv(&invocation);
            let mut iter = argv.into_iter();
            let Some(program) = iter.next() else {
                eprintln!(
                    "atomos-overview-chat-ui: empty argv from launch_invocation_argv \
                     for '{app_name}' — falling back to gio"
                );
                gio_fallback_launch(app, app_name);
                return;
            };
            let args: Vec<String> = iter.collect();
            eprintln!(
                "atomos-overview-chat-ui: dispatching launch via {program} {args:?} \
                 (default path={APP_HANDLER_LAUNCHER_PATH})"
            );
            if let Err(err) = Command::new(&program).args(&args).spawn() {
                eprintln!(
                    "atomos-overview-chat-ui: spawn of {program} failed for '{app_name}': {err}; \
                     falling back to gio"
                );
                gio_fallback_launch(app, app_name);
            }
        }
        LaunchInvocation::DirectGioFallback { .. } => {
            // Phosh `home.c:276-285` parity: warn-and-skip — keep launching
            // the app, just don't dispatch the lifecycle round-trip.
            eprintln!(
                "atomos-overview-chat-ui: {APP_HANDLER_LAUNCHER_PATH} not present; \
                 falling back to gio for '{app_name}'"
            );
            gio_fallback_launch(app, app_name);
        }
    }
}

fn gio_fallback_launch(app: &gio::AppInfo, app_name: &str) {
    if let Err(err) = app.launch(&[], Option::<&gio::AppLaunchContext>::None) {
        eprintln!("atomos-overview-chat-ui: failed launching {app_name}: {err}");
    }
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
            if let Some(gicon) = app_icon(&app) {
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
            tile_click_launch(&app_for_launch, &app_name_for_launch);
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

#[cfg(test)]
mod tests {
    use super::normalized_id_label;

    #[test]
    fn normalized_id_label_uses_last_segment() {
        assert_eq!(normalized_id_label("com.app.word.desktop"), "Word");
    }

    #[test]
    fn normalized_id_label_humanizes_separators() {
        assert_eq!(normalized_id_label("org.gnome.file-roller"), "File roller");
    }
}
