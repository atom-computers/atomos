use std::path::{Path, PathBuf};

pub const MAX_LINES: i32 = 6;
pub const MIN_LINES: i32 = 1;
pub const LINE_HEIGHT_PX: i32 = 38;

/// Single Rust-side source of truth for the path Phosh's `home.c`
/// (`ATOMOS_APP_HANDLER_LAUNCHER_PATH` `#define`) and `app-grid-button.c`'s
/// `activate_cb` both spawn (`/usr/libexec/atomos-app-handler launch <id>`).
/// Pinned here so the chat-ui app-grid tile click handler routes through the
/// same lifecycle as Phosh's own grid — bypassing it (the v0 behavior in
/// [`app-gtk/src/app_grid.rs`](../../app-gtk/src/app_grid.rs)) skips
/// `phosh_ipc::apply_home_ipc(SetFolded)`, breaks toplevel de-dup via
/// `find_matching_toplevel`, and leaves `atomos-app-handler` with no record
/// that the user just opened an app from the chat-ui sheet.
pub const APP_HANDLER_LAUNCHER_PATH: &str = "/usr/libexec/atomos-app-handler";

/// Decision returned by [`decide_launch_invocation`] for an app-grid tile
/// click. Plain data so the GTK click handler can pattern-match on it
/// without any pure logic spilling back into widget glue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LaunchInvocation {
    /// Spawn `<launcher> launch <app_id>` so the launch round-trips through
    /// `atomos-app-handler`'s `LifecycleAction::Launch` arm — same path
    /// Phosh's `app-grid-button.c:activate_cb` takes.
    DispatchAppHandler {
        app_id: String,
        launcher: PathBuf,
    },
    /// Fallback for hosts where the app-handler launcher is not installed
    /// (e.g. plain desktop preview): caller goes through `gio::AppInfo`.
    /// Mirrors Phosh `home.c`'s `g_file_test(... IS_EXECUTABLE)` warn-and-skip
    /// pattern — keep launching, just skip the lifecycle call.
    DirectGioFallback { app_id: String },
}

/// Decide how to launch the app the user just tapped in the chat-ui app
/// grid. Rust mirror of Phosh `app-grid-button.c:activate_cb` — when an
/// `atomos-app-handler` launcher is available, the launch must round-trip
/// through it so the home fold + toplevel de-dup + tracking inside
/// `atomos-app-handler` all fire as one unit. When the launcher is absent
/// (desktop preview, host without the rootfs overlay installed), fall
/// through to a direct `gio::AppInfo` launch so the user-facing click
/// still opens an app — same warn-and-skip pattern Phosh `home.c:276-285`
/// uses for its own lifecycle bridge.
pub fn decide_launch_invocation(
    app_id: &str,
    app_handler_launcher: Option<&Path>,
) -> LaunchInvocation {
    let app_id = app_id.to_string();
    match app_handler_launcher {
        Some(launcher) if !launcher.as_os_str().is_empty() => {
            LaunchInvocation::DispatchAppHandler {
                app_id,
                launcher: launcher.to_path_buf(),
            }
        }
        _ => LaunchInvocation::DirectGioFallback { app_id },
    }
}

/// Env override for the app-handler launcher path used by the chat-ui
/// app-grid tile click. Mirrors the existing
/// `ATOMOS_OVERVIEW_CHAT_UI_APP_GRID_CMD` pattern documented in this
/// crate's README — kept distinct so the launcher path can be redirected
/// (test/dev) without disturbing the wholesale grid command.
pub const APP_HANDLER_LAUNCHER_ENV: &str = "ATOMOS_OVERVIEW_CHAT_UI_APP_HANDLER_LAUNCHER";

/// Resolve the app-handler launcher path the chat-ui tile-click handler
/// should dispatch through.
///
/// Priority, mirroring Phosh `home.c:276-285`'s warn-and-skip lookup:
/// 1. `ATOMOS_OVERVIEW_CHAT_UI_APP_HANDLER_LAUNCHER` env override (used by
///    tests and `hotfix-overview-chat-ui.sh` when the launcher lives at a
///    non-standard path).
/// 2. [`APP_HANDLER_LAUNCHER_PATH`] iff `path_is_executable(<that path>)`
///    returns true.
/// 3. `None` — caller (chat-ui app-grid) falls back to `gio::AppInfo` so
///    desktop preview hosts without the rootfs overlay still launch apps.
///
/// `path_is_executable` is injected so the function stays pure / testable
/// — the GTK side passes a closure that calls
/// [`std::path::Path::is_file`]. Tests pass a deterministic predicate.
pub fn resolve_app_handler_launcher<F>(
    env_override: Option<&str>,
    path_is_executable: F,
) -> Option<PathBuf>
where
    F: Fn(&Path) -> bool,
{
    if let Some(value) = env_override {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            return Some(PathBuf::from(trimmed));
        }
    }
    let default = Path::new(APP_HANDLER_LAUNCHER_PATH);
    if path_is_executable(default) {
        Some(default.to_path_buf())
    } else {
        None
    }
}

/// Argv vector for the `DispatchAppHandler` case, matching the literal
/// command shape Phosh's `app-grid-button.c:220` builds:
/// `<launcher> launch <app_id>`. Returns an empty vector for the fallback
/// case (caller goes through `gio::AppInfo` instead).
pub fn launch_invocation_argv(invocation: &LaunchInvocation) -> Vec<String> {
    match invocation {
        LaunchInvocation::DispatchAppHandler { app_id, launcher } => vec![
            launcher.to_string_lossy().into_owned(),
            "launch".to_string(),
            app_id.to_string(),
        ],
        LaunchInvocation::DirectGioFallback { .. } => Vec::new(),
    }
}

/// Layer-shell namespace used by the production GTK binary. Exposed as a
/// constant so sibling surfaces (e.g. `atomos-home-bg`) can assert they do
/// not collide on the compositor.
pub const LAYER_SHELL_NAMESPACE: &str = "atomos-overview-chat-ui";

/// Default wlr-layer-shell layer for the overview chat surface. The binary
/// reads `ATOMOS_OVERVIEW_CHAT_UI_LAYER` to override; this constant is the
/// value used when the env var is absent.
pub const DEFAULT_LAYER_NAME: &str = "top";

/// Runtime enable gate env var. When not set to literal `"1"` the launcher
/// skips starting the surface — matched by the home-bg gate for symmetry.
pub const ENABLE_RUNTIME_ENV: &str = "ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME";

/// Basename used for the pidfile/logfile/disable marker under
/// `XDG_RUNTIME_DIR`. Encoded so combined-stack tests can verify launchers
/// don't write to overlapping paths.
pub const RUNTIME_FILE_BASENAME: &str = "atomos-overview-chat-ui";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LayoutState {
    pub source_lines: i32,
    pub visible_lines: i32,
    pub min_content_height: i32,
    pub max_content_height: i32,
    pub needs_scroll: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnterKeyAction {
    Submit(String),
    InsertNewline,
    Noop,
}

pub fn line_count(text: &str) -> i32 {
    text.lines().count().max(1) as i32
}

pub fn layout_state_for_text(text: &str) -> LayoutState {
    let source_lines = line_count(text);
    let visible_lines = source_lines.clamp(MIN_LINES, MAX_LINES);
    LayoutState {
        source_lines,
        visible_lines,
        min_content_height: visible_lines * LINE_HEIGHT_PX,
        max_content_height: MAX_LINES * LINE_HEIGHT_PX,
        needs_scroll: source_lines > MAX_LINES,
    }
}

pub fn enter_action(message: &str, shift_pressed: bool) -> EnterKeyAction {
    if shift_pressed {
        return EnterKeyAction::InsertNewline;
    }

    let trimmed = message.trim();
    if trimmed.is_empty() {
        EnterKeyAction::Noop
    } else {
        EnterKeyAction::Submit(trimmed.to_string())
    }
}

pub fn parse_lifecycle_action(arg: Option<&str>) -> &'static str {
    match arg {
        Some("--show") => "--show",
        Some("--hide") => "--hide",
        _ => "run",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn line_count_empty_is_one() {
        assert_eq!(line_count(""), 1);
    }

    #[test]
    fn line_count_single_line() {
        assert_eq!(line_count("hello"), 1);
    }

    #[test]
    fn line_count_multi_line() {
        assert_eq!(line_count("a\nb\nc"), 3);
    }

    #[test]
    fn line_count_trailing_newline_matches_lines_behavior() {
        assert_eq!(line_count("hello\n"), 1);
    }

    #[test]
    fn layout_clamps_to_min_line() {
        let state = layout_state_for_text("");
        assert_eq!(state.visible_lines, MIN_LINES);
        assert_eq!(state.min_content_height, MIN_LINES * LINE_HEIGHT_PX);
        assert!(!state.needs_scroll);
    }

    #[test]
    fn layout_clamps_to_max_lines() {
        let state = layout_state_for_text("1\n2\n3\n4\n5\n6\n7\n8");
        assert_eq!(state.source_lines, 8);
        assert_eq!(state.visible_lines, MAX_LINES);
        assert_eq!(state.min_content_height, MAX_LINES * LINE_HEIGHT_PX);
        assert!(state.needs_scroll);
    }

    #[test]
    fn layout_no_scroll_at_exact_limit() {
        let state = layout_state_for_text("1\n2\n3\n4\n5\n6");
        assert_eq!(state.visible_lines, MAX_LINES);
        assert!(!state.needs_scroll);
    }

    #[test]
    fn enter_action_shift_is_newline() {
        assert_eq!(enter_action("hello", true), EnterKeyAction::InsertNewline);
    }

    #[test]
    fn enter_action_submit_trims_whitespace() {
        assert_eq!(
            enter_action("   hello world  ", false),
            EnterKeyAction::Submit("hello world".to_string())
        );
    }

    #[test]
    fn enter_action_empty_is_noop() {
        assert_eq!(enter_action("", false), EnterKeyAction::Noop);
        assert_eq!(enter_action("   \n\t", false), EnterKeyAction::Noop);
    }

    #[test]
    fn enter_action_preserves_internal_newlines_on_submit() {
        assert_eq!(
            enter_action("hello\nworld", false),
            EnterKeyAction::Submit("hello\nworld".to_string())
        );
    }

    #[test]
    fn parse_lifecycle_show() {
        assert_eq!(parse_lifecycle_action(Some("--show")), "--show");
    }

    #[test]
    fn parse_lifecycle_hide() {
        assert_eq!(parse_lifecycle_action(Some("--hide")), "--hide");
    }

    #[test]
    fn parse_lifecycle_default_run() {
        assert_eq!(parse_lifecycle_action(None), "run");
        assert_eq!(parse_lifecycle_action(Some("--unknown")), "run");
    }

    #[test]
    fn parse_lifecycle_empty_arg_defaults_run() {
        assert_eq!(parse_lifecycle_action(Some("")), "run");
    }

    #[test]
    fn layer_shell_namespace_is_stable() {
        assert_eq!(LAYER_SHELL_NAMESPACE, "atomos-overview-chat-ui");
    }

    #[test]
    fn default_layer_is_top() {
        assert_eq!(DEFAULT_LAYER_NAME, "top");
    }

    #[test]
    fn enable_runtime_env_matches_launcher_contract() {
        assert_eq!(ENABLE_RUNTIME_ENV, "ATOMOS_OVERVIEW_CHAT_UI_ENABLE_RUNTIME");
    }

    #[test]
    fn runtime_file_basename_matches_launcher() {
        assert_eq!(RUNTIME_FILE_BASENAME, "atomos-overview-chat-ui");
    }

    #[test]
    fn app_handler_launcher_path_matches_phosh_home_c_constant() {
        // Pinned against the Phosh-side `#define` in
        // `rust/phosh/phosh/src/home.c` and the literal in
        // `rust/phosh/phosh/src/app-grid-button.c:220`. A rename in any one
        // of the three places without the other two desync's the launch
        // pipeline silently — this assertion fails the CI before the bad
        // image ships.
        assert_eq!(APP_HANDLER_LAUNCHER_PATH, "/usr/libexec/atomos-app-handler");
    }

    #[test]
    fn launch_invocation_argv_for_dispatch_uses_phosh_launch_command_format() {
        let argv = launch_invocation_argv(&LaunchInvocation::DispatchAppHandler {
            app_id: "org.gnome.Calculator".into(),
            launcher: PathBuf::from(APP_HANDLER_LAUNCHER_PATH),
        });
        assert_eq!(
            argv,
            vec![
                "/usr/libexec/atomos-app-handler".to_string(),
                "launch".to_string(),
                "org.gnome.Calculator".to_string(),
            ],
            "argv must match Phosh app-grid-button.c:220 command shape \
             so atomos-app-handler's parse_lifecycle_action sees \
             LifecycleAction::Launch{{ app_id }}",
        );
    }

    #[test]
    fn launch_invocation_argv_for_fallback_is_empty() {
        let argv = launch_invocation_argv(&LaunchInvocation::DirectGioFallback {
            app_id: "org.gnome.Calculator".into(),
        });
        assert!(
            argv.is_empty(),
            "DirectGioFallback signals 'do not spawn a subcommand' to the \
             caller; argv must be empty so the click handler falls through \
             to gio::AppInfo::launch",
        );
    }

    #[test]
    fn decide_launch_invocation_falls_back_to_gio_when_launcher_absent() {
        // No /usr/libexec/atomos-app-handler on disk: the chat-ui sheet
        // running in the desktop preview must still launch apps.
        assert_eq!(
            decide_launch_invocation("org.gnome.Calculator", None),
            LaunchInvocation::DirectGioFallback {
                app_id: "org.gnome.Calculator".into()
            }
        );
    }

    #[test]
    fn decide_launch_invocation_dispatches_to_app_handler_when_launcher_present() {
        // **Bug under TDD**: today's app_grid.rs click handler calls
        // `app.launch(&[], None)` unconditionally, bypassing the
        // `atomos-app-handler launch <id>` path that Phosh's own
        // `app-grid-button.c:activate_cb` takes. As a result the chat-ui
        // app-grid never folds home, never de-dups against an existing
        // toplevel, and never tells the app-handler that a new app was
        // opened — so the user "opens an app from the chat-ui sheet, then
        // can't find" the app-handler-side swipe-up-to-switcher gesture.
        //
        // Asserting on `decide_launch_invocation` (a stub today) reproduces
        // the bug as a deterministic local test. Stage 2 replaces the
        // stub body with the Phosh-parity dispatch decision and this test
        // goes green.
        let launcher = PathBuf::from(APP_HANDLER_LAUNCHER_PATH);
        assert_eq!(
            decide_launch_invocation("org.gnome.Calculator", Some(&launcher)),
            LaunchInvocation::DispatchAppHandler {
                app_id: "org.gnome.Calculator".into(),
                launcher: launcher.clone(),
            },
            "with /usr/libexec/atomos-app-handler available, chat-ui's \
             tile-click decision must round-trip through the app-handler \
             launch lifecycle (matches Phosh app-grid-button.c:activate_cb)",
        );
    }

    #[test]
    fn resolve_app_handler_launcher_uses_env_override_when_set() {
        let resolved = resolve_app_handler_launcher(Some("/tmp/atomos-app-handler-stub"), |_| {
            panic!("filesystem probe must not run when env override is set")
        });
        assert_eq!(
            resolved,
            Some(PathBuf::from("/tmp/atomos-app-handler-stub")),
        );
    }

    #[test]
    fn resolve_app_handler_launcher_ignores_blank_env_override() {
        // Empty / whitespace-only override falls through to the on-disk
        // probe; matches how shell scripts set env vars to "" to clear them.
        let resolved = resolve_app_handler_launcher(Some("   "), |p| {
            p == Path::new(APP_HANDLER_LAUNCHER_PATH)
        });
        assert_eq!(resolved, Some(PathBuf::from(APP_HANDLER_LAUNCHER_PATH)));
    }

    #[test]
    fn resolve_app_handler_launcher_returns_none_when_default_path_missing() {
        let resolved = resolve_app_handler_launcher(None, |_| false);
        assert!(
            resolved.is_none(),
            "without env override and default path absent, resolver must \
             return None so the chat-ui click handler falls through to gio",
        );
    }

    #[test]
    fn resolve_app_handler_launcher_returns_default_when_executable_on_disk() {
        let resolved = resolve_app_handler_launcher(None, |p| {
            p == Path::new(APP_HANDLER_LAUNCHER_PATH)
        });
        assert_eq!(resolved, Some(PathBuf::from(APP_HANDLER_LAUNCHER_PATH)));
    }

    #[test]
    fn decide_launch_invocation_must_not_skip_app_handler_when_launcher_present() {
        // Negative-form pin of the same contract: also fails today, kept
        // alongside the positive assertion so a regression that flips the
        // dispatch back to DirectGioFallback (e.g. someone reverts the
        // Stage 2 wiring) trips a name-targeted test rather than only
        // showing up as an inequality on the positive assertion.
        let launcher = PathBuf::from(APP_HANDLER_LAUNCHER_PATH);
        let inv = decide_launch_invocation("org.gnome.Calculator", Some(&launcher));
        assert!(
            !matches!(inv, LaunchInvocation::DirectGioFallback { .. }),
            "DirectGioFallback with a launcher path on disk reproduces the \
             bug: chat-ui app-grid bypasses /usr/libexec/atomos-app-handler",
        );
    }
}
