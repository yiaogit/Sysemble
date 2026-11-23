//! Core types for Sysemble.
//!
//! The build engine is not implemented yet. This crate currently holds the
//! state machine that the engine will enforce, so the rules can be reviewed
//! and tested before any build code exists.

/// Crate version, wired to `Cargo.toml`.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Version of the `buildspec.yaml` format this crate understands.
pub const API_VERSION: &str = "sysemble/v1";

/// Lifecycle of a system build.
///
/// A build may only move forward one step at a time. "Built" does not imply
/// "Tested", and "Tested" does not imply "Ready": those are separate claims
/// that must be earned separately.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    Draft,
    Validated,
    Planned,
    Building,
    Built,
    Tested,
    Ready,
    Failed,
}

impl Stage {
    /// Every stage, in lifecycle order.
    pub const ALL: [Stage; 8] = [
        Stage::Draft,
        Stage::Validated,
        Stage::Planned,
        Stage::Building,
        Stage::Built,
        Stage::Tested,
        Stage::Ready,
        Stage::Failed,
    ];

    /// Stable identifier used in logs, JSON, and the UI.
    pub fn as_str(self) -> &'static str {
        match self {
            Stage::Draft => "draft",
            Stage::Validated => "validated",
            Stage::Planned => "planned",
            Stage::Building => "building",
            Stage::Built => "built",
            Stage::Tested => "tested",
            Stage::Ready => "ready",
            Stage::Failed => "failed",
        }
    }

    /// True when moving from `self` to `next` is a legal transition.
    ///
    /// Skipping a stage is rejected on purpose: a build cannot be "tested"
    /// without having been "built", and cannot be "ready" without a test run.
    pub fn can_advance_to(self, next: Stage) -> bool {
        use Stage::*;
        match (self, next) {
            (Draft, Validated)
            | (Validated, Planned)
            | (Planned, Building)
            | (Building, Built)
            | (Built, Tested)
            | (Tested, Ready) => true,
            (_, Failed) => self != Failed,
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_the_happy_path() {
        let path = [
            Stage::Draft,
            Stage::Validated,
            Stage::Planned,
            Stage::Building,
            Stage::Built,
            Stage::Tested,
            Stage::Ready,
        ];
        for pair in path.windows(2) {
            assert!(
                pair[0].can_advance_to(pair[1]),
                "{} -> {} should be allowed",
                pair[0].as_str(),
                pair[1].as_str()
            );
        }
    }

    #[test]
    fn rejects_skipping_stages() {
        assert!(!Stage::Draft.can_advance_to(Stage::Built));
        assert!(!Stage::Built.can_advance_to(Stage::Ready));
        assert!(!Stage::Planned.can_advance_to(Stage::Tested));
    }

    #[test]
    fn anything_can_fail_once_but_failure_is_terminal() {
        assert!(Stage::Draft.can_advance_to(Stage::Failed));
        assert!(Stage::Building.can_advance_to(Stage::Failed));
        assert!(!Stage::Failed.can_advance_to(Stage::Failed));
    }
}
