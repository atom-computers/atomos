use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum ParityTier {
    MustHave,
    NiceToHave,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Capability {
    pub id: &'static str,
    pub parity_tier: ParityTier,
    pub description: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct VisualSpec {
    pub css_name: &'static str,
    pub top_clock: bool,
    pub keypad_unlock: bool,
    pub swipe_up_hint: bool,
    pub status_row: bool,
    pub lockshield_secondary_outputs: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct LockscreenSpec {
    pub visual: VisualSpec,
    pub capabilities: Vec<Capability>,
}

pub fn phosh_parity_spec() -> LockscreenSpec {
    LockscreenSpec {
        visual: VisualSpec {
            css_name: "phosh-lockscreen-inspired",
            top_clock: true,
            keypad_unlock: true,
            swipe_up_hint: true,
            status_row: true,
            lockshield_secondary_outputs: true,
        },
        capabilities: vec![
            Capability {
                id: "session_lock_protocol",
                parity_tier: ParityTier::MustHave,
                description: "Session lock protocol controls focus and rendering while locked",
            },
            Capability {
                id: "require_unlock",
                parity_tier: ParityTier::MustHave,
                description: "Unlock requires explicit credential flow",
            },
            Capability {
                id: "lock_before_sleep",
                parity_tier: ParityTier::MustHave,
                description: "System locks before suspend and wakes into locked state",
            },
            Capability {
                id: "status_affordances",
                parity_tier: ParityTier::MustHave,
                description: "Battery, network, time are visible on lockscreen",
            },
            Capability {
                id: "active_call_card",
                parity_tier: ParityTier::NiceToHave,
                description: "Ongoing call status can be shown while locked",
            },
            Capability {
                id: "extensible_extra_page",
                parity_tier: ParityTier::NiceToHave,
                description: "Optional extra lockscreen page for custom integrations",
            },
        ],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn has_all_must_have_capabilities() {
        let spec = phosh_parity_spec();
        let must_have: Vec<&str> = spec
            .capabilities
            .iter()
            .filter(|c| c.parity_tier == ParityTier::MustHave)
            .map(|c| c.id)
            .collect();
        let expected = vec![
            "session_lock_protocol",
            "require_unlock",
            "lock_before_sleep",
            "status_affordances",
        ];
        assert_eq!(must_have, expected);
    }

    #[test]
    fn visual_spec_matches_mobile_phosh_style_baseline() {
        let spec = phosh_parity_spec();
        assert!(spec.visual.top_clock);
        assert!(spec.visual.keypad_unlock);
        assert!(spec.visual.swipe_up_hint);
        assert!(spec.visual.status_row);
        assert!(spec.visual.lockshield_secondary_outputs);
    }
}
