//! App launch policy ported from Phosh `app-tracker.c`.
//!
//! Pure decision logic: given the current foreign-toplevel snapshot and a
//! requested `.desktop` id, decide whether to activate an existing window or
//! spawn a new process. Execution lives in the GTK binary.

use crate::ToplevelEntry;

/// Strip the `.desktop` suffix Phosh uses when comparing app ids.
pub fn strip_app_id_suffix(app_id: &str) -> &str {
    app_id.strip_suffix(".desktop").unwrap_or(app_id)
}

pub fn app_ids_match(requested: &str, toplevel_app_id: &str) -> bool {
    strip_app_id_suffix(requested) == strip_app_id_suffix(toplevel_app_id)
}

pub fn find_matching_toplevel<'a>(
    entries: &'a [ToplevelEntry],
    app_id: &str,
) -> Option<&'a ToplevelEntry> {
    entries.iter().find(|e| app_ids_match(app_id, &e.app_id))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LaunchPlan {
    ActivateExisting { toplevel_id: u32 },
    SpawnNew,
}

pub fn plan_launch(entries: &[ToplevelEntry], app_id: &str) -> LaunchPlan {
    if let Some(entry) = find_matching_toplevel(entries, app_id) {
        LaunchPlan::ActivateExisting {
            toplevel_id: entry.id,
        }
    } else {
        LaunchPlan::SpawnNew
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: u32, app_id: &str) -> ToplevelEntry {
        ToplevelEntry {
            id,
            app_id: app_id.into(),
            title: String::new(),
            activated: false,
        }
    }

    #[test]
    fn strip_app_id_suffix_removes_desktop() {
        assert_eq!(strip_app_id_suffix("org.gnome.Terminal.desktop"), "org.gnome.Terminal");
    }

    #[test]
    fn plan_launch_activate_when_matching_toplevel_exists() {
        let entries = vec![entry(1, "org.gnome.Terminal")];
        assert_eq!(
            plan_launch(&entries, "org.gnome.Terminal.desktop"),
            LaunchPlan::ActivateExisting { toplevel_id: 1 }
        );
    }

    #[test]
    fn plan_launch_spawn_when_no_match() {
        let entries = vec![entry(1, "org.gnome.Calculator")];
        assert_eq!(
            plan_launch(&entries, "org.gnome.Terminal.desktop"),
            LaunchPlan::SpawnNew
        );
    }
}
