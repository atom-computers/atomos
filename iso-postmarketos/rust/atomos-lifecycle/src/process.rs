//! Process spawn command construction.
//!
//! Pure functions that build the argv + environment for chat-ui and home-bg
//! lifecycle operations. No actual process spawning — that lives in the daemon
//! binary. Keeping this pure enables exhaustive unit testing without subprocess
//! side effects.

use crate::{ChatUiAction, ChatUiLayer, HomeBgAction, HomeBgLayer};

pub const CHAT_UI_LAUNCHER_PATH: &str = "/usr/libexec/atomos-overview-chat-ui";
pub const HOME_BG_LAUNCHER_PATH: &str = "/usr/libexec/atomos-home-bg";

pub const CHAT_UI_LAYER_ENV: &str = "ATOMOS_OVERVIEW_CHAT_UI_LAYER";
pub const HOME_BG_LAYER_ENV: &str = "ATOMOS_HOME_BG_LAYER";

/// A command to spawn (or signal) an external process. Pure value — no
/// side effects. The daemon binary interprets these into `std::process::Command`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManagedCommand {
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
}

impl ManagedCommand {
    fn show_with_env(bin: &str, env_key: &str, env_val: &str) -> Self {
        Self {
            argv: vec![bin.to_string(), "--show".to_string()],
            env: vec![(env_key.to_string(), env_val.to_string())],
        }
    }

    fn hide(bin: &str) -> Self {
        Self {
            argv: vec![bin.to_string(), "--hide".to_string()],
            env: vec![],
        }
    }
}

fn chat_ui_layer_name(layer: ChatUiLayer) -> &'static str {
    match layer {
        ChatUiLayer::Overlay => "overlay",
        ChatUiLayer::Bottom => "bottom",
    }
}

fn home_bg_layer_name(layer: HomeBgLayer) -> &'static str {
    match layer {
        HomeBgLayer::Top => "top",
        HomeBgLayer::Background => "background",
    }
}

/// Build the command to manage chat-ui given the desired action.
pub fn chat_ui_command(action: ChatUiAction) -> ManagedCommand {
    match action {
        ChatUiAction::Show { layer } => ManagedCommand::show_with_env(
            CHAT_UI_LAUNCHER_PATH,
            CHAT_UI_LAYER_ENV,
            chat_ui_layer_name(layer),
        ),
        ChatUiAction::Hide => ManagedCommand::hide(CHAT_UI_LAUNCHER_PATH),
    }
}

/// Build the command to manage home-bg given the desired action.
pub fn home_bg_command(action: HomeBgAction) -> ManagedCommand {
    match action {
        HomeBgAction::Show { layer } => ManagedCommand::show_with_env(
            HOME_BG_LAUNCHER_PATH,
            HOME_BG_LAYER_ENV,
            home_bg_layer_name(layer),
        ),
        HomeBgAction::Hide => ManagedCommand::hide(HOME_BG_LAUNCHER_PATH),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{HomeInputs, chat_ui_action, home_bg_action};

    #[test]
    fn chat_ui_show_overlay_command() {
        let cmd = chat_ui_command(ChatUiAction::Show { layer: ChatUiLayer::Overlay });
        assert_eq!(cmd.argv, vec!["/usr/libexec/atomos-overview-chat-ui", "--show"]);
        assert_eq!(cmd.env, vec![("ATOMOS_OVERVIEW_CHAT_UI_LAYER".to_string(), "overlay".to_string())]);
    }

    #[test]
    fn chat_ui_show_bottom_command() {
        let cmd = chat_ui_command(ChatUiAction::Show { layer: ChatUiLayer::Bottom });
        assert_eq!(cmd.argv, vec!["/usr/libexec/atomos-overview-chat-ui", "--show"]);
        assert_eq!(cmd.env, vec![("ATOMOS_OVERVIEW_CHAT_UI_LAYER".to_string(), "bottom".to_string())]);
    }

    #[test]
    fn chat_ui_hide_command() {
        let cmd = chat_ui_command(ChatUiAction::Hide);
        assert_eq!(cmd.argv, vec!["/usr/libexec/atomos-overview-chat-ui", "--hide"]);
        assert!(cmd.env.is_empty());
    }

    #[test]
    fn home_bg_show_top_command() {
        let cmd = home_bg_command(HomeBgAction::Show { layer: HomeBgLayer::Top });
        assert_eq!(cmd.argv, vec!["/usr/libexec/atomos-home-bg", "--show"]);
        assert_eq!(cmd.env, vec![("ATOMOS_HOME_BG_LAYER".to_string(), "top".to_string())]);
    }

    #[test]
    fn home_bg_show_background_command() {
        let cmd = home_bg_command(HomeBgAction::Show { layer: HomeBgLayer::Background });
        assert_eq!(cmd.argv, vec!["/usr/libexec/atomos-home-bg", "--show"]);
        assert_eq!(cmd.env, vec![("ATOMOS_HOME_BG_LAYER".to_string(), "background".to_string())]);
    }

    #[test]
    fn home_bg_hide_command() {
        let cmd = home_bg_command(HomeBgAction::Hide);
        assert_eq!(cmd.argv, vec!["/usr/libexec/atomos-home-bg", "--hide"]);
        assert!(cmd.env.is_empty());
    }

    #[test]
    fn launcher_paths_match_install_scripts() {
        assert_eq!(CHAT_UI_LAUNCHER_PATH, "/usr/libexec/atomos-overview-chat-ui");
        assert_eq!(HOME_BG_LAUNCHER_PATH, "/usr/libexec/atomos-home-bg");
    }

    #[test]
    fn env_var_names_match_launcher_contracts() {
        assert_eq!(CHAT_UI_LAYER_ENV, "ATOMOS_OVERVIEW_CHAT_UI_LAYER");
        assert_eq!(HOME_BG_LAYER_ENV, "ATOMOS_HOME_BG_LAYER");
    }

    #[test]
    fn end_to_end_home_screen_produces_overlay_show() {
        let inputs = HomeInputs::home_screen();
        let chat = chat_ui_command(chat_ui_action(&inputs));
        assert_eq!(chat.argv, vec!["/usr/libexec/atomos-overview-chat-ui", "--show"]);
        assert_eq!(chat.env[0].0, "ATOMOS_OVERVIEW_CHAT_UI_LAYER");
        assert_eq!(chat.env[0].1, "overlay");

        let bg = home_bg_command(home_bg_action(&inputs));
        assert_eq!(bg.argv, vec!["/usr/libexec/atomos-home-bg", "--show"]);
        assert_eq!(bg.env[0].0, "ATOMOS_HOME_BG_LAYER");
        assert_eq!(bg.env[0].1, "top");
    }

    #[test]
    fn end_to_end_app_running_produces_bottom_show() {
        let inputs = HomeInputs::app_running();
        let chat = chat_ui_command(chat_ui_action(&inputs));
        assert_eq!(chat.env[0].1, "bottom");

        let bg = home_bg_command(home_bg_action(&inputs));
        assert_eq!(bg.env[0].1, "background");
    }

    #[test]
    fn end_to_end_locked_produces_hide_for_both() {
        let inputs = HomeInputs::locked_no_apps();
        let chat = chat_ui_command(chat_ui_action(&inputs));
        assert_eq!(chat.argv[1], "--hide");

        let bg = home_bg_command(home_bg_action(&inputs));
        assert_eq!(bg.argv[1], "--hide");
    }
}