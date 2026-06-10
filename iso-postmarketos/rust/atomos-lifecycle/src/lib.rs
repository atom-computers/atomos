//! Pure decision logic for atomos process lifecycle orchestration.
//!
//! Mirrors the policy in Phosh `home.c` functions:
//!   - `atomos_phosh_chat_ui_layer_state_for_home`
//!   - `atomos_phosh_sync_overview_chat_ui_lifecycle`
//!   - `atomos_phosh_sync_home_bg_layer`
//!
//! Extracted into a pure Rust module so the composition is exhaustively
//! unit-testable cross-platform (macOS dev machines included).

pub mod daemon;
pub mod input;
pub mod process;
pub mod state;

#[cfg(all(feature = "wayland", target_os = "linux"))]
pub mod wayland;

#[cfg(all(feature = "daemon", target_os = "linux"))]
pub mod dbus;

/// Home surface drag state. Mirrors PhoshDragSurfaceState.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HomeDragState {
    Folded,
    Unfolded,
    Transition,
}

impl HomeDragState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Folded => "folded",
            Self::Unfolded => "unfolded",
            Self::Transition => "transition",
        }
    }

    /// Parse from the string values used in D-Bus signals.
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "folded" => Some(Self::Folded),
            "unfolded" => Some(Self::Unfolded),
            "transition" | "dragged" => Some(Self::Transition),
            _ => None,
        }
    }
}

/// Session lock state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LockState {
    Locked,
    Unlocked,
}

/// Combined state snapshot used by all decision functions.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HomeInputs {
    pub drag_state: HomeDragState,
    pub locked: LockState,
    pub toplevel_count: usize,
}

impl HomeInputs {
    pub fn home_screen() -> Self {
        Self {
            drag_state: HomeDragState::Unfolded,
            locked: LockState::Unlocked,
            toplevel_count: 0,
        }
    }

    pub fn app_running() -> Self {
        Self {
            drag_state: HomeDragState::Folded,
            locked: LockState::Unlocked,
            toplevel_count: 1,
        }
    }

    pub fn locked_no_apps() -> Self {
        Self {
            drag_state: HomeDragState::Folded,
            locked: LockState::Locked,
            toplevel_count: 0,
        }
    }

    pub fn locked_with_app() -> Self {
        Self {
            drag_state: HomeDragState::Folded,
            locked: LockState::Locked,
            toplevel_count: 1,
        }
    }
}

/// The layer chat-ui should render on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChatUiLayer {
    Overlay,
    Bottom,
}

/// Lifecycle action for the chat-ui process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChatUiAction {
    Show { layer: ChatUiLayer },
    Hide,
}

/// The layer home-bg should render on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HomeBgLayer {
    Top,
    Background,
}

/// Lifecycle action for the home-bg process.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HomeBgAction {
    Show { layer: HomeBgLayer },
    Hide,
}

// ---------------------------------------------------------------------------
// Decision functions (pure, testable)
// ---------------------------------------------------------------------------

/// Decide chat-ui layer based on home state.
///
/// Mirrors `atomos_phosh_chat_ui_layer_state_for_home`:
/// - If home is unfolded → overlay (above phosh-home which sits on TOP)
/// - If home is folded and unlocked with no toplevels → overlay
///   (folded phosh-home still covers BOTTOM chat-ui; treat as overview)
/// - If home is folded with apps or while locked → bottom
///   (under xdg-toplevels; or hidden entirely while locked)
pub fn chat_ui_layer(inputs: &HomeInputs) -> ChatUiLayer {
    match inputs.drag_state {
        HomeDragState::Unfolded => ChatUiLayer::Overlay,
        HomeDragState::Folded => {
            if inputs.locked == LockState::Unlocked && inputs.toplevel_count == 0 {
                ChatUiLayer::Overlay
            } else {
                ChatUiLayer::Bottom
            }
        }
        HomeDragState::Transition => ChatUiLayer::Bottom,
    }
}

/// Decide the full lifecycle action for chat-ui.
///
/// When locked, always hide (chat-ui must not paint above the lockscreen).
/// Otherwise, show on the layer returned by `chat_ui_layer`.
pub fn chat_ui_action(inputs: &HomeInputs) -> ChatUiAction {
    if inputs.locked == LockState::Locked {
        return ChatUiAction::Hide;
    }
    ChatUiAction::Show {
        layer: chat_ui_layer(inputs),
    }
}

/// Decide home-bg layer based on home state.
///
/// Mirrors `atomos_phosh_sync_home_bg_layer`:
/// - If locked → hide (lockscreen covers everything)
/// - If unfolded → top (above chat-ui on BOTTOM so home-bg shows through)
/// - If folded → background (below chat-ui on BOTTOM so the strip is visible)
pub fn home_bg_action(inputs: &HomeInputs) -> HomeBgAction {
    if inputs.locked == LockState::Locked {
        return HomeBgAction::Hide;
    }
    match inputs.drag_state {
        HomeDragState::Unfolded => HomeBgAction::Show {
            layer: HomeBgLayer::Top,
        },
        HomeDragState::Folded => HomeBgAction::Show {
            layer: HomeBgLayer::Background,
        },
        HomeDragState::Transition => HomeBgAction::Show {
            layer: HomeBgLayer::Background,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_ui_overlay_when_home_unfolded_even_with_apps() {
        let inputs = HomeInputs {
            drag_state: HomeDragState::Unfolded,
            locked: LockState::Unlocked,
            toplevel_count: 2,
        };
        assert_eq!(chat_ui_layer(&inputs), ChatUiLayer::Overlay);
    }

    #[test]
    fn chat_ui_overlay_when_folded_zero_toplevels_unlocked() {
        let inputs = HomeInputs {
            drag_state: HomeDragState::Folded,
            locked: LockState::Unlocked,
            toplevel_count: 0,
        };
        assert_eq!(chat_ui_layer(&inputs), ChatUiLayer::Overlay);
    }

    #[test]
    fn chat_ui_bottom_when_app_is_open() {
        let inputs = HomeInputs {
            drag_state: HomeDragState::Folded,
            locked: LockState::Unlocked,
            toplevel_count: 1,
        };
        assert_eq!(chat_ui_layer(&inputs), ChatUiLayer::Bottom);
    }

    #[test]
    fn chat_ui_bottom_when_folded_and_locked() {
        let inputs = HomeInputs {
            drag_state: HomeDragState::Folded,
            locked: LockState::Locked,
            toplevel_count: 0,
        };
        assert_eq!(chat_ui_layer(&inputs), ChatUiLayer::Bottom);
    }

    #[test]
    fn chat_ui_bottom_during_transition() {
        let inputs = HomeInputs {
            drag_state: HomeDragState::Transition,
            locked: LockState::Unlocked,
            toplevel_count: 0,
        };
        assert_eq!(chat_ui_layer(&inputs), ChatUiLayer::Bottom);
    }

    #[test]
    fn chat_ui_hidden_when_locked_regardless_of_apps() {
        let inputs = HomeInputs {
            drag_state: HomeDragState::Folded,
            locked: LockState::Locked,
            toplevel_count: 0,
        };
        assert_eq!(chat_ui_action(&inputs), ChatUiAction::Hide);

        let with_app = HomeInputs {
            drag_state: HomeDragState::Folded,
            locked: LockState::Locked,
            toplevel_count: 5,
        };
        assert_eq!(chat_ui_action(&with_app), ChatUiAction::Hide);
    }

    #[test]
    fn chat_ui_show_overlay_on_home_screen_after_unlock() {
        let inputs = HomeInputs::home_screen();
        assert_eq!(
            chat_ui_action(&inputs),
            ChatUiAction::Show {
                layer: ChatUiLayer::Overlay
            }
        );
    }

    #[test]
    fn chat_ui_show_bottom_when_app_running_after_unlock() {
        let inputs = HomeInputs::app_running();
        assert_eq!(
            chat_ui_action(&inputs),
            ChatUiAction::Show {
                layer: ChatUiLayer::Bottom
            }
        );
    }

    #[test]
    fn home_bg_hidden_when_locked() {
        let inputs = HomeInputs::locked_no_apps();
        assert_eq!(home_bg_action(&inputs), HomeBgAction::Hide);
    }

    #[test]
    fn home_bg_hidden_when_locked_with_app() {
        let inputs = HomeInputs::locked_with_app();
        assert_eq!(home_bg_action(&inputs), HomeBgAction::Hide);
    }

    #[test]
    fn home_bg_top_when_home_unfolded() {
        let inputs = HomeInputs::home_screen();
        assert_eq!(
            home_bg_action(&inputs),
            HomeBgAction::Show {
                layer: HomeBgLayer::Top
            }
        );
    }

    #[test]
    fn home_bg_background_when_app_running() {
        let inputs = HomeInputs::app_running();
        assert_eq!(
            home_bg_action(&inputs),
            HomeBgAction::Show {
                layer: HomeBgLayer::Background
            }
        );
    }

    #[test]
    fn home_bg_background_during_transition() {
        let inputs = HomeInputs {
            drag_state: HomeDragState::Transition,
            locked: LockState::Unlocked,
            toplevel_count: 0,
        };
        assert_eq!(
            home_bg_action(&inputs),
            HomeBgAction::Show {
                layer: HomeBgLayer::Background
            }
        );
    }

    #[test]
    fn regression_unlock_with_app_must_not_promote_chat_ui_to_overlay() {
        let inputs = HomeInputs {
            drag_state: HomeDragState::Folded,
            locked: LockState::Unlocked,
            toplevel_count: 1,
        };
        assert_eq!(
            chat_ui_action(&inputs),
            ChatUiAction::Show {
                layer: ChatUiLayer::Bottom
            }
        );
    }

    #[test]
    fn regression_unlock_with_app_home_bg_stays_background_not_top() {
        let inputs = HomeInputs {
            drag_state: HomeDragState::Folded,
            locked: LockState::Unlocked,
            toplevel_count: 1,
        };
        assert_eq!(
            home_bg_action(&inputs),
            HomeBgAction::Show {
                layer: HomeBgLayer::Background
            }
        );
    }

    #[test]
    fn chat_ui_bottom_when_many_apps_running() {
        for n in [1, 2, 5, 20] {
            let inputs = HomeInputs {
                drag_state: HomeDragState::Folded,
                locked: LockState::Unlocked,
                toplevel_count: n,
            };
            assert_eq!(chat_ui_layer(&inputs), ChatUiLayer::Bottom,
                "with {n} toplevels chat-ui must be BOTTOM, not overlay");
        }
    }

    #[test]
    fn all_predefined_states_are_consistent() {
        let h = HomeInputs::home_screen();
        assert_eq!(chat_ui_layer(&h), ChatUiLayer::Overlay);
        assert_eq!(home_bg_action(&h), HomeBgAction::Show { layer: HomeBgLayer::Top });

        let a = HomeInputs::app_running();
        assert_eq!(chat_ui_layer(&a), ChatUiLayer::Bottom);
        assert_eq!(home_bg_action(&a), HomeBgAction::Show { layer: HomeBgLayer::Background });
    }
}