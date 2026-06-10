//! Wayland toplevel count tracking.
//!
//! Connects to `zwlr_foreign_toplevel_manager_v1` and emits the count of
//! open toplevels whenever it changes. This is the same protocol the
//! app-handler uses, but this module only needs the count, not the
//! app IDs or handles.
//!
//! The `ToplevelCounter` is platform-specific (Linux Wayland only).
//! The `toplevel_count_from_env` function provides a fallback for testing
//! and one-shot mode.

use std::env;

/// Parse toplevel count from an env var, returning 0 on any parse error.
///
/// # Deprecation
/// Only used in one-shot mode. The daemon reads toplevel count via Wayland
/// (zwlr_foreign_toplevel_manager_v1) instead of env vars.
pub fn toplevel_count_from_env() -> usize {
    env::var("ATOMOS_LIFECYCLE_TOPLEVEL_COUNT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

/// Parse lock state from an env var.
///
/// # Deprecation
/// Only used in one-shot mode. The daemon reads lock state via D-Bus
/// (org.freedesktop.login1) instead of env vars.
pub fn lock_state_from_env() -> super::LockState {
    match env::var("ATOMOS_LIFECYCLE_LOCKED").as_deref() {
        Ok("1") | Ok("true") | Ok("locked") => super::LockState::Locked,
        _ => super::LockState::Unlocked,
    }
}

/// Parse drag state from an env var.
///
/// # Deprecation
/// Only used in one-shot mode. The daemon reads drag state via D-Bus
/// (org.atomos.Home DragChanged signal) instead of env vars.
pub fn drag_state_from_env() -> super::HomeDragState {
    match env::var("ATOMOS_LIFECYCLE_DRAG_STATE").as_deref() {
        Ok("unfolded") => super::HomeDragState::Unfolded,
        Ok("transition") => super::HomeDragState::Transition,
        _ => super::HomeDragState::Folded,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn toplevel_count_parses_valid_number() {
        env::set_var("ATOMOS_LIFECYCLE_TOPLEVEL_COUNT", "3");
        assert_eq!(toplevel_count_from_env(), 3);
        env::remove_var("ATOMOS_LIFECYCLE_TOPLEVEL_COUNT");
    }

    #[test]
    fn toplevel_count_defaults_to_zero_when_missing() {
        env::remove_var("ATOMOS_LIFECYCLE_TOPLEVEL_COUNT");
        assert_eq!(toplevel_count_from_env(), 0);
    }

    #[test]
    fn toplevel_count_defaults_to_zero_on_invalid() {
        env::set_var("ATOMOS_LIFECYCLE_TOPLEVEL_COUNT", "not-a-number");
        assert_eq!(toplevel_count_from_env(), 0);
        env::remove_var("ATOMOS_LIFECYCLE_TOPLEVEL_COUNT");
    }

#[test]
fn lock_state_locked_from_env() {
    for val in ["1", "true", "locked"] {
        env::set_var("ATOMOS_LIFECYCLE_LOCKED", val);
        assert_eq!(lock_state_from_env(), crate::LockState::Locked, "val={val}");
    }
    env::remove_var("ATOMOS_LIFECYCLE_LOCKED");
}

#[test]
fn lock_state_unlocked_from_env() {
    env::remove_var("ATOMOS_LIFECYCLE_LOCKED");
    assert_eq!(lock_state_from_env(), crate::LockState::Unlocked);
    env::set_var("ATOMOS_LIFECYCLE_LOCKED", "0");
    assert_eq!(lock_state_from_env(), crate::LockState::Unlocked);
    env::remove_var("ATOMOS_LIFECYCLE_LOCKED");
}

#[test]
fn drag_state_unfolded_from_env() {
    env::set_var("ATOMOS_LIFECYCLE_DRAG_STATE", "unfolded");
    assert_eq!(drag_state_from_env(), crate::HomeDragState::Unfolded);
    env::remove_var("ATOMOS_LIFECYCLE_DRAG_STATE");
}

#[test]
fn drag_state_folded_by_default() {
    env::remove_var("ATOMOS_LIFECYCLE_DRAG_STATE");
    assert_eq!(drag_state_from_env(), crate::HomeDragState::Folded);
}
}