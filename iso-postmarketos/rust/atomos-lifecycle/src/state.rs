//! State machine for deduplicating lifecycle transitions.
//!
//! The daemon receives `HomeInputs` events from multiple sources (Wayland
//! toplevel changes, lock state changes, drag state changes). Many events
//! produce the same action as the previous one. The state machine filters
//! those out so we only spawn/stop processes when the desired action actually
//! changes.

use crate::{chat_ui_action, home_bg_action, ChatUiAction, HomeBgAction, HomeInputs};

/// Snapshot of what the daemon has last told each managed process to do.
/// `None` means "never started / unknown" — next transition must act.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LastAction {
    pub chat_ui: Option<ChatUiAction>,
    pub home_bg: Option<HomeBgAction>,
}

impl Default for LastAction {
    fn default() -> Self {
        Self {
            chat_ui: None,
            home_bg: None,
        }
    }
}

/// Transition actions: only the processes whose desired state changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transition {
    pub chat_ui: Option<ChatUiAction>,
    pub home_bg: Option<HomeBgAction>,
}

/// Compute which processes need their lifecycle updated given the new
/// `HomeInputs` and the previous `LastAction`.
///
/// Returns a `Transition` containing only the actions that differ from the
/// previous state. If a process should hide again (e.g., it was already
/// hidden but the state hasn't changed), the transition omits it to avoid
/// redundant SIGTERM.
///
/// Mirrors the Phosh pattern where `atomos_phosh_sync_*` is only called when
/// the home state or lock state changes, not on every toplevel count tick.
pub fn compute_transition(inputs: &HomeInputs, last: &LastAction) -> Transition {
    let chat = chat_ui_action(inputs);
    let bg = home_bg_action(inputs);

    let chat_ui = if last.chat_ui != Some(chat) {
        Some(chat)
    } else {
        None
    };

    let home_bg = if last.home_bg != Some(bg) {
        Some(bg)
    } else {
        None
    };

    Transition { chat_ui, home_bg }
}

/// Update `LastAction` to reflect what was actually dispatched.
pub fn apply_transition(last: &LastAction, transition: &Transition) -> LastAction {
    LastAction {
        chat_ui: transition.chat_ui.or(last.chat_ui),
        home_bg: transition.home_bg.or(last.home_bg),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ChatUiLayer, HomeBgLayer, LockState, HomeDragState};

    fn home_screen() -> HomeInputs {
        HomeInputs::home_screen()
    }

    fn app_running() -> HomeInputs {
        HomeInputs::app_running()
    }

    fn locked() -> HomeInputs {
        HomeInputs::locked_no_apps()
    }

    #[test]
    fn first_transition_always_dispatches_both() {
        let last = LastAction::default();
        let t = compute_transition(&home_screen(), &last);
        assert!(t.chat_ui.is_some(), "first event must dispatch chat_ui");
        assert!(t.home_bg.is_some(), "first event must dispatch home_bg");
    }

    #[test]
    fn same_state_produces_no_transition() {
        let last = LastAction {
            chat_ui: Some(ChatUiAction::Show { layer: ChatUiLayer::Overlay }),
            home_bg: Some(HomeBgAction::Show { layer: HomeBgLayer::Top }),
        };
        let t = compute_transition(&home_screen(), &last);
        assert!(t.chat_ui.is_none(), "same action → no dispatch");
        assert!(t.home_bg.is_none(), "same action → no dispatch");
    }

    #[test]
    fn layer_change_from_overlay_to_bottom_dispatches() {
        let last = LastAction {
            chat_ui: Some(ChatUiAction::Show { layer: ChatUiLayer::Overlay }),
            home_bg: Some(HomeBgAction::Show { layer: HomeBgLayer::Top }),
        };
        let t = compute_transition(&app_running(), &last);
        assert_eq!(
            t.chat_ui,
            Some(ChatUiAction::Show { layer: ChatUiLayer::Bottom }),
            "layer changed → must re-spawn with new env"
        );
        assert_eq!(
            t.home_bg,
            Some(HomeBgAction::Show { layer: HomeBgLayer::Background }),
            "layer changed → must re-spawn with new env"
        );
    }

    #[test]
    fn layer_change_from_bottom_to_overlay_dispatches() {
        let last = LastAction {
            chat_ui: Some(ChatUiAction::Show { layer: ChatUiLayer::Bottom }),
            home_bg: Some(HomeBgAction::Show { layer: HomeBgLayer::Background }),
        };
        let t = compute_transition(&home_screen(), &last);
        assert_eq!(
            t.chat_ui,
            Some(ChatUiAction::Show { layer: ChatUiLayer::Overlay }),
            "app closed → promote chat-ui"
        );
        assert_eq!(
            t.home_bg,
            Some(HomeBgAction::Show { layer: HomeBgLayer::Top }),
            "app closed → promote home-bg"
        );
    }

    #[test]
    fn show_to_hide_dispatches_hide() {
        let last = LastAction {
            chat_ui: Some(ChatUiAction::Show { layer: ChatUiLayer::Overlay }),
            home_bg: Some(HomeBgAction::Show { layer: HomeBgLayer::Top }),
        };
        let t = compute_transition(&locked(), &last);
        assert_eq!(t.chat_ui, Some(ChatUiAction::Hide));
        assert_eq!(t.home_bg, Some(HomeBgAction::Hide));
    }

    #[test]
    fn hide_to_hide_is_suppressed() {
        let last = LastAction {
            chat_ui: Some(ChatUiAction::Hide),
            home_bg: Some(HomeBgAction::Hide),
        };
        let t = compute_transition(&locked(), &last);
        assert!(t.chat_ui.is_none(), "Hide → Hide is redundant");
        assert!(t.home_bg.is_none(), "Hide → Hide is redundant");
    }

    #[test]
    fn hide_to_show_dispatches_show() {
        let last = LastAction {
            chat_ui: Some(ChatUiAction::Hide),
            home_bg: Some(HomeBgAction::Hide),
        };
        let t = compute_transition(&home_screen(), &last);
        assert_eq!(t.chat_ui, Some(ChatUiAction::Show { layer: ChatUiLayer::Overlay }));
        assert_eq!(t.home_bg, Some(HomeBgAction::Show { layer: HomeBgLayer::Top }));
    }

    #[test]
    fn partial_transition_only_dispatches_changed_process() {
        let last = LastAction {
            chat_ui: Some(ChatUiAction::Show { layer: ChatUiLayer::Overlay }),
            home_bg: Some(HomeBgAction::Show { layer: HomeBgLayer::Background }),
        };
        let inputs = HomeInputs {
            drag_state: HomeDragState::Unfolded,
            locked: LockState::Unlocked,
            toplevel_count: 0,
        };
        let t = compute_transition(&inputs, &last);
        assert!(t.chat_ui.is_none(), "chat-ui layer didn't change");
        assert_eq!(
            t.home_bg,
            Some(HomeBgAction::Show { layer: HomeBgLayer::Top }),
            "home-bg layer changed"
        );
    }

    #[test]
    fn apply_transition_updates_last_action() {
        let last = LastAction::default();
        let transition = compute_transition(&home_screen(), &last);
        let updated = apply_transition(&last, &transition);
        assert_eq!(updated.chat_ui, Some(ChatUiAction::Show { layer: ChatUiLayer::Overlay }));
        assert_eq!(updated.home_bg, Some(HomeBgAction::Show { layer: HomeBgLayer::Top }));
    }

    #[test]
    fn apply_transition_preserves_unchanged() {
        let last = LastAction {
            chat_ui: Some(ChatUiAction::Show { layer: ChatUiLayer::Overlay }),
            home_bg: Some(HomeBgAction::Show { layer: HomeBgLayer::Background }),
        };
        let transition = Transition {
            chat_ui: None,
            home_bg: Some(HomeBgAction::Show { layer: HomeBgLayer::Top }),
        };
        let updated = apply_transition(&last, &transition);
        assert_eq!(updated.chat_ui, Some(ChatUiAction::Show { layer: ChatUiLayer::Overlay }));
        assert_eq!(updated.home_bg, Some(HomeBgAction::Show { layer: HomeBgLayer::Top }));
    }

    #[test]
    fn regression_lock_unlock_cycle() {
        let mut last = LastAction::default();

        // Boot → home screen
        let t1 = compute_transition(&home_screen(), &last);
        assert!(t1.chat_ui.is_some());
        last = apply_transition(&last, &t1);

        // App opens
        let t2 = compute_transition(&app_running(), &last);
        assert!(t2.chat_ui.is_some(), "layer must change overlay→bottom");
        last = apply_transition(&last, &t2);

        // Lock
        let t3 = compute_transition(&locked(), &last);
        assert_eq!(t3.chat_ui, Some(ChatUiAction::Hide), "lock must hide chat-ui");
        assert_eq!(t3.home_bg, Some(HomeBgAction::Hide), "lock must hide home-bg");
        last = apply_transition(&last, &t3);

        // Unlock (app still running)
        let unlocked_with_app = HomeInputs {
            drag_state: HomeDragState::Folded,
            locked: LockState::Unlocked,
            toplevel_count: 1,
        };
        let t4 = compute_transition(&unlocked_with_app, &last);
        assert_eq!(
            t4.chat_ui,
            Some(ChatUiAction::Show { layer: ChatUiLayer::Bottom }),
            "regression: unlock with app must NOT promote to overlay"
        );
        assert_eq!(
            t4.home_bg,
            Some(HomeBgAction::Show { layer: HomeBgLayer::Background }),
            "home-bg must not jump to top when app is visible"
        );
        last = apply_transition(&last, &t4);

        // App closes
        let t5 = compute_transition(&home_screen(), &last);
        assert_eq!(
            t5.chat_ui,
            Some(ChatUiAction::Show { layer: ChatUiLayer::Overlay }),
            "last app closes → chat-ui overlays phosh-home"
        );
    }
}