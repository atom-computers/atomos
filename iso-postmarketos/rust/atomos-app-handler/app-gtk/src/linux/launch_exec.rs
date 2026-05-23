//! Spawn `.desktop` apps via GIO (replaces Phosh `app-tracker.c` spawn path).

use gtk::gio;
use gtk::gio::prelude::*;

pub fn spawn_desktop_app(app_id: &str) -> Result<(), String> {
    let desktop_id = normalize_desktop_id(app_id);
    let app = gio::DesktopAppInfo::new(&desktop_id)
        .ok_or_else(|| format!("unknown desktop app id: {desktop_id}"))?;
    app.launch(&[], Option::<&gio::AppLaunchContext>::None)
        .map_err(|e| e.to_string())?;
    Ok(())
}

fn normalize_desktop_id(app_id: &str) -> String {
    if app_id.ends_with(".desktop") {
        app_id.to_string()
    } else {
        format!("{app_id}.desktop")
    }
}

#[cfg(test)]
mod tests {
    use super::normalize_desktop_id;

    #[test]
    fn normalize_appends_desktop_suffix() {
        assert_eq!(
            normalize_desktop_id("org.gnome.Calculator"),
            "org.gnome.Calculator.desktop"
        );
    }
}
