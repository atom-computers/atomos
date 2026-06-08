//! Pure-logic core for `atomos-app-handler`.
//!
//! Kept free of GTK / Wayland deps so `cargo test -p atomos-app-handler` runs
//! on any host (macOS dev machines included). Each runtime decision the
//! `app-gtk` binary makes is reachable through a small set of pure functions
//! consuming `Result<String, std::env::VarError>`, so the composition step is
//! exhaustively unit-testable.

pub mod desktop_launch;
pub mod handle;
pub mod launch;
pub mod launch_visibility;
pub mod session;

pub use desktop_launch::{
    dbus_activation_env_var_names_present, dbus_service_basename, default_dbus_service_path,
    desktop_entry_has_exec, desktop_entry_is_dbus_activatable, launch_requires_gdk_app_launch_context,
    parse_dbus_service_exec, APP_ID_FIREFOX_ESR, APP_ID_GNOME_CONSOLE,
    DBUS_ACTIVATION_SESSION_ENV_VARS, FIXTURE_FIREFOX_ESR_DESKTOP, FIXTURE_GNOME_CONSOLE_DESKTOP,
    FIXTURE_GNOME_CONSOLE_SERVICE_DAEMON, dbus_service_exec_is_daemon_only,
    desktop_exec_is_spawnable_for_window, parse_desktop_entry_primary_exec,
    should_spawn_dbus_service_exec_directly,
};
pub use launch::{LaunchPlan, app_ids_match, find_matching_toplevel, plan_launch};
pub use launch_visibility::{
    chat_ui_layer_must_change_after_tile_launch, foreground_xdg_toplevel_visible_with_chat_ui_layer,
    required_chat_ui_layer_after_tile_launch, CHAT_UI_LAYER_AFTER_SUCCESSFUL_LAUNCH,
    CHAT_UI_LAYER_APP_GRID_OPEN, REGRESSION_APP_DBUS_ACTIVATABLE,
    REGRESSION_APP_EXISTING_TOLEVEL,
};
pub use session::{
    derive_home_ipc, launcher_home_ipc_when_visibility_changes, home_target_name, HomeTarget,
    PhoshHomeIpc, PhoshHomeShellState, UiMode,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum LayerTarget {
    Background,
    Bottom,
    Top,
    Overlay,
}

impl LayerTarget {
    /// Z-order index matching the wlr-layer-shell protocol — smaller draws
    /// first (further from the user), larger draws last (closer).
    pub const fn z_index(self) -> u8 {
        match self {
            LayerTarget::Background => 0,
            LayerTarget::Bottom => 1,
            LayerTarget::Top => 2,
            LayerTarget::Overlay => 3,
        }
    }

    pub const fn from_name(name: &str) -> Option<Self> {
        match name.as_bytes() {
            b"background" => Some(LayerTarget::Background),
            b"bottom" => Some(LayerTarget::Bottom),
            b"top" => Some(LayerTarget::Top),
            b"overlay" => Some(LayerTarget::Overlay),
            _ => None,
        }
    }
}

/// Layer-shell namespace; stable so phoc/phosh rules can target this surface.
pub const LAYER_SHELL_NAMESPACE: &str = "atomos-app-handler";

/// Both the bottom-edge handle surface and the full-screen gesture surface
/// live on `Overlay` so the gesture handle always wins the bottom-edge sequence
/// ahead of phoc's own edge drag.
pub const DEFAULT_LAYER: LayerTarget = LayerTarget::Overlay;
pub const DEFAULT_LAYER_NAME: &str = "overlay";

/// Runtime enable gate env var.
pub const ENABLE_RUNTIME_ENV: &str = "ATOMOS_APP_HANDLER_ENABLE_RUNTIME";

/// Legacy env var from the app-switcher rename.
pub const ENABLE_RUNTIME_ENV_LEGACY: &str = "ATOMOS_APP_SWITCHER_ENABLE_RUNTIME";

/// Basename used for the pidfile/logfile/disable marker under
/// `XDG_RUNTIME_DIR`.
pub const RUNTIME_FILE_BASENAME: &str = "atomos-app-handler";

/// D-Bus name/path for Phosh home fold/unfold IPC.
pub const PHOSH_HOME_DBUS_NAME: &str = "org.atomos.PhoshHome";
pub const PHOSH_HOME_DBUS_PATH: &str = "/org/atomos/PhoshHome";

/// On-disk marker written by install-app-handler.sh to assert lifecycle wiring.
pub const OVERLAY_CONTRACT_BASENAME: &str = "app-handler-contract";
pub const OVERLAY_CONTRACT_VERSION: &str =
    "app-handler-v1-launch-switcher-dbus-home";

/// Phosh-side marker (`/etc/atomos/phosh-integration-contract`) must match
/// [`OVERLAY_CONTRACT_VERSION`] so final-verify catches half-upgraded images.
pub const PHOSH_INTEGRATION_CONTRACT_BASENAME: &str = "phosh-integration-contract";
pub const STACK_INTEGRATION_VERSION: &str = OVERLAY_CONTRACT_VERSION;

/// Defaults for the gesture knobs. Same numeric defaults as the legacy
/// `atomos-swipe-bridge` (which only fired open at `dy >= MIN_UPWARD_PX`);
/// we bump `OPEN_THRESHOLD` to 48 px so a stray finger-jitter at the bottom
/// edge doesn't accidentally pop the switcher.
/// Height of `atomos-top-bar` / Phosh `PHOSH_TOP_BAR_HEIGHT`. The swipe-up
/// fade overlay must not paint over this strip so the status bar stays crisp
/// while the foreground app dims.
pub const TOP_BAR_HEIGHT_PX: i32 = 32;

pub const DEFAULT_HANDLE_HEIGHT_PX: i32 = 24;
pub const DEFAULT_OPEN_THRESHOLD_PX: f64 = 48.0;
pub const DEFAULT_DISMISS_THRESHOLD_PX: f64 = 120.0;

pub type EnvResult = Result<String, std::env::VarError>;

pub fn parse_bool_env_value(value: &EnvResult) -> Option<bool> {
    match value.as_deref() {
        Ok("1") => Some(true),
        Ok("0") => Some(false),
        _ => None,
    }
}

pub fn env_flag_enabled(value: &EnvResult) -> bool {
    matches!(parse_bool_env_value(value), Some(true))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LifecycleAction {
    Run,
    Hide,
    Launch { app_id: String },
}

pub fn parse_lifecycle_action(args: &[String]) -> LifecycleAction {
    match args.first().map(String::as_str) {
        Some("--hide") => LifecycleAction::Hide,
        Some("launch") => LifecycleAction::Launch {
            app_id: args.get(1).cloned().unwrap_or_default(),
        },
        Some("--start") => LifecycleAction::Run,
        None => LifecycleAction::Run,
        _ => LifecycleAction::Run,
    }
}

pub fn parse_lifecycle_action_from_argv() -> LifecycleAction {
    let args: Vec<String> = std::env::args().skip(1).collect();
    parse_lifecycle_action(&args)
}

/// Visual fade ramp for the bottom-edge swipe-up gesture, in `[0.0, 1.0]`.
///
/// Egui-parity contract: a full-screen `Layer::Overlay` gesture surface
/// (so the wayland implicit pointer grab survives an upward drag of any
/// length — there is no surface boundary the pointer can leave) paints a
/// backdrop fade only over the foreground app's content rectangle — from
/// [`TOP_BAR_HEIGHT_PX`] down to the bottom handle strip. The visible
/// 24 px handle chrome lives on `Layer::Bottom` below the app; its
/// `exclusive_zone` reserves the bottom inset so the running app sits in
/// the closeable window between the top bar and the handle.
///
/// This pure function computes the alpha:
///
/// - `dy` follows GTK's `GestureDrag` convention: negative = upward.
/// - Returns `0.0` for a downward / zero / non-finite drag.
/// - Ramps linearly from `0.0` at `dy = 0` to `1.0` at
///   `dy = -open_threshold_px` so the fade peaks exactly when
///   [`evaluate_swipe_up`] returns [`SwipeOutcome::CloseApp`].
/// - Clamped at `1.0` for any further upward motion.
/// - Returns `0.0` when `open_threshold_px <= 0` so the
///   "threshold == 0 disables the close path" test/debug knob does
///   not also flash a full-screen black fade on every twitch.
pub fn handle_drag_progress(dy: f64, cfg: &GestureConfig) -> f32 {
    if !dy.is_finite() || cfg.open_threshold_px <= 0.0 {
        return 0.0;
    }
    let upward = (-dy).max(0.0);
    let ratio = (upward / cfg.open_threshold_px).clamp(0.0, 1.0);
    ratio as f32
}

/// Whether the bottom-edge handle surface should be mapped on the
/// compositor right now, given the current Wayland toplevel count.
///
/// Egui-parity contract:
///
/// - `count == 0` → home screen, only `atomos-overview-chat-ui` is
///   visible. The handle bar must not paint over the chat-ui app-grid /
///   chat input strip.
/// - `count >= 1` → at least one foreground app is open and chat-ui has
///   relayered to `Bottom`; the bottom handle strip and gesture overlay
///   must be mapped so the app sits above the handle in the layer stack.
///
/// Pure so `linux.rs` can call it from `on_toplevel_count_changed` and
/// the policy is unit-tested cross-platform.
pub fn should_show_handle(toplevel_count: usize) -> bool {
    toplevel_count > 0
}

/// Default argv[0] when `std::env::args()` returns nothing (e.g. embedded
/// invocation, exotic init systems). Matches the binary basename so the
/// GTK option-parser error path stays diagnosable in launcher logs.
pub const DEFAULT_PROGRAM_NAME: &str = "atomos-app-handler";

/// Compute the argv to hand to `gtk::Application::run_with_args(...)`.
///
/// Background: `g_application_run` runs its own option parser over the
/// argv it receives, before `connect_activate` fires. Our private
/// lifecycle flags (`--start`, `--show`, `--hide`) — already consumed by
/// [`parse_lifecycle_action_from_argv`] — are unknown to GTK. Letting
/// them through trips:
///
/// ```text
/// Unknown option --start
/// gtk::Application::run returned exit_code=ExitCode(1)
/// ```
///
/// which is the rc=1 the user sees in
/// `/run/user/<uid>/atomos-app-handler.log` when the autostart entry's
/// contract `Exec=/usr/libexec/atomos-app-handler --start` reaches the
/// binary unfiltered. The handle-bar surface is never `present()`'d and
/// the visible swipe-up bar above the running app is missing.
///
/// This helper is the single source of truth for that filter: it
/// preserves only argv[0] (the program name GTK expects to see), drops
/// every following flag, and falls back to [`DEFAULT_PROGRAM_NAME`] when
/// `actual_argv` is empty.
pub fn gtk_argv_for_run(actual_argv: &[String]) -> Vec<String> {
    let program = actual_argv
        .first()
        .filter(|s| !s.is_empty())
        .cloned()
        .unwrap_or_else(|| DEFAULT_PROGRAM_NAME.to_string());
    vec![program]
}

/// Convenience wrapper for the binary entry point: reads `std::env::args()`
/// and feeds it to [`gtk_argv_for_run`].
pub fn gtk_argv_for_run_from_process_argv() -> Vec<String> {
    let actual: Vec<String> = std::env::args().collect();
    gtk_argv_for_run(&actual)
}

/// One running app surfaced by the Wayland `zwlr_foreign_toplevel_manager_v1`
/// client. Kept as plain data so the egui preview, headless tests, and the
/// GTK card UI all consume the exact same shape.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToplevelEntry {
    /// Stable per-process id assigned by the wayland client thread. Not a
    /// Wayland object id — we don't expose those across the channel because
    /// the protocol handles aren't Send.
    pub id: u32,
    pub app_id: String,
    pub title: String,
    pub activated: bool,
}

impl ToplevelEntry {
    /// Display label preference: title if present, else app_id, else "Untitled".
    pub fn display_label(&self) -> &str {
        let title = self.title.trim();
        if !title.is_empty() {
            return title;
        }
        let app_id = self.app_id.trim();
        if !app_id.is_empty() {
            return app_id;
        }
        "Untitled"
    }
}

/// Outcome of a bottom-edge drag delta. The front-end calls this once per
/// drag-update event; if the result is `CloseApp` it should close the
/// foreground toplevel and stop polling further updates from the same gesture.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwipeOutcome {
    Ignore,
    CloseApp,
}

/// `dy` follows GTK's `GestureDrag` convention: negative = upward. Returns
/// `CloseApp` once the upward magnitude reaches `open_threshold_px`.
pub fn evaluate_swipe_up(dy: f64, cfg: &GestureConfig) -> SwipeOutcome {
    let upward = -dy;
    if upward.is_finite() && upward >= cfg.open_threshold_px && cfg.open_threshold_px > 0.0 {
        SwipeOutcome::CloseApp
    } else if upward.is_finite() && upward >= cfg.open_threshold_px && cfg.open_threshold_px == 0.0 {
        SwipeOutcome::Ignore
    } else {
        SwipeOutcome::Ignore
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GestureConfig {
    /// Bottom-edge handle strip height in CSS pixels.
    pub handle_height_px: i32,
    /// Vertical (upward) delta in CSS pixels at which a bottom-edge drag
    /// graduates from "ignore" to "close the foreground app".
    pub open_threshold_px: f64,
    /// Per-card vertical delta in CSS pixels at which a swipe-away closes
    /// the toplevel.
    pub dismiss_threshold_px: f64,
}

impl Default for GestureConfig {
    fn default() -> Self {
        Self {
            handle_height_px: DEFAULT_HANDLE_HEIGHT_PX,
            open_threshold_px: DEFAULT_OPEN_THRESHOLD_PX,
            dismiss_threshold_px: DEFAULT_DISMISS_THRESHOLD_PX,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CardOutcome {
    Ignore,
    /// User swept the card up (or down) past the dismiss threshold.
    Close,
    /// User released the card without moving past the threshold and the
    /// gesture qualifies as a tap (`|dx|+|dy|` small).
    Activate,
}

/// `dx`/`dy` are the cumulative drag deltas from gesture begin to end (GTK
/// `GestureDrag::offset` semantics on `connect_drag_end`). Returns:
///
/// - `Close` if the vertical magnitude reached `dismiss_threshold_px`.
/// - `Activate` if both magnitudes stayed below `tap_slop_px = 8`.
/// - `Ignore` otherwise (partial drag without intent — caller should snap
///   the card back).
pub fn evaluate_card_dismiss(dx: f64, dy: f64, cfg: &GestureConfig) -> CardOutcome {
    const TAP_SLOP_PX: f64 = 8.0;
    if !dx.is_finite() || !dy.is_finite() {
        return CardOutcome::Ignore;
    }
    let v = dy.abs();
    if cfg.dismiss_threshold_px > 0.0 && v >= cfg.dismiss_threshold_px {
        return CardOutcome::Close;
    }
    if dx.abs() <= TAP_SLOP_PX && v <= TAP_SLOP_PX {
        return CardOutcome::Activate;
    }
    CardOutcome::Ignore
}

/// Runtime configuration consumed by the GTK binary. Plain data so the
/// composition step is unit-testable end-to-end.
#[derive(Debug, Clone, PartialEq)]
pub struct RuntimeConfig {
    pub runtime_enabled: bool,
    pub gestures: GestureConfig,
}

#[derive(Debug, Clone)]
pub struct EnvInputs {
    pub runtime: EnvResult,
    pub handle_height: EnvResult,
    pub open_threshold: EnvResult,
    pub dismiss_threshold: EnvResult,
}

impl Default for EnvInputs {
    fn default() -> Self {
        Self {
            runtime: Err(std::env::VarError::NotPresent),
            handle_height: Err(std::env::VarError::NotPresent),
            open_threshold: Err(std::env::VarError::NotPresent),
            dismiss_threshold: Err(std::env::VarError::NotPresent),
        }
    }
}

impl EnvInputs {
    pub fn from_process_env() -> Self {
        Self {
            runtime: std::env::var(ENABLE_RUNTIME_ENV),
            handle_height: std::env::var("ATOMOS_APP_HANDLER_HANDLE_HEIGHT"),
            open_threshold: std::env::var("ATOMOS_APP_HANDLER_OPEN_THRESHOLD_PX"),
            dismiss_threshold: std::env::var("ATOMOS_APP_HANDLER_DISMISS_THRESHOLD_PX"),
        }
    }
}

fn parse_i32_min1(v: &EnvResult, default: i32) -> i32 {
    v.as_deref()
        .ok()
        .and_then(|s| s.trim().parse::<i32>().ok())
        .filter(|n| *n >= 1)
        .unwrap_or(default)
}

fn parse_f64_nonneg(v: &EnvResult, default: f64) -> f64 {
    v.as_deref()
        .ok()
        .and_then(|s| s.trim().parse::<f64>().ok())
        .filter(|x| x.is_finite() && *x >= 0.0)
        .unwrap_or(default)
}

pub fn runtime_enabled(value: &EnvResult) -> bool {
    if env_flag_enabled(value) {
        return true;
    }
    matches!(
        std::env::var(ENABLE_RUNTIME_ENV_LEGACY).as_deref(),
        Ok("1")
    )
}

pub fn compose_runtime_config(env: &EnvInputs) -> RuntimeConfig {
    RuntimeConfig {
        runtime_enabled: runtime_enabled(&env.runtime),
        gestures: GestureConfig {
            handle_height_px: parse_i32_min1(&env.handle_height, DEFAULT_HANDLE_HEIGHT_PX),
            open_threshold_px: parse_f64_nonneg(&env.open_threshold, DEFAULT_OPEN_THRESHOLD_PX),
            dismiss_threshold_px: parse_f64_nonneg(
                &env.dismiss_threshold,
                DEFAULT_DISMISS_THRESHOLD_PX,
            ),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::env::VarError;

    fn ok(s: &str) -> EnvResult {
        Ok(s.to_string())
    }
    fn missing() -> EnvResult {
        Err(VarError::NotPresent)
    }

    #[test]
    fn namespace_is_stable() {
        assert_eq!(LAYER_SHELL_NAMESPACE, "atomos-app-handler");
    }

    #[test]
    fn enable_runtime_env_matches_launcher_contract() {
        assert_eq!(ENABLE_RUNTIME_ENV, "ATOMOS_APP_HANDLER_ENABLE_RUNTIME");
    }

    #[test]
    fn runtime_file_basename_matches_launcher() {
        assert_eq!(RUNTIME_FILE_BASENAME, "atomos-app-handler");
    }

    #[test]
    fn overlay_contract_constants_are_stable() {
        assert_eq!(OVERLAY_CONTRACT_BASENAME, "app-handler-contract");
        assert_eq!(
            OVERLAY_CONTRACT_VERSION,
            "app-handler-v1-launch-switcher-dbus-home"
        );
    }

    #[test]
    fn default_layer_is_overlay() {
        assert_eq!(DEFAULT_LAYER, LayerTarget::Overlay);
        assert_eq!(LayerTarget::from_name(DEFAULT_LAYER_NAME), Some(DEFAULT_LAYER));
    }

    #[test]
    fn z_index_is_wlr_layer_shell_order() {
        assert!(LayerTarget::Background.z_index() < LayerTarget::Bottom.z_index());
        assert!(LayerTarget::Bottom.z_index() < LayerTarget::Top.z_index());
        assert!(LayerTarget::Top.z_index() < LayerTarget::Overlay.z_index());
    }

    #[test]
    fn parse_bool_env_value_strict() {
        assert_eq!(parse_bool_env_value(&ok("1")), Some(true));
        assert_eq!(parse_bool_env_value(&ok("0")), Some(false));
        assert_eq!(parse_bool_env_value(&ok("true")), None);
        assert_eq!(parse_bool_env_value(&missing()), None);
    }

    #[test]
    fn runtime_enabled_default_false() {
        assert!(!runtime_enabled(&missing()));
        assert!(!runtime_enabled(&ok("0")));
        assert!(!runtime_enabled(&ok("yes")));
    }

    #[test]
    fn runtime_enabled_when_flag_is_one() {
        assert!(runtime_enabled(&ok("1")));
    }

    #[test]
    fn gtk_argv_strips_start_flag_so_gtk_option_parser_never_sees_it() {
        // Reproduces the diagnose log line
        // `Unknown option --start / gtk::Application::run returned ExitCode(1)`:
        // the autostart entry passes --start, parse_lifecycle_action_from_argv
        // already mapped it to LifecycleAction::Run, so gtk must never see it.
        let argv = vec![
            "/usr/libexec/atomos-app-handler".to_string(),
            "--start".to_string(),
        ];
        assert_eq!(
            gtk_argv_for_run(&argv),
            vec!["/usr/libexec/atomos-app-handler".to_string()],
        );
    }

    #[test]
    fn gtk_argv_strips_show_flag() {
        let argv = vec![
            "/usr/libexec/atomos-app-handler".to_string(),
            "--hide".to_string(),
        ];
        assert_eq!(
            gtk_argv_for_run(&argv),
            vec!["/usr/libexec/atomos-app-handler".to_string()],
        );
    }

    #[test]
    fn gtk_argv_strips_launch_subcommand_and_app_id() {
        let argv = vec![
            "/usr/libexec/atomos-app-handler".to_string(),
            "launch".to_string(),
            "org.gnome.Calculator".to_string(),
        ];
        assert_eq!(
            gtk_argv_for_run(&argv),
            vec!["/usr/libexec/atomos-app-handler".to_string()],
        );
    }

    #[test]
    fn gtk_argv_preserves_program_name() {
        let argv = vec!["atomos-app-handler".to_string(), "--start".to_string()];
        assert_eq!(
            gtk_argv_for_run(&argv),
            vec!["atomos-app-handler".to_string()],
        );
    }

    #[test]
    fn gtk_argv_falls_back_to_default_when_actual_empty_or_blank() {
        assert_eq!(
            gtk_argv_for_run(&[]),
            vec![DEFAULT_PROGRAM_NAME.to_string()],
        );
        assert_eq!(
            gtk_argv_for_run(&["".to_string(), "--start".to_string()]),
            vec![DEFAULT_PROGRAM_NAME.to_string()],
        );
    }

    #[test]
    fn handle_is_hidden_on_home_screen_with_zero_toplevels() {
        // Egui-parity contract: only atomos-overview-chat-ui paints on
        // the home screen. The bottom-edge handle bar must not be
        // mapped while no app is in the foreground.
        assert!(!should_show_handle(0));
    }

    #[test]
    fn handle_is_visible_when_any_app_is_open() {
        for n in 1..=8usize {
            assert!(
                should_show_handle(n),
                "with {n} toplevel(s) open the handle must be mapped \
                 so the user can swipe up into the switcher",
            );
        }
    }

    #[test]
    fn handle_drag_progress_zero_when_idle() {
        let cfg = GestureConfig::default();
        assert_eq!(handle_drag_progress(0.0, &cfg), 0.0);
    }

    #[test]
    fn handle_drag_progress_zero_for_downward_drag() {
        // Downward drag (dy > 0) is not part of the open path — it must
        // NOT fade the running app out, otherwise a stray downward
        // touch would dim the whole screen.
        let cfg = GestureConfig::default();
        assert_eq!(handle_drag_progress(10.0, &cfg), 0.0);
        assert_eq!(handle_drag_progress(1000.0, &cfg), 0.0);
    }

    #[test]
    fn handle_drag_progress_ramps_linearly_to_one_at_open_threshold() {
        // Defaults: open_threshold_px = 48.0.
        let cfg = GestureConfig::default();
        assert!((handle_drag_progress(-12.0, &cfg) - 0.25).abs() < 1e-6);
        assert!((handle_drag_progress(-24.0, &cfg) - 0.5).abs() < 1e-6);
        assert!((handle_drag_progress(-36.0, &cfg) - 0.75).abs() < 1e-6);
        assert!((handle_drag_progress(-48.0, &cfg) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn handle_drag_progress_clamps_to_one_past_open_threshold() {
        // Past the threshold the switcher is opening / open, so the
        // fade must stay at 1.0 rather than over-fading.
        let cfg = GestureConfig::default();
        assert_eq!(handle_drag_progress(-100.0, &cfg), 1.0);
        assert_eq!(handle_drag_progress(-10_000.0, &cfg), 1.0);
    }

    #[test]
    fn handle_drag_progress_scales_with_open_threshold() {
        // A maintainer-tuned 96 px threshold means halfway = 48 px upward.
        let cfg = GestureConfig {
            handle_height_px: DEFAULT_HANDLE_HEIGHT_PX,
            open_threshold_px: 96.0,
            dismiss_threshold_px: DEFAULT_DISMISS_THRESHOLD_PX,
        };
        assert!((handle_drag_progress(-48.0, &cfg) - 0.5).abs() < 1e-6);
        assert!((handle_drag_progress(-96.0, &cfg) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn handle_drag_progress_zero_when_open_threshold_disabled() {
        // open_threshold_px == 0 disables the open path (see
        // evaluate_swipe_up_with_zero_threshold_disables_path). The fade
        // must follow suit — otherwise the first finger-twitch would
        // black out the whole screen with no possibility of opening.
        let cfg = GestureConfig {
            handle_height_px: DEFAULT_HANDLE_HEIGHT_PX,
            open_threshold_px: 0.0,
            dismiss_threshold_px: DEFAULT_DISMISS_THRESHOLD_PX,
        };
        assert_eq!(handle_drag_progress(-100.0, &cfg), 0.0);
    }

    #[test]
    fn handle_drag_progress_handles_non_finite() {
        let cfg = GestureConfig::default();
        assert_eq!(handle_drag_progress(f64::NAN, &cfg), 0.0);
        assert_eq!(handle_drag_progress(f64::INFINITY, &cfg), 0.0);
        assert_eq!(handle_drag_progress(f64::NEG_INFINITY, &cfg), 0.0);
    }

    #[test]
    fn handle_drag_progress_peaks_with_evaluate_swipe_up_outcome() {
        for thr in [12.0_f64, 24.0, 48.0, 96.0, 240.0] {
            let cfg = GestureConfig {
                handle_height_px: DEFAULT_HANDLE_HEIGHT_PX,
                open_threshold_px: thr,
                dismiss_threshold_px: 120.0,
            };
            let dy_at_threshold = -thr;
            assert!(
                (handle_drag_progress(dy_at_threshold, &cfg) - 1.0).abs() < 1e-6,
                "fade must reach 1.0 at dy={dy_at_threshold} for threshold={thr}",
            );
            assert_eq!(
                evaluate_swipe_up(dy_at_threshold, &cfg),
                SwipeOutcome::CloseApp,
                "evaluate_swipe_up must fire at the same dy the fade peaks",
            );
        }
    }

    #[test]
    fn parse_lifecycle_action_variants() {
        assert_eq!(parse_lifecycle_action(&[]), LifecycleAction::Run);
        assert_eq!(parse_lifecycle_action(&["".into()]), LifecycleAction::Run);
        assert_eq!(parse_lifecycle_action(&["foo".into()]), LifecycleAction::Run);
        assert_eq!(
            parse_lifecycle_action(&["--hide".into()]),
            LifecycleAction::Hide
        );
        assert_eq!(
            parse_lifecycle_action(&["launch".into(), "org.foo.App".into()]),
            LifecycleAction::Launch {
                app_id: "org.foo.App".into()
            }
        );
    }

    #[test]
    fn toplevel_entry_display_label_picks_title_first() {
        let t = ToplevelEntry {
            id: 1,
            app_id: "org.gnome.Terminal".into(),
            title: "george@phone:~".into(),
            activated: false,
        };
        assert_eq!(t.display_label(), "george@phone:~");
    }

    #[test]
    fn toplevel_entry_display_label_falls_back_to_app_id() {
        let t = ToplevelEntry {
            id: 1,
            app_id: "org.gnome.Terminal".into(),
            title: "".into(),
            activated: false,
        };
        assert_eq!(t.display_label(), "org.gnome.Terminal");
    }

    #[test]
    fn toplevel_entry_display_label_final_fallback() {
        let t = ToplevelEntry {
            id: 1,
            app_id: "   ".into(),
            title: "\t".into(),
            activated: false,
        };
        assert_eq!(t.display_label(), "Untitled");
    }

    #[test]
    fn evaluate_swipe_up_ignores_downward_drag() {
        let cfg = GestureConfig::default();
        assert_eq!(evaluate_swipe_up(0.0, &cfg), SwipeOutcome::Ignore);
        assert_eq!(evaluate_swipe_up(50.0, &cfg), SwipeOutcome::Ignore);
    }

    #[test]
    fn evaluate_swipe_up_fires_at_threshold() {
        let cfg = GestureConfig {
            handle_height_px: 24,
            open_threshold_px: 48.0,
            dismiss_threshold_px: 120.0,
        };
        assert_eq!(evaluate_swipe_up(-47.9, &cfg), SwipeOutcome::Ignore);
        assert_eq!(evaluate_swipe_up(-48.0, &cfg), SwipeOutcome::CloseApp);
        assert_eq!(evaluate_swipe_up(-200.0, &cfg), SwipeOutcome::CloseApp);
    }

    #[test]
    fn evaluate_swipe_up_handles_nan_and_inf() {
        let cfg = GestureConfig::default();
        assert_eq!(evaluate_swipe_up(f64::NAN, &cfg), SwipeOutcome::Ignore);
        assert_eq!(evaluate_swipe_up(f64::NEG_INFINITY, &cfg), SwipeOutcome::Ignore);
    }

    #[test]
    fn evaluate_swipe_up_with_zero_threshold_disables_path() {
        let cfg = GestureConfig {
            handle_height_px: 24,
            open_threshold_px: 0.0,
            dismiss_threshold_px: 120.0,
        };
        assert_eq!(evaluate_swipe_up(-500.0, &cfg), SwipeOutcome::Ignore);
    }

    #[test]
    fn evaluate_card_dismiss_close_on_vertical_threshold() {
        let cfg = GestureConfig::default();
        assert_eq!(evaluate_card_dismiss(0.0, -150.0, &cfg), CardOutcome::Close);
        assert_eq!(evaluate_card_dismiss(0.0, 150.0, &cfg), CardOutcome::Close);
    }

    #[test]
    fn evaluate_card_dismiss_activate_when_tap_slop() {
        let cfg = GestureConfig::default();
        assert_eq!(evaluate_card_dismiss(2.0, -3.0, &cfg), CardOutcome::Activate);
        assert_eq!(evaluate_card_dismiss(0.0, 0.0, &cfg), CardOutcome::Activate);
    }

    #[test]
    fn evaluate_card_dismiss_ignore_partial_swipe() {
        let cfg = GestureConfig::default();
        assert_eq!(evaluate_card_dismiss(0.0, -60.0, &cfg), CardOutcome::Ignore);
        assert_eq!(evaluate_card_dismiss(40.0, 0.0, &cfg), CardOutcome::Ignore);
    }

    #[test]
    fn evaluate_card_dismiss_handles_nan() {
        let cfg = GestureConfig::default();
        assert_eq!(
            evaluate_card_dismiss(f64::NAN, 0.0, &cfg),
            CardOutcome::Ignore
        );
        assert_eq!(
            evaluate_card_dismiss(0.0, f64::NAN, &cfg),
            CardOutcome::Ignore
        );
    }

    #[test]
    fn compose_runtime_config_defaults() {
        let cfg = compose_runtime_config(&EnvInputs::default());
        assert!(!cfg.runtime_enabled);
        assert_eq!(cfg.gestures.handle_height_px, DEFAULT_HANDLE_HEIGHT_PX);
        assert_eq!(cfg.gestures.open_threshold_px, DEFAULT_OPEN_THRESHOLD_PX);
        assert_eq!(
            cfg.gestures.dismiss_threshold_px,
            DEFAULT_DISMISS_THRESHOLD_PX
        );
    }

    #[test]
    fn compose_runtime_config_full_override() {
        let env = EnvInputs {
            runtime: ok("1"),
            handle_height: ok("36"),
            open_threshold: ok("80"),
            dismiss_threshold: ok("200"),
        };
        let cfg = compose_runtime_config(&env);
        assert!(cfg.runtime_enabled);
        assert_eq!(cfg.gestures.handle_height_px, 36);
        assert_eq!(cfg.gestures.open_threshold_px, 80.0);
        assert_eq!(cfg.gestures.dismiss_threshold_px, 200.0);
    }

    #[test]
    fn compose_runtime_config_rejects_invalid_values() {
        let env = EnvInputs {
            runtime: missing(),
            handle_height: ok("0"),       // below 1 → fall back to default
            open_threshold: ok("-1"),     // negative → fall back to default
            dismiss_threshold: ok("nope"), // non-numeric → fall back to default
        };
        let cfg = compose_runtime_config(&env);
        assert_eq!(cfg.gestures.handle_height_px, DEFAULT_HANDLE_HEIGHT_PX);
        assert_eq!(cfg.gestures.open_threshold_px, DEFAULT_OPEN_THRESHOLD_PX);
        assert_eq!(
            cfg.gestures.dismiss_threshold_px,
            DEFAULT_DISMISS_THRESHOLD_PX
        );
    }

    #[test]
    fn from_name_parses_canonical_values() {
        assert_eq!(LayerTarget::from_name("overlay"), Some(LayerTarget::Overlay));
        assert_eq!(LayerTarget::from_name("OVERLAY"), None, "case-sensitive");
        assert_eq!(LayerTarget::from_name(""), None);
    }
}
