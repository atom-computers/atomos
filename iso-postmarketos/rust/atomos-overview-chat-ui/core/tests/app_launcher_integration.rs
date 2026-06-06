//! Integration contracts for the chat-ui app launcher hang class:
//!
//! _"Tap the app-grid icon (or an app tile) and the UI freezes — touch stops
//! responding because heavy GLib desktop enumeration or metadata reads run on
//! the GTK main thread inside the click handler."_
//!
//! These tests reproduce that failure mode as deterministic source contracts
//! (same pattern as `lifecycle_integration_contract.rs` and
//! `app_grid_wiring.rs`) so `cargo test -p atomos-overview-chat-ui` on macOS
//! / CI catches regressions before a device image ships.
//!
//! Bug vectors pinned here:
//!   1. `build_app_grid_sheet()` (`gio::AppInfo::all()`) inline in the dock
//!      toggle click handler — blocks the main loop for hundreds of ms.
//!   2. Sorting / labelling via `display_name()` / `name()` on malformed
//!      `.desktop` entries — can wedge GLib entirely on device images.
//!   3. Window-level `GestureClick` in `PropagationPhase::Capture` for the
//!      dock toggle — intercepts taps before child widgets and misroutes focus.
//!   4. Eager CI repro building the grid synchronously at startup.
//!   5. Tile click bypassing `Command::spawn` for the app-handler launch path.

const UI_RS: &str = include_str!("../../app-gtk/src/ui.rs");
const APP_GRID_RS: &str = include_str!("../../app-gtk/src/app_grid.rs");
const STYLE_RS: &str = include_str!("../../app-gtk/src/style.rs");
const INSTALL_SCRIPT: &str =
    include_str!("../../../../scripts/overview-chat-ui/install-overview-chat-ui.sh");

fn click_handler_body() -> &'static str {
    let start = UI_RS
        .find("app_grid_btn.connect_clicked")
        .expect("ui.rs must wire app_grid_btn.connect_clicked");
    &UI_RS[start..]
}

fn connect_dock_toggle_body() -> &'static str {
    let start = UI_RS
        .find("fn connect_dock_toggle")
        .expect("ui.rs must define connect_dock_toggle");
    &UI_RS[start..]
}

fn schedule_app_grid_build_body() -> &'static str {
    let start = UI_RS
        .find("fn schedule_app_grid_build")
        .expect("ui.rs must define schedule_app_grid_build");
    &UI_RS[start..]
}

fn eager_app_grid_block() -> &'static str {
    let start = UI_RS
        .find("if eager_app_grid_enabled()")
        .expect("ui.rs must gate eager app-grid build");
    &UI_RS[start..start + 600]
}

#[test]
fn app_grid_build_is_scheduled_via_idle_not_inline_in_click_handler() {
    let body = click_handler_body();
    assert!(
        body.contains("schedule_app_grid_build"),
        "app-gtk/src/ui.rs click handler must call schedule_app_grid_build \
         instead of build_app_grid_sheet() inline",
    );
    assert!(
        !body.contains("let app_sheet = build_app_grid_sheet()"),
        "app-gtk/src/ui.rs must not call build_app_grid_sheet() directly \
         inside connect_clicked — that blocks the GTK main loop on mobile",
    );
}

#[test]
fn schedule_app_grid_build_uses_idle_add_local_once() {
    let body = schedule_app_grid_build_body();
    assert!(
        body.contains("glib::idle_add_local_once"),
        "schedule_app_grid_build must defer work with glib::idle_add_local_once",
    );
    assert!(
        body.contains("build_app_grid_sheet("),
        "idle callback is where build_app_grid_sheet() must run",
    );
}

#[test]
fn schedule_app_grid_build_shows_loading_placeholder_before_idle_work() {
    let body = schedule_app_grid_build_body();
    assert!(
        body.contains("Loading apps"),
        "user must see immediate feedback while gio::AppInfo::all() runs on idle",
    );
}

#[test]
fn eager_app_grid_also_defers_via_schedule_not_inline_build() {
    let block = eager_app_grid_block();
    assert!(
        block.contains("schedule_app_grid_build"),
        "ATOMOS_OVERVIEW_CHAT_UI_EAGER_APP_GRID repro must not block startup \
         with a synchronous build_app_grid_sheet()",
    );
    assert!(
        !block.contains("let app_sheet = build_app_grid_sheet()"),
        "eager repro must not inline build_app_grid_sheet() at startup",
    );
}

#[test]
fn dock_toggle_uses_button_clicked_not_window_capture_gesture() {
    let body = connect_dock_toggle_body();
    assert!(
        body.contains("app_grid_btn.connect_clicked"),
        "dock toggle must be wired on the app-grid button, not a window gesture",
    );
    assert!(
        !body.contains("dock_hit_tap"),
        "window-level dock_hit_tap reproduced hangs by intercepting taps in \
         Capture phase before child widgets receive them",
    );
    assert!(
        !body.contains("PropagationPhase::Capture"),
        "connect_dock_toggle must not install a Capture-phase gesture — that \
         blocked OSK/focus and made the launcher feel wedged",
    );
    assert!(
        !UI_RS.contains("win.add_controller(dock_hit_tap)"),
        "app-grid toggle must not attach a window-level capture click handler",
    );
}

#[test]
fn app_grid_sorts_by_app_id_not_display_name_metadata() {
    assert!(
        APP_GRID_RS.contains("app.id()") && APP_GRID_RS.contains("sort_by_key"),
        "visible_apps must sort by app.id() only",
    );
    assert!(
        !APP_GRID_RS.contains("sort_by_key(|app| app_label"),
        "must not sort via app_label() — that reads display_name() and can \
         hang on malformed device .desktop files",
    );
    assert!(
        APP_GRID_RS.contains("normalized_id_label(&id)"),
        "tile labels must prefer id-derived text before GLib display_name()",
    );
}

#[test]
fn app_label_never_reads_glib_display_metadata() {
    let label_fn = APP_GRID_RS
        .split("fn app_label")
        .nth(1)
        .and_then(|tail| tail.split("\nfn ").next())
        .unwrap_or("");
    assert!(
        !label_fn.contains("display_name()"),
        "app_label must not call gio::AppInfo::display_name() — hangs on broken .desktop",
    );
    assert!(
        !label_fn.contains(".name()"),
        "app_label must not call gio::AppInfo::name() — same hang class as display_name()",
    );
}

#[test]
fn tile_click_primary_path_spawns_app_handler_subprocess() {
    assert!(
        APP_GRID_RS.contains("Command::new(&program).args(&args).spawn()"),
        "DispatchAppHandler tile clicks must spawn atomos-app-handler without \
         blocking the GTK main loop on launch I/O",
    );
}

#[test]
fn tile_click_routes_through_decide_launch_invocation() {
    assert!(
        APP_GRID_RS.contains("decide_launch_invocation"),
        "tile_click_launch must use shared launch decision logic",
    );
}

#[test]
fn app_tile_labels_use_explicit_theme_colors_not_inherit_only() {
    // On the transparent layer-shell overlay, `color: inherit` resolves to
    // an undefined/contrast-less value — tiles look blank (no name, no icon).
    let decorative = STYLE_RS
        .split("fn stylesheet")
        .nth(1)
        .and_then(|tail| tail.split("#[cfg(test)]").next())
        .unwrap_or("");
    assert!(
        decorative.contains("window.atomos-chat-root.atomos-dark label.atomos-app-label")
            && decorative.contains("color: #ffffff"),
        "dark theme must set an explicit app-label color",
    );
    assert!(
        decorative.contains("window.atomos-chat-root.atomos-light label.atomos-app-label")
            && decorative.contains("color: #121212"),
        "light theme must set an explicit app-label color",
    );
    assert!(
        decorative.contains("button.atomos-app-tile image"),
        "tile icons need an explicit -gtk-icon-size",
    );
    assert!(
        !decorative.contains("label.atomos-app-label {\n  color: inherit"),
        "inherit-only label color reproduces invisible names on device",
    );
}

#[test]
fn install_launcher_defaults_app_icons_on() {
    assert!(
        INSTALL_SCRIPT.contains(
            "ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS=\"${ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS:-1}\""
        ),
        "production launcher must default real gicons on; :-0 made every tile \
         a blank symbolic placeholder",
    );
}

#[test]
fn app_icons_enabled_unless_explicitly_disabled() {
    assert!(
        APP_GRID_RS.contains("Ok(\"0\")"),
        "app_icons_enabled must only disable when env is explicitly 0",
    );
    assert!(
        !APP_GRID_RS.contains("Ok(\"1\")"),
        "icons must not require ATOMOS_OVERVIEW_CHAT_UI_ENABLE_APP_ICONS=1 to show",
    );
}

#[test]
fn tile_click_dismisses_app_sheet_before_launch() {
    let tile_handler = APP_GRID_RS
        .split("tile_btn.connect_clicked")
        .nth(1)
        .and_then(|tail| tail.split("flow.insert").next())
        .unwrap_or("");
    assert!(
        tile_handler.contains("dismiss_for_tile()"),
        "tile click must collapse the overlay app sheet before launch",
    );
    assert!(
        UI_RS.contains("dismissing app sheet for launch"),
        "dismiss helper must log when collapsing the sheet",
    );
    let dismiss_order = tile_handler
        .find("dismiss_for_tile()")
        .zip(tile_handler.find("tile_click_launch("));
    assert!(
        dismiss_order.map(|(d, l)| d < l).unwrap_or(false),
        "dismiss must run before tile_click_launch in the tile click closure",
    );
}
