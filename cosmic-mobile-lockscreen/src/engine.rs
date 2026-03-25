#![allow(dead_code)]
use crate::spec::{LockscreenSpec, phosh_parity_spec};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LockState {
    pub locked: bool,
    pub unlock_required: bool,
    pub active_page: &'static str,
    pub unlock_status: String,
}

impl Default for LockState {
    fn default() -> Self {
        Self {
            locked: false,
            unlock_required: true,
            active_page: "info",
            unlock_status: String::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LockEvent {
    LockRequested,
    UnlockFailed(&'static str),
    UnlockSucceeded,
    SwitchPage(&'static str),
}

#[derive(Debug, Clone)]
pub struct LockEngine {
    spec: LockscreenSpec,
    state: LockState,
}

impl LockEngine {
    pub fn new() -> Self {
        Self {
            spec: phosh_parity_spec(),
            state: LockState::default(),
        }
    }

    pub fn spec(&self) -> &LockscreenSpec {
        &self.spec
    }

    pub fn state(&self) -> &LockState {
        &self.state
    }

    pub fn apply(&mut self, event: LockEvent) {
        match event {
            LockEvent::LockRequested => {
                self.state.locked = true;
                self.state.active_page = "info";
                self.state.unlock_status.clear();
            }
            LockEvent::UnlockFailed(msg) => {
                self.state.locked = true;
                self.state.active_page = "keypad";
                self.state.unlock_status = msg.to_string();
            }
            LockEvent::UnlockSucceeded => {
                self.state.locked = false;
                self.state.active_page = "info";
                self.state.unlock_status.clear();
            }
            LockEvent::SwitchPage(page) => {
                self.state.active_page = page;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lock_unlock_state_machine_is_consistent() {
        let mut engine = LockEngine::new();
        assert!(!engine.state().locked);
        engine.apply(LockEvent::LockRequested);
        assert!(engine.state().locked);
        assert_eq!(engine.state().active_page, "info");

        engine.apply(LockEvent::UnlockFailed("bad pin"));
        assert!(engine.state().locked);
        assert_eq!(engine.state().active_page, "keypad");
        assert_eq!(engine.state().unlock_status, "bad pin");

        engine.apply(LockEvent::UnlockSucceeded);
        assert!(!engine.state().locked);
        assert_eq!(engine.state().active_page, "info");
        assert!(engine.state().unlock_status.is_empty());
    }
}
