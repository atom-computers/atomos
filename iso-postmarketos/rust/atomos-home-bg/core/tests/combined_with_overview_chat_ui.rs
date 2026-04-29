//! Combined-stack integration tests: pin down the invariants that let
//! `atomos-home-bg` and `atomos-overview-chat-ui` coexist layered on the same
//! Phosh compositor without colliding.
//!
//! These run with `cargo test -p atomos-home-bg` because the dev-dep on
//! `atomos-overview-chat-ui` core is local-only; neither the home-bg runtime
//! binary nor any production code path depends on overview-chat-ui.

use atomos_home_bg as home_bg;
use atomos_overview_chat_ui as chat;

#[test]
fn layer_shell_namespaces_are_distinct_and_non_empty() {
    assert_ne!(home_bg::LAYER_SHELL_NAMESPACE, chat::LAYER_SHELL_NAMESPACE);
    assert!(!home_bg::LAYER_SHELL_NAMESPACE.is_empty());
    assert!(!chat::LAYER_SHELL_NAMESPACE.is_empty());
}

#[test]
fn runtime_enable_env_vars_are_distinct() {
    assert_ne!(home_bg::ENABLE_RUNTIME_ENV, chat::ENABLE_RUNTIME_ENV);
}

#[test]
fn runtime_file_basenames_are_distinct() {
    assert_ne!(
        home_bg::RUNTIME_FILE_BASENAME,
        chat::RUNTIME_FILE_BASENAME
    );
}

#[test]
fn home_bg_layers_strictly_below_overview_chat_ui_default() {
    let chat_default_layer = home_bg::LayerTarget::from_name(chat::DEFAULT_LAYER_NAME)
        .expect("overview-chat-ui DEFAULT_LAYER_NAME must match a known LayerTarget variant");
    assert!(
        home_bg::DEFAULT_LAYER < chat_default_layer,
        "home-bg default layer {:?} ({}) must sit below overview-chat-ui default layer {:?} ({})",
        home_bg::DEFAULT_LAYER,
        home_bg::DEFAULT_LAYER.z_index(),
        chat_default_layer,
        chat_default_layer.z_index(),
    );
}

#[test]
fn overview_chat_ui_default_layer_is_interactive_tier() {
    let chat_default = home_bg::LayerTarget::from_name(chat::DEFAULT_LAYER_NAME)
        .expect("overview-chat-ui DEFAULT_LAYER_NAME must be a known variant");
    assert!(
        matches!(
            chat_default,
            home_bg::LayerTarget::Top | home_bg::LayerTarget::Overlay
        ),
        "overview-chat-ui default layer must be Top or Overlay, got {chat_default:?}"
    );
}

#[test]
fn home_bg_default_layer_is_below_all_interactive_tiers() {
    assert!(home_bg::DEFAULT_LAYER < home_bg::LayerTarget::Top);
    assert!(home_bg::DEFAULT_LAYER < home_bg::LayerTarget::Overlay);
}

#[test]
fn home_bg_is_non_interactive_by_default_when_stacked_under_overview_chat_ui() {
    let cfg = home_bg::compose_surface_config(&home_bg::EnvInputs::default());
    assert_eq!(cfg.input, home_bg::InputPolicy::NonInteractive);
    assert_eq!(cfg.layer, home_bg::DEFAULT_LAYER);
}

#[test]
fn lifecycle_actions_are_symmetric_between_stacks() {
    let chat_tokens = ["--show", "--hide"];
    for token in chat_tokens {
        assert_ne!(chat::parse_lifecycle_action(Some(token)), "run");
    }
    assert!(matches!(
        home_bg::parse_lifecycle_action(Some("--show")),
        home_bg::LifecycleAction::Show
    ));
    assert!(matches!(
        home_bg::parse_lifecycle_action(Some("--hide")),
        home_bg::LifecycleAction::Hide
    ));
    assert_eq!(chat::parse_lifecycle_action(None), "run");
    assert!(matches!(
        home_bg::parse_lifecycle_action(None),
        home_bg::LifecycleAction::Run
    ));
}
