//! Combined-stack integration tests: assert that the
//! `atomos-app-handler` core constants do not collide with the
//! `atomos-home-bg` or `atomos-overview-chat-ui` core constants, and that
//! the backdrop the switcher self-paints is visually identical to the
//! home-bg base color (so the requirement "background should not be the app
//! still, it should be the atomos-home-bg" reads as one continuous surface).
//!
//! Runs only via `cargo test -p atomos-app-handler` because the dev-deps on
//! both sibling cores are local-only.

use atomos_app_handler as sw;
use atomos_home_bg as bg;
use atomos_overview_chat_ui as chat;

#[test]
fn layer_shell_namespaces_are_pairwise_distinct_and_non_empty() {
    let names = [
        sw::LAYER_SHELL_NAMESPACE,
        bg::LAYER_SHELL_NAMESPACE,
        chat::LAYER_SHELL_NAMESPACE,
    ];
    for n in names {
        assert!(!n.is_empty());
    }
    assert_ne!(names[0], names[1]);
    assert_ne!(names[0], names[2]);
    assert_ne!(names[1], names[2]);
}

#[test]
fn runtime_enable_env_vars_are_pairwise_distinct() {
    let envs = [
        sw::ENABLE_RUNTIME_ENV,
        bg::ENABLE_RUNTIME_ENV,
        chat::ENABLE_RUNTIME_ENV,
    ];
    assert_ne!(envs[0], envs[1]);
    assert_ne!(envs[0], envs[2]);
    assert_ne!(envs[1], envs[2]);
}

#[test]
fn runtime_file_basenames_are_pairwise_distinct() {
    let names = [
        sw::RUNTIME_FILE_BASENAME,
        bg::RUNTIME_FILE_BASENAME,
        chat::RUNTIME_FILE_BASENAME,
    ];
    assert_ne!(names[0], names[1]);
    assert_ne!(names[0], names[2]);
    assert_ne!(names[1], names[2]);
}

#[test]
fn switcher_default_layer_is_at_or_above_overview_chat_ui_default() {
    // The switcher self-paints a #0a0a0a backdrop and must occlude both the
    // running app AND the overview-chat-ui strip while open.
    let chat_default = bg::LayerTarget::from_name(chat::DEFAULT_LAYER_NAME)
        .expect("overview-chat-ui DEFAULT_LAYER_NAME must match a known LayerTarget variant");
    let switcher_default = bg::LayerTarget::from_name(sw::DEFAULT_LAYER_NAME)
        .expect("app-switcher DEFAULT_LAYER_NAME must match a known LayerTarget variant");
    assert!(
        switcher_default >= chat_default,
        "app-switcher default layer {:?} ({}) must sit at or above overview-chat-ui default layer {:?} ({}) so the switcher backdrop occludes the chat strip while open",
        switcher_default,
        switcher_default.z_index(),
        chat_default,
        chat_default.z_index(),
    );
}

#[test]
fn switcher_default_layer_is_strictly_above_home_bg_default() {
    let switcher_default = bg::LayerTarget::from_name(sw::DEFAULT_LAYER_NAME)
        .expect("app-switcher DEFAULT_LAYER_NAME must match a known LayerTarget variant");
    assert!(
        switcher_default > bg::DEFAULT_LAYER,
        "app-switcher default layer {:?} ({}) must sit strictly above home-bg default layer {:?} ({}) so the switcher renders above the wallpaper",
        switcher_default,
        switcher_default.z_index(),
        bg::DEFAULT_LAYER,
        bg::DEFAULT_LAYER.z_index(),
    );
}

#[test]
fn switcher_backdrop_matches_home_bg_base_color_byte_for_byte() {
    // The user-visible contract for the switcher backdrop is "looks like
    // atomos-home-bg, not the still of the running app". The cheapest way
    // to assert this end-to-end without a screenshot pipeline is to pin
    // both representations against each other byte-for-byte.
    let bg_color_hex = "#0a0a0a"; // mirror of HOME_BG_BASE_COLOR / index.html body fill
    assert_eq!(
        sw::BACKDROP_BASE_COLOR_HEX,
        bg_color_hex,
        "app-switcher backdrop hex must match the documented home-bg #0a0a0a base color",
    );
    assert_eq!(
        sw::BACKDROP_BASE_COLOR_RGB,
        [0x0a, 0x0a, 0x0a],
        "app-switcher backdrop rgb must decode the same #0a0a0a triplet",
    );
}

#[test]
fn lifecycle_actions_are_symmetric_with_home_bg() {
    assert!(matches!(
        sw::parse_lifecycle_action(&["--show".into()]),
        sw::LifecycleAction::Show
    ));
    assert!(matches!(
        bg::parse_lifecycle_action(Some("--show")),
        bg::LifecycleAction::Show
    ));
    assert!(matches!(
        sw::parse_lifecycle_action(&["--hide".into()]),
        sw::LifecycleAction::Hide
    ));
    assert!(matches!(
        sw::parse_lifecycle_action(&[]),
        sw::LifecycleAction::Run
    ));
    assert!(matches!(
        sw::parse_lifecycle_action(&["launch".into(), "org.foo.App".into()]),
        sw::LifecycleAction::Launch { .. }
    ));
}

#[test]
fn handle_paint_is_not_fully_transparent() {
    assert!(
        sw::handle::STRIP_SCRIM.a > 0.0,
        "handle strip scrim must be visible on device"
    );
    assert!(
        sw::handle::PILL_FILL.a > 0.0,
        "handle pill must be visible on device"
    );
    assert_eq!(sw::handle::PILL_WIDTH_PX, 150.0);
}

#[test]
fn chat_ui_app_handler_launcher_path_is_pinned_against_app_handler_runtime_basename() {
    // Chat-ui's `APP_HANDLER_LAUNCHER_PATH` must end with the app-handler's
    // own `RUNTIME_FILE_BASENAME` so a basename rename in the app-handler
    // crate forces the chat-ui constant (and Phosh `home.c`'s `#define`,
    // and `app-grid-button.c`'s string) to be revisited together.
    assert!(
        chat::APP_HANDLER_LAUNCHER_PATH.ends_with(sw::RUNTIME_FILE_BASENAME),
        "chat-ui APP_HANDLER_LAUNCHER_PATH ({}) must end in app-handler \
         RUNTIME_FILE_BASENAME ({})",
        chat::APP_HANDLER_LAUNCHER_PATH,
        sw::RUNTIME_FILE_BASENAME,
    );
}

#[test]
fn chat_ui_app_grid_launch_decision_round_trips_through_app_handler_lifecycle() {
    // **Bug under TDD**: feeds chat-ui's tile-click decision (with a
    // launcher path explicitly available) through atomos-app-handler's
    // argv parser. The contract is "chat-ui dispatches → app-handler
    // parses LifecycleAction::Launch{ app_id }". Today this fails because
    // chat-ui's `decide_launch_invocation` stub returns `DirectGioFallback`
    // → `launch_invocation_argv` returns `[]` → `parse_lifecycle_action`
    // returns `LifecycleAction::Run`.
    let launcher = std::path::PathBuf::from(chat::APP_HANDLER_LAUNCHER_PATH);
    let invocation = chat::decide_launch_invocation("org.gnome.Calculator", Some(&launcher));
    let argv = chat::launch_invocation_argv(&invocation);
    assert!(
        !argv.is_empty(),
        "chat-ui must produce a non-empty argv when launcher path is \
         available; got DirectGioFallback (the bug)",
    );
    // Drop argv[0] (the launcher executable path) — `parse_lifecycle_action`
    // reads the *arguments* to that program, mirroring how `argv[1..]`
    // is read inside `atomos-app-handler` itself.
    let action_args: Vec<String> = argv[1..].to_vec();
    let action = sw::parse_lifecycle_action(&action_args);
    assert_eq!(
        action,
        sw::LifecycleAction::Launch {
            app_id: "org.gnome.Calculator".into(),
        },
        "chat-ui app-grid → app-handler launch lifecycle round-trip must \
         land on LifecycleAction::Launch{{ app_id }} so home folds, the \
         existing toplevel is activated if any, and the app-handler tracks \
         the new app as opened-from-chat-ui",
    );
}

#[test]
fn chat_ui_app_grid_must_not_bypass_app_handler_when_launcher_present() {
    // Negative-form pin: even if a future refactor stops using the
    // `LaunchInvocation` enum directly, the *outcome* must still be that
    // chat-ui app-grid clicks reach the app-handler launch lifecycle when
    // the launcher path is on disk. Today this fails because the stub
    // ignores the launcher path.
    let launcher = std::path::PathBuf::from(chat::APP_HANDLER_LAUNCHER_PATH);
    let invocation = chat::decide_launch_invocation("org.gnome.Calculator", Some(&launcher));
    assert!(
        matches!(invocation, chat::LaunchInvocation::DispatchAppHandler { .. }),
        "with /usr/libexec/atomos-app-handler available, chat-ui must NOT \
         fall back to a direct gio launch — that bypasses home fold IPC \
         and the app-handler's toplevel tracking, which is the bug \
         reported as 'opened the app from chat-ui, can't find the swipe-up \
         to the switcher anymore'",
    );
}
