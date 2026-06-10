//! Persistent daemon event loop and state management.
//!
//! The daemon receives `LifecycleEvent` inputs (lock/unlock, toplevel count
//! changes, drag state changes) and processes them through the state machine
//! in `state.rs`. Only changed actions are dispatched — redundant transitions
//! are deduplicated.
//!
//! TDD: this module defines the event types and the processing loop so that
//! the entire lifecycle orchestration is unit-testable without Wayland or D-Bus.

use crate::{
    process, state,
    HomeDragState, HomeInputs, LockState,
};

/// Events that can change the daemon's view of the world.
///
/// Each variant corresponds to a real event source:
/// - `LockChanged` → D-Bus `org.freedesktop.login1.Session.Locked` property
/// - `ToplevelCountChanged` → `zwlr_foreign_toplevel_manager_v1` add/remove
/// - `DragStateChanged` → PhoshHome `notify::drag-state` D-Bus signal
/// - `InitialSync` → daemon startup, forces full dispatch
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LifecycleEvent {
    /// Session locked or unlocked.
    LockChanged(LockState),
    /// Number of open toplevel windows changed.
    ToplevelCountChanged(usize),
    /// PhoshHome drag surface state changed.
    DragStateChanged(HomeDragState),
    /// Initial sync at startup — dispatches both processes unconditionally.
    InitialSync,
}

/// The persistent daemon state. Owns the last-dispatched actions and the
/// current input snapshot so it can compute delta transitions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LifecycleDaemon {
    /// Current view of the world (updated by each event).
    inputs: HomeInputs,
    /// Last actions actually dispatched to processes.
    last: state::LastAction,
}

impl LifecycleDaemon {
    /// Create a daemon with default (safe) initial state: folded, unlocked,
    /// zero toplevels. The first `InitialSync` event will dispatch both
    /// processes.
    pub fn new() -> Self {
        Self {
            inputs: HomeInputs {
                drag_state: HomeDragState::Folded,
                locked: LockState::Unlocked,
                toplevel_count: 0,
            },
            last: state::LastAction::default(),
        }
    }

    /// Create a daemon with explicit initial state (for testing).
    pub fn with_inputs(inputs: HomeInputs) -> Self {
        Self {
            inputs,
            last: state::LastAction::default(),
        }
    }

    /// Process an event and return the actions that need to be dispatched.
    /// Actions that haven't changed since the last dispatch are suppressed.
    pub fn process_event(&mut self, event: &LifecycleEvent) -> DispatchResult {
        match event {
            LifecycleEvent::LockChanged(locked) => {
                self.inputs.locked = *locked;
            }
            LifecycleEvent::ToplevelCountChanged(count) => {
                self.inputs.toplevel_count = *count;
            }
            LifecycleEvent::DragStateChanged(drag) => {
                self.inputs.drag_state = *drag;
            }
            LifecycleEvent::InitialSync => {
                // Don't modify inputs — just force a full dispatch.
            }
        }

        let transition = state::compute_transition(&self.inputs, &self.last);
        self.last = state::apply_transition(&self.last, &transition);
        transition
    }

    /// Read-only access to current inputs (for testing).
    pub fn inputs(&self) -> &HomeInputs {
        &self.inputs
    }

    /// Read-only access to last dispatched actions (for testing).
    pub fn last_action(&self) -> &state::LastAction {
        &self.last
    }
}

impl Default for LifecycleDaemon {
    fn default() -> Self {
        Self::new()
    }
}

/// The result of processing an event. Contains only the actions that changed
/// since the last dispatch.
pub type DispatchResult = state::Transition;

/// Convert a `DispatchResult` into spawn commands for the managed processes.
/// Returns `None` entries for actions that don't need dispatching.
pub fn dispatch_commands(transition: &DispatchResult) -> (Option<process::ManagedCommand>, Option<process::ManagedCommand>) {
    let chat = transition.chat_ui.map(process::chat_ui_command);
    let bg = transition.home_bg.map(process::home_bg_command);
    (chat, bg)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ChatUiAction, HomeBgAction};

    // ---- RED: daemon event processing tests ----

    #[test]
    fn initial_sync_dispatches_both_processes() {
        let mut daemon = LifecycleDaemon::new();
        let result = daemon.process_event(&LifecycleEvent::InitialSync);
        assert!(result.chat_ui.is_some(), "initial sync must dispatch chat-ui");
        assert!(result.home_bg.is_some(), "initial sync must dispatch home-bg");
    }

    #[test]
    fn initial_sync_dispatches_overlay_and_top_for_home_screen() {
        let mut daemon = LifecycleDaemon::with_inputs(HomeInputs::home_screen());
        let result = daemon.process_event(&LifecycleEvent::InitialSync);
        // Home screen: Unfolded + Unlocked + 0 apps → chat-ui overlay, home-bg top
        assert_eq!(result.chat_ui, Some(ChatUiAction::Show { layer: crate::ChatUiLayer::Overlay }));
        assert_eq!(result.home_bg, Some(HomeBgAction::Show { layer: crate::HomeBgLayer::Top }));
    }

    #[test]
    fn initial_sync_from_folded_dispatches_background_for_home_bg() {
        // Default state: Folded + Unlocked + 0 apps → chat-ui overlay (0 apps),
        // home-bg background (folded)
        let mut daemon = LifecycleDaemon::new();
        let result = daemon.process_event(&LifecycleEvent::InitialSync);
        assert_eq!(result.chat_ui, Some(ChatUiAction::Show { layer: crate::ChatUiLayer::Overlay }));
        assert_eq!(result.home_bg, Some(HomeBgAction::Show { layer: crate::HomeBgLayer::Background }));
    }

    #[test]
    fn lock_event_hides_both_processes() {
        let mut daemon = LifecycleDaemon::new();
        daemon.process_event(&LifecycleEvent::InitialSync); // bootstrap

        let result = daemon.process_event(&LifecycleEvent::LockChanged(LockState::Locked));
        assert_eq!(result.chat_ui, Some(ChatUiAction::Hide));
        assert_eq!(result.home_bg, Some(HomeBgAction::Hide));
    }

    #[test]
    fn unlock_with_zero_toplevels_shows_overlay_and_top() {
        let mut daemon = LifecycleDaemon::with_inputs(HomeInputs::home_screen());
        daemon.process_event(&LifecycleEvent::InitialSync);
        // Unfold first so home-bg is on top
        daemon.process_event(&LifecycleEvent::LockChanged(LockState::Locked));

        let result = daemon.process_event(&LifecycleEvent::LockChanged(LockState::Unlocked));
        assert_eq!(result.chat_ui, Some(ChatUiAction::Show { layer: crate::ChatUiLayer::Overlay }));
        assert_eq!(result.home_bg, Some(HomeBgAction::Show { layer: crate::HomeBgLayer::Top }));
    }

    #[test]
    fn unlock_with_app_running_shows_bottom_not_overlay() {
        let mut daemon = LifecycleDaemon::new();
        daemon.process_event(&LifecycleEvent::InitialSync);
        daemon.process_event(&LifecycleEvent::ToplevelCountChanged(1));
        daemon.process_event(&LifecycleEvent::LockChanged(LockState::Locked));

        let result = daemon.process_event(&LifecycleEvent::LockChanged(LockState::Unlocked));
        assert_eq!(result.chat_ui, Some(ChatUiAction::Show { layer: crate::ChatUiLayer::Bottom }),
            "regression: unlock with app running must NOT promote to overlay");
        assert_eq!(result.home_bg, Some(HomeBgAction::Show { layer: crate::HomeBgLayer::Background }));
    }

    #[test]
    fn app_open_changes_chat_ui_to_bottom() {
        let mut daemon = LifecycleDaemon::new();
        daemon.process_event(&LifecycleEvent::InitialSync);

        let result = daemon.process_event(&LifecycleEvent::ToplevelCountChanged(1));
        // chat-ui changes overlay→bottom; home-bg stays background (deduplicated)
        assert_eq!(result.chat_ui, Some(ChatUiAction::Show { layer: crate::ChatUiLayer::Bottom }));
        assert!(result.home_bg.is_none(), "home-bg stays background, no change needed");
    }

    #[test]
    fn app_close_changes_chat_ui_to_overlay() {
        let mut daemon = LifecycleDaemon::new();
        daemon.process_event(&LifecycleEvent::InitialSync);
        daemon.process_event(&LifecycleEvent::ToplevelCountChanged(1));

        let result = daemon.process_event(&LifecycleEvent::ToplevelCountChanged(0));
        assert_eq!(result.chat_ui, Some(ChatUiAction::Show { layer: crate::ChatUiLayer::Overlay }),
            "last app closes → chat-ui overlay");
        // home-bg stays Background (drag_state still Folded)
        assert!(result.home_bg.is_none(), "home-bg stays background, deduplicated");
    }

    #[test]
    fn same_state_twice_produces_no_dispatch() {
        let mut daemon = LifecycleDaemon::new();
        daemon.process_event(&LifecycleEvent::InitialSync);

        let result = daemon.process_event(&LifecycleEvent::ToplevelCountChanged(0));
        assert!(result.chat_ui.is_none(), "same state → no dispatch");
        assert!(result.home_bg.is_none(), "same state → no dispatch");
    }

    #[test]
    fn second_lock_is_suppressed() {
        let mut daemon = LifecycleDaemon::new();
        daemon.process_event(&LifecycleEvent::InitialSync);
        daemon.process_event(&LifecycleEvent::LockChanged(LockState::Locked));

        let result = daemon.process_event(&LifecycleEvent::LockChanged(LockState::Locked));
        assert!(result.chat_ui.is_none(), "lock → lock is redundant");
        assert!(result.home_bg.is_none(), "lock → lock is redundant");
    }

    #[test]
    fn drag_unfolded_while_no_apps_promotes_home_bg_to_top() {
        let mut daemon = LifecycleDaemon::new();
        daemon.process_event(&LifecycleEvent::InitialSync);

        let result = daemon.process_event(&LifecycleEvent::DragStateChanged(HomeDragState::Unfolded));
        // chat-ui was already Overlay (0 apps folded), so it's deduplicated
        assert!(result.chat_ui.is_none(), "chat-ui stays overlay → no dispatch");
        // home-bg changes background→top
        assert_eq!(result.home_bg, Some(HomeBgAction::Show { layer: crate::HomeBgLayer::Top }),
            "unfolded → home-bg promoted from background to top");
    }

    #[test]
    fn drag_unfolded_while_app_running_still_overlay() {
        let mut daemon = LifecycleDaemon::new();
        daemon.process_event(&LifecycleEvent::InitialSync);
        daemon.process_event(&LifecycleEvent::ToplevelCountChanged(1));

        let result = daemon.process_event(&LifecycleEvent::DragStateChanged(HomeDragState::Unfolded));
        assert_eq!(result.chat_ui, Some(ChatUiAction::Show { layer: crate::ChatUiLayer::Overlay }),
            "unfolded home always puts chat-ui on overlay, regardless of app count");
    }

    #[test]
    fn full_lock_unlock_cycle_with_app() {
        let mut daemon = LifecycleDaemon::new();

        // Boot → home screen
        let r0 = daemon.process_event(&LifecycleEvent::InitialSync);
        assert!(r0.chat_ui.is_some());

        // Open app
        let r1 = daemon.process_event(&LifecycleEvent::ToplevelCountChanged(1));
        assert_eq!(r1.chat_ui, Some(ChatUiAction::Show { layer: crate::ChatUiLayer::Bottom }));

        // Lock
        let r2 = daemon.process_event(&LifecycleEvent::LockChanged(LockState::Locked));
        assert_eq!(r2.chat_ui, Some(ChatUiAction::Hide));

        // Unlock (app still running)
        let r3 = daemon.process_event(&LifecycleEvent::LockChanged(LockState::Unlocked));
        assert_eq!(r3.chat_ui, Some(ChatUiAction::Show { layer: crate::ChatUiLayer::Bottom }),
            "regression: unlock with app must NOT promote to overlay");

        // Close app
        let r4 = daemon.process_event(&LifecycleEvent::ToplevelCountChanged(0));
        assert_eq!(r4.chat_ui, Some(ChatUiAction::Show { layer: crate::ChatUiLayer::Overlay }));
    }

    #[test]
    fn dispatch_commands_converts_show_overlay() {
        let mut daemon = LifecycleDaemon::new();
        let result = daemon.process_event(&LifecycleEvent::InitialSync);
        let (chat_cmd, bg_cmd) = dispatch_commands(&result);
        assert!(chat_cmd.is_some());
        assert!(bg_cmd.is_some());
        let chat = chat_cmd.unwrap();
        assert_eq!(chat.argv, vec!["/usr/libexec/atomos-overview-chat-ui", "--show"]);
        assert_eq!(chat.env[0].0, "ATOMOS_OVERVIEW_CHAT_UI_LAYER");
        assert_eq!(chat.env[0].1, "overlay");
    }

    #[test]
    fn dispatch_commands_converts_hide() {
        let mut daemon = LifecycleDaemon::new();
        daemon.process_event(&LifecycleEvent::InitialSync);
        let result = daemon.process_event(&LifecycleEvent::LockChanged(LockState::Locked));
        let (chat_cmd, bg_cmd) = dispatch_commands(&result);
        assert!(chat_cmd.is_some());
        let chat = chat_cmd.unwrap();
        assert_eq!(chat.argv, vec!["/usr/libexec/atomos-overview-chat-ui", "--hide"]);
        assert!(chat.env.is_empty());
        let bg = bg_cmd.unwrap();
        assert_eq!(bg.argv, vec!["/usr/libexec/atomos-home-bg", "--hide"]);
    }

    #[test]
    fn no_dispatch_for_unchanged_state() {
        let mut daemon = LifecycleDaemon::new();
        daemon.process_event(&LifecycleEvent::InitialSync);

        let result = daemon.process_event(&LifecycleEvent::ToplevelCountChanged(0));
        let (chat_cmd, bg_cmd) = dispatch_commands(&result);
        assert!(chat_cmd.is_none());
        assert!(bg_cmd.is_none());
    }
}