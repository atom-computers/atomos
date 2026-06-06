//! Spawn `.desktop` apps via GIO (replaces Phosh `app-tracker.c` spawn path).

use atomos_app_handler::{
    app_ids_match, default_dbus_service_path, desktop_exec_is_spawnable_for_window,
    parse_dbus_service_exec, should_spawn_dbus_service_exec_directly,
    DBUS_ACTIVATION_SESSION_ENV_VARS,
};
use gtk::gdk::prelude::DisplayExt;
use gtk::gio;
use gtk::gio::prelude::{AppInfoExt, AppLaunchContextExt};
use gtk::glib::prelude::Cast;
use gtk::glib::SpawnFlags;
use std::process::Command;

/// Build the same launch context Phosh uses in `app-tracker.c` /
/// `app-grid-button.c`. Required for DBusActivatable apps (GNOME Console,
/// Settings, …): without it GIO logs success on D-Bus Activate but the
/// compositor never receives an XDG activation token, so Exec-only apps
/// like Firefox still appear while DBus apps do not.
fn display_app_launch_context() -> gtk::gdk::AppLaunchContext {
    gtk::gdk::Display::default()
        .expect("GdkDisplay required to launch apps (WAYLAND_DISPLAY set?)")
        .app_launch_context()
}

fn systemd_user_session_available() -> bool {
    Command::new("systemctl")
        .args(["--user", "status"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

/// DBus-activatable services start outside the app-handler process and read
/// env from dbus-daemon activation state, not our inherited environ.
fn sync_session_env_to_dbus_activation() {
    let vars: Vec<&str> = DBUS_ACTIVATION_SESSION_ENV_VARS
        .iter()
        .copied()
        .filter(|key| {
            std::env::var(key)
                .map(|value| !value.is_empty())
                .unwrap_or(false)
        })
        .collect();
    if vars.is_empty() {
        return;
    }
    eprintln!(
        "atomos-app-handler: launch: syncing session env to dbus activation ({})",
        vars.join(" ")
    );
    let mut cmd = Command::new("dbus-update-activation-environment");
    if systemd_user_session_available() {
        cmd.arg("--systemd");
    }
    cmd.args(vars);
    match cmd.status() {
        Ok(status) if status.success() => {}
        Ok(status) => {
            eprintln!(
                "atomos-app-handler: launch: dbus-update-activation-environment exited {status}"
            );
        }
        Err(err) => {
            eprintln!(
                "atomos-app-handler: launch: dbus-update-activation-environment failed: {err}"
            );
        }
    }
}

fn prepare_launch_context(context: &gtk::gdk::AppLaunchContext, desktop: &gio::DesktopAppInfo) {
    for key in DBUS_ACTIVATION_SESSION_ENV_VARS {
        if let Ok(value) = std::env::var(key) {
            context.setenv(key, &value);
        }
    }
    if let Ok(value) = std::env::var("DBUS_SESSION_BUS_ADDRESS") {
        context.setenv("DBUS_SESSION_BUS_ADDRESS", &value);
    }
    if let Some(token) = context.startup_notify_id(Some(desktop), &[]) {
        context.setenv("XDG_ACTIVATION_TOKEN", &token);
        context.setenv("DESKTOP_STARTUP_ID", &token);
    }
}

fn desktop_is_dbus_activatable(desktop: &gio::DesktopAppInfo) -> bool {
    desktop
        .string("DBusActivatable")
        .map(|flag| flag.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

fn desktop_spawnable_exec(desktop: &gio::DesktopAppInfo) -> Option<String> {
    desktop
        .string("Exec")
        .map(|exec| exec.to_string())
        .filter(|exec| desktop_exec_is_spawnable_for_window(exec))
}

fn load_dbus_service_exec(app_id: &str) -> Option<String> {
    let path = default_dbus_service_path(app_id);
    let content = std::fs::read_to_string(&path).ok()?;
    parse_dbus_service_exec(&content)
}

fn apply_launch_context_env(cmd: &mut Command, context: &gtk::gdk::AppLaunchContext) {
    for entry in context.environment() {
        if let Some(entry) = entry.to_str() {
            if let Some((key, value)) = entry.split_once('=') {
                cmd.env(key, value);
            }
        }
    }
}

fn spawn_command_with_launch_context(
    exec: &str,
    context: &gtk::gdk::AppLaunchContext,
) -> Result<(), String> {
    let argv = gtk::glib::shell_parse_argv(exec).map_err(|e| e.to_string())?;
    let Some(program) = argv.first() else {
        return Err(format!("empty Exec line: {exec}"));
    };
    let mut cmd = Command::new(program);
    if argv.len() > 1 {
        cmd.args(&argv[1..]);
    }
    apply_launch_context_env(&mut cmd, context);
    cmd.spawn()
        .map(|_| ())
        .map_err(|e| format!("failed to spawn {exec}: {e}"))
}

pub fn spawn_desktop_app(app_id: &str) -> Result<(), String> {
    sync_session_env_to_dbus_activation();
    let context = display_app_launch_context();
    let desktop = find_enumerated_desktop_app_info(app_id).or_else(|| {
        gio::DesktopAppInfo::new(&normalize_desktop_id(app_id))
    });
    let desktop =
        desktop.ok_or_else(|| format!("unknown desktop app id: {}", normalize_desktop_id(app_id)))?;

    prepare_launch_context(&context, &desktop);

    if desktop_is_dbus_activatable(&desktop) {
        // Device `.service` files use `--gapplication-service` (no window). When the
        // desktop entry also has a window Exec= (Console: `kgx`), spawn that with the
        // Gdk launch context so a toplevel appears. GIO launch_uris_as_manager alone
        // often returns Ok while the bus entry stays `(activatable)` with no process.
        if let Some(exec) = desktop_spawnable_exec(&desktop) {
            eprintln!("atomos-app-handler: launch: dbus activatable spawning desktop Exec {exec}");
            return spawn_command_with_launch_context(&exec, &context);
        }
        eprintln!("atomos-app-handler: launch: dbus activatable via launch_uris_as_manager");
        return desktop
            .launch_uris_as_manager(&[], Some(&context), SpawnFlags::SEARCH_PATH, None, None)
            .map_err(|e| e.to_string());
    }

    if let Some(exec) = load_dbus_service_exec(app_id) {
        if should_spawn_dbus_service_exec_directly(&exec) {
            eprintln!("atomos-app-handler: launch: spawning dbus service exec {exec}");
            return spawn_command_with_launch_context(&exec, &context);
        }
    }

    desktop
        .launch_uris_as_manager(&[], Some(&context), SpawnFlags::SEARCH_PATH, None, None)
        .map_err(|e| e.to_string())
}

fn find_enumerated_desktop_app_info(app_id: &str) -> Option<gio::DesktopAppInfo> {
    gio::AppInfo::all()
        .into_iter()
        .find(|app| app.id().is_some_and(|id| app_ids_match(app_id, &id)))
        .and_then(|app| app.downcast::<gio::DesktopAppInfo>().ok())
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
    use super::{find_enumerated_desktop_app_info, normalize_desktop_id};
    use atomos_app_handler::app_ids_match;

    #[test]
    fn normalize_appends_desktop_suffix() {
        assert_eq!(
            normalize_desktop_id("org.gnome.Calculator"),
            "org.gnome.Calculator.desktop"
        );
    }

    #[test]
    fn app_ids_match_covers_desktop_suffix_mismatch() {
        assert!(app_ids_match(
            "org.gnome.Calculator",
            "org.gnome.Calculator.desktop"
        ));
    }

    #[test]
    fn find_enumerated_desktop_app_info_is_exposed_for_launch_fallback() {
        let _ = find_enumerated_desktop_app_info("org.example.Nothing");
    }
}
