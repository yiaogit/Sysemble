//! Error types for loading specs and resolving plans.

use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::model::BaseKind;
use crate::validate::Diagnostic;

/// Failure while reading or deserializing a `buildspec.yaml`.
///
/// The spec's filesystem path is part of every message. For YAML syntax errors
/// the [`serde_yaml::Error`] source keeps the line/column location intact.
#[derive(Debug, Error)]
pub enum SpecError {
    #[error("cannot read spec `{path}`: {source}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("cannot parse spec `{path}`: {source}")]
    Parse {
        path: PathBuf,
        #[source]
        source: serde_yaml::Error,
    },
}

impl SpecError {
    /// The spec file this error refers to.
    pub fn path(&self) -> &Path {
        match self {
            SpecError::Read { path, .. } | SpecError::Parse { path, .. } => path,
        }
    }
}

/// Failure while turning a validated spec into a plan.
#[derive(Debug, Error)]
pub enum PlanError {
    /// The spec is structurally readable but has validation errors. The
    /// diagnostics are carried along so a CLI can print them without running
    /// [`crate::validate_spec`] a second time.
    #[error(
        "spec is invalid: {} validation error(s); run `sysemble validate` for details",
        .errors.len()
    )]
    InvalidSpec { errors: Vec<Diagnostic> },

    /// The base distribution is valid per the schema but outside the P0
    /// planner's supported set.
    #[error("base `{kind}` is not supported by the P0 planner (supported: debian, ubuntu)")]
    UnsupportedBase { kind: BaseKind },
}

impl PlanError {
    /// Validation errors that prevented planning, if any.
    pub fn validation_errors(&self) -> &[Diagnostic] {
        match self {
            PlanError::InvalidSpec { errors } => errors,
            PlanError::UnsupportedBase { .. } => &[],
        }
    }
}
