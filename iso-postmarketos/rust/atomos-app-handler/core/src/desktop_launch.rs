//! Desktop-entry launch classification for the Firefox-vs-Console split.
//!
//! Exec-based apps (Firefox ESR) spawn as children and inherit
//! `WAYLAND_DISPLAY` from the app-handler process. DBusActivatable apps
//! (GNOME Console, Settings, …) activate via the session bus and need a
//! [`GdkAppLaunchContext`](https://docs.gtk.org/gdk4/class.AppLaunchContext.html)
//! so GLib attaches the XDG activation token — otherwise GIO logs success
//! but nothing appears on screen.

/// Minimal excerpt from `firefox-esr.desktop` on the device image.
pub const FIXTURE_FIREFOX_ESR_DESKTOP: &str = r#"[Desktop Entry]
Exec=/usr/lib/firefox-esr/firefox-esr %u
StartupNotify=true
Type=Application
"#;

/// Minimal excerpt from `org.gnome.Console.desktop` on the device image.
pub const FIXTURE_GNOME_CONSOLE_DESKTOP: &str = r#"[Desktop Entry]
Type=Application
Name=Console
Exec=kgx
DBusActivatable=true
"#;

/// Device image uses `--gapplication-service` in the dbus service file.
pub const FIXTURE_GNOME_CONSOLE_SERVICE_DAEMON: &str = r#"[D-BUS Service]
Name=org.gnome.Console
Exec=/usr/bin/kgx --gapplication-service
"#;

/// Representative ids from the QEMU app grid regression.
pub const APP_ID_FIREFOX_ESR: &str = "firefox-esr.desktop";
pub const APP_ID_GNOME_CONSOLE: &str = "org.gnome.Console.desktop";

/// Session env vars dbus-daemon must copy into DBusActivatable service processes.
/// Exec-based apps inherit these from the spawner; DBus apps do not unless this
/// list is pushed via `dbus-update-activation-environment` before Activate.
pub const DBUS_ACTIVATION_SESSION_ENV_VARS: &[&str] = &[
    "WAYLAND_DISPLAY",
    "XDG_RUNTIME_DIR",
    "GDK_BACKEND",
    "XDG_CURRENT_DESKTOP",
];

pub fn dbus_activation_env_var_names_present<'a>(
    environ: &'a [(&'a str, &'a str)],
) -> Vec<&'static str> {
    DBUS_ACTIVATION_SESSION_ENV_VARS
        .iter()
        .copied()
        .filter(|key| {
            environ
                .iter()
                .any(|(k, v)| *k == *key && !v.is_empty())
        })
        .collect()
}

pub fn dbus_service_basename(desktop_id: &str) -> &str {
    crate::launch::strip_app_id_suffix(desktop_id)
}

pub fn default_dbus_service_path(desktop_id: &str) -> String {
    format!(
        "/usr/share/dbus-1/services/{}.service",
        dbus_service_basename(desktop_id)
    )
}

/// Parse `Exec=` from a `/usr/share/dbus-1/services/*.service` file.
pub fn parse_dbus_service_exec(service_ini: &str) -> Option<String> {
    service_ini.lines().find_map(|line| {
        let trimmed = line.trim();
        trimmed
            .strip_prefix("Exec=")
            .map(str::trim)
            .filter(|exec| !exec.is_empty())
            .map(str::to_string)
    })
}

/// True when the dbus `.service` file Exec starts a bus-activatable daemon, not a window.
pub fn dbus_service_exec_is_daemon_only(exec: &str) -> bool {
    exec.contains("--gapplication-service")
}

pub fn should_spawn_dbus_service_exec_directly(service_exec: &str) -> bool {
    !dbus_service_exec_is_daemon_only(service_exec)
}

/// Primary `[Desktop Entry]` `Exec=` line (not action-group entries).
pub fn parse_desktop_entry_primary_exec(desktop_contents: &str) -> Option<String> {
    let mut in_desktop_entry = false;
    for line in desktop_contents.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_desktop_entry = trimmed.eq_ignore_ascii_case("[Desktop Entry]");
            continue;
        }
        if !in_desktop_entry {
            continue;
        }
        if let Some(exec) = trimmed.strip_prefix("Exec=") {
            let exec = exec.trim();
            if !exec.is_empty() {
                return Some(exec.to_string());
            }
        }
    }
    None
}

/// True when a desktop `Exec=` spawns a visible app (not a dbus daemon stub).
pub fn desktop_exec_is_spawnable_for_window(exec: &str) -> bool {
    !exec.trim().is_empty() && !dbus_service_exec_is_daemon_only(exec)
}

pub fn desktop_entry_has_exec(desktop_contents: &str) -> bool {
    desktop_contents
        .lines()
        .any(|line| line.trim_start().starts_with("Exec="))
}

pub fn desktop_entry_is_dbus_activatable(desktop_contents: &str) -> bool {
    desktop_contents.lines().any(|line| {
        let trimmed = line.trim();
        trimmed.eq_ignore_ascii_case("DBusActivatable=true")
    })
}

/// DBus-activatable entries must launch through GdkAppLaunchContext (Phosh parity).
pub fn launch_requires_gdk_app_launch_context(desktop_contents: &str) -> bool {
    desktop_entry_is_dbus_activatable(desktop_contents)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn regression_firefox_is_exec_not_dbus_activatable() {
        assert!(desktop_entry_has_exec(FIXTURE_FIREFOX_ESR_DESKTOP));
        assert!(!desktop_entry_is_dbus_activatable(FIXTURE_FIREFOX_ESR_DESKTOP));
        assert!(!launch_requires_gdk_app_launch_context(FIXTURE_FIREFOX_ESR_DESKTOP));
    }

    #[test]
    fn regression_gnome_console_is_dbus_activatable_with_window_exec() {
        assert!(desktop_entry_has_exec(FIXTURE_GNOME_CONSOLE_DESKTOP));
        assert!(desktop_entry_is_dbus_activatable(FIXTURE_GNOME_CONSOLE_DESKTOP));
        assert!(launch_requires_gdk_app_launch_context(FIXTURE_GNOME_CONSOLE_DESKTOP));
        assert_eq!(
            parse_desktop_entry_primary_exec(FIXTURE_GNOME_CONSOLE_DESKTOP).as_deref(),
            Some("kgx"),
        );
        assert!(desktop_exec_is_spawnable_for_window("kgx"));
        assert!(!desktop_exec_is_spawnable_for_window(
            "/usr/bin/kgx --gapplication-service"
        ));
    }

    #[test]
    fn dbus_activation_env_vars_include_wayland_and_runtime_dir() {
        assert!(DBUS_ACTIVATION_SESSION_ENV_VARS.contains(&"WAYLAND_DISPLAY"));
        assert!(DBUS_ACTIVATION_SESSION_ENV_VARS.contains(&"XDG_RUNTIME_DIR"));
        let present = dbus_activation_env_var_names_present(&[
            ("WAYLAND_DISPLAY", "wayland-0"),
            ("XDG_RUNTIME_DIR", "/run/user/10000"),
        ]);
        assert_eq!(present.len(), 2);
    }

    #[test]
    fn parse_gnome_console_service_exec() {
        assert_eq!(
            parse_dbus_service_exec(FIXTURE_GNOME_CONSOLE_SERVICE_DAEMON).as_deref(),
            Some("/usr/bin/kgx --gapplication-service"),
        );
        assert!(dbus_service_exec_is_daemon_only(
            "/usr/bin/kgx --gapplication-service"
        ));
        assert!(!should_spawn_dbus_service_exec_directly(
            "/usr/bin/kgx --gapplication-service"
        ));
        assert_eq!(
            default_dbus_service_path(APP_ID_GNOME_CONSOLE),
            "/usr/share/dbus-1/services/org.gnome.Console.service",
        );
    }
}
