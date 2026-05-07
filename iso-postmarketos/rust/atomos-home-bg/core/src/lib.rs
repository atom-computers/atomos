//! Pure-logic core for `atomos-home-bg`.
//!
//! Kept free of GTK/webkit deps so `cargo test -p atomos-home-bg` runs on any
//! host (macOS dev machines included) without an X11/Wayland session.
//!
//! Environment variables are read by the thin GTK binary and passed in here as
//! `Result<String, std::env::VarError>` so every decision is deterministically
//! unit-testable.

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
    ///
    /// Anchored to [wlr-layer-shell v4 `zwlr_layer_shell_v1_layer`](
    /// https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/blob/master/unstable/wlr-layer-shell-unstable-v1.xml
    /// ). Use for cross-surface ordering assertions in tests.
    pub const fn z_index(self) -> u8 {
        match self {
            LayerTarget::Background => 0,
            LayerTarget::Bottom => 1,
            LayerTarget::Top => 2,
            LayerTarget::Overlay => 3,
        }
    }

    /// Parse the same set of names accepted by `resolve_layer`, case-sensitive
    /// and without whitespace tolerance (the env-aware version handles that).
    /// Returns `None` for unknown names instead of falling back so tests can
    /// distinguish "user typo" from "legitimate default".
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InputPolicy {
    /// Empty Wayland input region + KeyboardMode::None. Pointer/touch falls
    /// through to whatever surface sits beneath us on the compositor stack.
    NonInteractive,
    /// Normal window input. Opt-in via `ATOMOS_HOME_BG_INTERACTIVE=1` for
    /// debugging only; production use-case is a wallpaper-style surface.
    Interactive,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LifecycleAction {
    Run,
    Show,
    Hide,
}

/// Layer-shell namespace; stable so phoc/phosh rules can target this surface.
pub const LAYER_SHELL_NAMESPACE: &str = "atomos-home-bg";

/// Content path shipped in the rootfs overlay. A React `dist/` is expected to
/// land here (packaging is independent of this crate).
pub const DEFAULT_CONTENT_PATH: &str = "/usr/share/atomos-home-bg/index.html";

/// Canonical default when `ATOMOS_HOME_BG_LAYER` is unset.
///
/// **Not** [`LayerTarget::Background`]: postmarketOS / Phosh still owns a
/// `background`-layer surface (solid color when AtomOS disables the JPEG via
/// `apply-atomos-wallpaper-dconf.sh`); stacking a second client on `background`
/// is compositor-dependent. `bottom` sits *above* that layer but still below the
/// overview chat UI (default `top`) and other shell UI.
pub const DEFAULT_LAYER: LayerTarget = LayerTarget::Bottom;

/// String form of `DEFAULT_LAYER`; matches the launcher default and the env
/// var the binary parses.
pub const DEFAULT_LAYER_NAME: &str = "bottom";

/// Runtime enable gate env var — paired with the matching overview-chat-ui
/// constant so combined-stack tests can assert they are distinct.
pub const ENABLE_RUNTIME_ENV: &str = "ATOMOS_HOME_BG_ENABLE_RUNTIME";

/// Basename used for the pidfile/logfile/disable marker under
/// `XDG_RUNTIME_DIR`. Installer launcher writes `<basename>.pid` etc.
pub const RUNTIME_FILE_BASENAME: &str = "atomos-home-bg";

/// Fallback served via `data:` URL when the default content path is absent at
/// startup. Kept minimal on purpose so missing rootfs content still produces
/// a well-formed, opaque dark page rather than a WebKit error screen — same
/// `#0a0a0a` base color as the shipped placeholder (`index.html`), so the
/// home-bg surface stays opaque even with no `event-horizon.js` available.
pub const BLANK_FALLBACK_DATA_URL: &str =
    "data:text/html,%3Chtml%3E%3Cbody%20style=%22margin:0;background:%230a0a0a%22%3E%3C/body%3E%3C/html%3E";

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

fn has_supported_scheme(url: &str) -> bool {
    url.starts_with("file://") || url.starts_with("http://") || url.starts_with("https://")
}

/// Resolve the URL the webview should load.
///
/// Priority:
/// 1. `ATOMOS_HOME_BG_URL` if set to a supported scheme (`file`/`http`/`https`).
/// 2. `file://` + `DEFAULT_CONTENT_PATH` otherwise.
///
/// Unsupported schemes (e.g. `javascript:`, `about:`) fall back to the default
/// rather than being propagated into the webview.
pub fn resolve_content_url(env_value: &EnvResult) -> String {
    if let Ok(raw) = env_value.as_deref() {
        let trimmed = raw.trim();
        if !trimmed.is_empty() && has_supported_scheme(trimmed) {
            return trimmed.to_string();
        }
    }
    format!("file://{}", DEFAULT_CONTENT_PATH)
}

/// Choose the layer-shell layer. Unset / empty / unknown values use
/// [`DEFAULT_LAYER`] (see module docs — `bottom` to sit above Phosh's background
/// layer).
pub fn resolve_layer(env_value: &EnvResult) -> LayerTarget {
    match env_value
        .as_deref()
        .map(str::trim)
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Ok("background") => LayerTarget::Background,
        Ok("bottom") => LayerTarget::Bottom,
        Ok("top") => LayerTarget::Top,
        Ok("overlay") => LayerTarget::Overlay,
        Ok(_) | Err(_) => DEFAULT_LAYER,
    }
}

/// Non-interactive by default. Anything other than literal `1` stays
/// non-interactive so a stray `true`/`yes`/empty env value doesn't
/// accidentally swallow user input on the home screen.
pub fn resolve_input_policy(env_value: &EnvResult) -> InputPolicy {
    if env_flag_enabled(env_value) {
        InputPolicy::Interactive
    } else {
        InputPolicy::NonInteractive
    }
}

/// Runtime gate. Production rootfs ships with this OFF so the surface only
/// appears on devices that explicitly opt in via overlay or launcher override.
pub fn runtime_enabled(env_value: &EnvResult) -> bool {
    env_flag_enabled(env_value)
}

pub fn parse_lifecycle_action(arg: Option<&str>) -> LifecycleAction {
    match arg {
        Some("--show") => LifecycleAction::Show,
        Some("--hide") => LifecycleAction::Hide,
        _ => LifecycleAction::Run,
    }
}

/// Convenience bundle consumed by the GTK binary. Kept as plain data so the
/// composition step is unit-testable end-to-end.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SurfaceConfig {
    pub url: String,
    pub layer: LayerTarget,
    pub input: InputPolicy,
    pub runtime_enabled: bool,
}

#[derive(Debug, Clone)]
pub struct EnvInputs {
    pub url: EnvResult,
    pub layer: EnvResult,
    pub interactive: EnvResult,
    pub runtime: EnvResult,
}

impl Default for EnvInputs {
    fn default() -> Self {
        Self {
            url: Err(std::env::VarError::NotPresent),
            layer: Err(std::env::VarError::NotPresent),
            interactive: Err(std::env::VarError::NotPresent),
            runtime: Err(std::env::VarError::NotPresent),
        }
    }
}

impl EnvInputs {
    pub fn from_process_env() -> Self {
        Self {
            url: std::env::var("ATOMOS_HOME_BG_URL"),
            layer: std::env::var("ATOMOS_HOME_BG_LAYER"),
            interactive: std::env::var("ATOMOS_HOME_BG_INTERACTIVE"),
            runtime: std::env::var("ATOMOS_HOME_BG_ENABLE_RUNTIME"),
        }
    }
}

pub fn compose_surface_config(env: &EnvInputs) -> SurfaceConfig {
    SurfaceConfig {
        url: resolve_content_url(&env.url),
        layer: resolve_layer(&env.layer),
        input: resolve_input_policy(&env.interactive),
        runtime_enabled: runtime_enabled(&env.runtime),
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
        assert_eq!(LAYER_SHELL_NAMESPACE, "atomos-home-bg");
    }

    #[test]
    fn default_content_path_lives_under_usr_share() {
        assert!(DEFAULT_CONTENT_PATH.starts_with("/usr/share/atomos-home-bg/"));
    }

    #[test]
    fn resolve_content_url_defaults_to_rootfs_path() {
        assert_eq!(
            resolve_content_url(&missing()),
            format!("file://{}", DEFAULT_CONTENT_PATH)
        );
    }

    #[test]
    fn resolve_content_url_accepts_file_scheme() {
        assert_eq!(
            resolve_content_url(&ok("file:///opt/app/index.html")),
            "file:///opt/app/index.html"
        );
    }

    #[test]
    fn resolve_content_url_accepts_http_and_https() {
        assert_eq!(
            resolve_content_url(&ok("http://127.0.0.1:5173/")),
            "http://127.0.0.1:5173/"
        );
        assert_eq!(
            resolve_content_url(&ok("https://example.test/home")),
            "https://example.test/home"
        );
    }

    #[test]
    fn resolve_content_url_rejects_unsupported_schemes() {
        assert_eq!(
            resolve_content_url(&ok("javascript:alert(1)")),
            format!("file://{}", DEFAULT_CONTENT_PATH)
        );
        assert_eq!(
            resolve_content_url(&ok("about:blank")),
            format!("file://{}", DEFAULT_CONTENT_PATH)
        );
    }

    #[test]
    fn resolve_content_url_ignores_empty_and_whitespace() {
        assert_eq!(
            resolve_content_url(&ok("   ")),
            format!("file://{}", DEFAULT_CONTENT_PATH)
        );
    }

    #[test]
    fn resolve_content_url_trims_surrounding_whitespace() {
        assert_eq!(
            resolve_content_url(&ok("  file:///tmp/x.html  ")),
            "file:///tmp/x.html"
        );
    }

    #[test]
    fn resolve_layer_defaults_to_default_layer() {
        assert_eq!(resolve_layer(&missing()), DEFAULT_LAYER);
        assert_eq!(resolve_layer(&ok("")), DEFAULT_LAYER);
        assert_eq!(resolve_layer(&ok("garbage")), DEFAULT_LAYER);
    }

    #[test]
    fn resolve_layer_parses_all_variants() {
        assert_eq!(resolve_layer(&ok("background")), LayerTarget::Background);
        assert_eq!(resolve_layer(&ok("bottom")), LayerTarget::Bottom);
        assert_eq!(resolve_layer(&ok("top")), LayerTarget::Top);
        assert_eq!(resolve_layer(&ok("overlay")), LayerTarget::Overlay);
    }

    #[test]
    fn resolve_layer_is_case_insensitive_and_trims() {
        assert_eq!(resolve_layer(&ok("  BoTtOm ")), LayerTarget::Bottom);
        assert_eq!(resolve_layer(&ok("Top")), LayerTarget::Top);
    }

    #[test]
    fn resolve_input_policy_defaults_non_interactive() {
        assert_eq!(resolve_input_policy(&missing()), InputPolicy::NonInteractive);
        assert_eq!(resolve_input_policy(&ok("0")), InputPolicy::NonInteractive);
        assert_eq!(
            resolve_input_policy(&ok("true")),
            InputPolicy::NonInteractive,
            "only literal '1' flips interactive to avoid swallowing home-screen input"
        );
    }

    #[test]
    fn resolve_input_policy_opt_in() {
        assert_eq!(resolve_input_policy(&ok("1")), InputPolicy::Interactive);
    }

    #[test]
    fn runtime_enabled_default_false() {
        assert!(!runtime_enabled(&missing()));
        assert!(!runtime_enabled(&ok("0")));
    }

    #[test]
    fn runtime_enabled_when_flag_is_one() {
        assert!(runtime_enabled(&ok("1")));
    }

    #[test]
    fn parse_lifecycle_action_variants() {
        assert_eq!(parse_lifecycle_action(None), LifecycleAction::Run);
        assert_eq!(parse_lifecycle_action(Some("")), LifecycleAction::Run);
        assert_eq!(parse_lifecycle_action(Some("foo")), LifecycleAction::Run);
        assert_eq!(parse_lifecycle_action(Some("--show")), LifecycleAction::Show);
        assert_eq!(parse_lifecycle_action(Some("--hide")), LifecycleAction::Hide);
    }

    #[test]
    fn compose_surface_config_defaults() {
        let cfg = compose_surface_config(&EnvInputs::default());
        assert_eq!(cfg.url, format!("file://{}", DEFAULT_CONTENT_PATH));
        assert_eq!(cfg.layer, DEFAULT_LAYER);
        assert_eq!(cfg.input, InputPolicy::NonInteractive);
        assert!(!cfg.runtime_enabled);
    }

    #[test]
    fn compose_surface_config_full_override() {
        let env = EnvInputs {
            url: ok("https://dash.local/home"),
            layer: ok("overlay"),
            interactive: ok("1"),
            runtime: ok("1"),
        };
        let cfg = compose_surface_config(&env);
        assert_eq!(cfg.url, "https://dash.local/home");
        assert_eq!(cfg.layer, LayerTarget::Overlay);
        assert_eq!(cfg.input, InputPolicy::Interactive);
        assert!(cfg.runtime_enabled);
    }

    #[test]
    fn blank_fallback_is_well_formed_data_url() {
        assert!(BLANK_FALLBACK_DATA_URL.starts_with("data:text/html,"));
        // Dark base #0a0a0a (URL-encoded as %230a0a0a). Must match the
        // visual contract of the shipped placeholder so a missing rootfs
        // file doesn't suddenly turn the home-bg surface into a different
        // color or a transparent rect.
        assert!(
            BLANK_FALLBACK_DATA_URL.contains("%230a0a0a"),
            "fallback must paint opaque #0a0a0a, matching the placeholder's base color"
        );
        assert!(
            !BLANK_FALLBACK_DATA_URL.contains("transparent"),
            "fallback must not be transparent — would let unrelated layers bleed through"
        );
    }

    #[test]
    fn z_index_is_wlr_layer_shell_order() {
        assert!(LayerTarget::Background.z_index() < LayerTarget::Bottom.z_index());
        assert!(LayerTarget::Bottom.z_index() < LayerTarget::Top.z_index());
        assert!(LayerTarget::Top.z_index() < LayerTarget::Overlay.z_index());
    }

    #[test]
    fn layer_target_ord_matches_z_index() {
        assert!(LayerTarget::Background < LayerTarget::Bottom);
        assert!(LayerTarget::Bottom < LayerTarget::Top);
        assert!(LayerTarget::Top < LayerTarget::Overlay);
    }

    #[test]
    fn from_name_parses_canonical_values() {
        assert_eq!(LayerTarget::from_name("background"), Some(LayerTarget::Background));
        assert_eq!(LayerTarget::from_name("bottom"), Some(LayerTarget::Bottom));
        assert_eq!(LayerTarget::from_name("top"), Some(LayerTarget::Top));
        assert_eq!(LayerTarget::from_name("overlay"), Some(LayerTarget::Overlay));
        assert_eq!(LayerTarget::from_name("BACKGROUND"), None, "case-sensitive");
        assert_eq!(LayerTarget::from_name(""), None);
    }

    #[test]
    fn default_layer_name_matches_default_layer_variant() {
        assert_eq!(LayerTarget::from_name(DEFAULT_LAYER_NAME), Some(DEFAULT_LAYER));
        assert_eq!(resolve_layer(&missing()), DEFAULT_LAYER);
    }

    #[test]
    fn enable_runtime_env_matches_launcher_contract() {
        // build-image.sh verify_home_bg_launcher_contract greps for this;
        // keep the string stable.
        assert_eq!(ENABLE_RUNTIME_ENV, "ATOMOS_HOME_BG_ENABLE_RUNTIME");
    }

    #[test]
    fn runtime_file_basename_matches_launcher() {
        assert_eq!(RUNTIME_FILE_BASENAME, "atomos-home-bg");
    }
}
