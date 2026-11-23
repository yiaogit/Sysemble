//! Core types for Sysemble.
//!
//! This crate owns the parts of the system that must be reviewable without a
//! build sandbox:
//!
//! - the [`BuildSpec`] model, mirroring `spec/buildspec.schema.json`;
//! - [`load_spec`] for reading YAML/JSON specs;
//! - [`validate_spec`], which turns a spec into stable, path-addressed
//!   [`Diagnostic`]s;
//! - [`resolve_plan`], which turns a valid spec into a deterministic [`Plan`];
//! - the [`Stage`] state machine the engine will enforce.
//!
//! The build engine itself is not implemented yet. Plans are data: nothing in
//! this crate writes to the host, runs a builder, or performs network IO.

mod error;
mod loader;
mod model;
mod packages;
mod plan;
mod validate;

pub use error::{PlanError, SpecError};
pub use loader::load_spec;
pub use model::*;
pub use plan::{
    resolve_plan, Estimates, Plan, PlanBase, PlanModule, PlanTarget, PlanWarning, MODULE_VERSION,
    PLAN_API_VERSION,
};
pub use validate::{codes, validate_spec, Diagnostic, Severity};

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
