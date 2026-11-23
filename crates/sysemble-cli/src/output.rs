//! Formatting shared by the commands.
//!
//! Everything here is pure: the functions return strings and never touch the
//! process streams, so the output formats can be unit-tested.

use sysemble_core::{Diagnostic, Plan, SpecError};

/// Human-readable diagnostic line: `error[code] /path: message`.
pub fn diagnostic_line(diagnostic: &Diagnostic) -> String {
    format!(
        "{}[{}] {}: {}",
        diagnostic.severity.as_str(),
        diagnostic.code,
        diagnostic.path,
        diagnostic.message
    )
}

/// One-line summary printed to stderr after a successful plan.
pub fn plan_summary(plan: &Plan) -> String {
    format!(
        "plan: {} packages, {} MB",
        plan.packages.len(),
        plan.estimates.image_mb
    )
}

/// Pretty JSON array of diagnostics, as emitted by `validate --json`.
pub fn diagnostics_json(diagnostics: &[Diagnostic]) -> Result<String, serde_json::Error> {
    serde_json::to_string_pretty(diagnostics)
}

/// Pretty JSON plan document, as emitted by `plan`.
pub fn plan_json(plan: &Plan) -> Result<String, serde_json::Error> {
    serde_json::to_string_pretty(plan)
}

/// Wrap a document-level load failure as a diagnostic.
///
/// [`sysemble_core`] returns [`SpecError`] rather than a [`Diagnostic`] when a
/// spec cannot be read or parsed, because there is no spec document to point
/// into. The CLI wraps it so `validate --json` always emits the same array
/// shape. `spec.read` and `spec.parse` are CLI-level codes; they are not part
/// of the core's stable validation code set.
pub fn spec_error_diagnostic(error: &SpecError) -> Diagnostic {
    let code = match error {
        SpecError::Read { .. } => "spec.read",
        SpecError::Parse { .. } => "spec.parse",
    };
    Diagnostic::error(code, "/", error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_diagnostics_one_per_line() {
        let error = Diagnostic::error("spec.meta.name.invalid", "/meta/name", "bad name");
        assert_eq!(
            diagnostic_line(&error),
            "error[spec.meta.name.invalid] /meta/name: bad name"
        );

        let warning = Diagnostic::warning(
            "spec.target.base.release.missing",
            "/target/base/release",
            "no release",
        );
        assert_eq!(
            diagnostic_line(&warning),
            "warning[spec.target.base.release.missing] /target/base/release: no release"
        );
    }

    #[test]
    fn diagnostic_json_is_a_pretty_array() {
        let json = diagnostics_json(&[Diagnostic::error("x", "/x", "boom")])
            .expect("diagnostics must serialize");
        let parsed: serde_json::Value = serde_json::from_str(&json).expect("must be valid JSON");
        assert!(parsed.is_array());
        assert_eq!(parsed[0]["severity"], "error");
        assert_eq!(parsed[0]["code"], "x");
        assert!(json.contains('\n'), "expected pretty output, got {json}");
    }

    #[test]
    fn wraps_spec_errors_as_diagnostics() {
        let error = SpecError::Read {
            path: std::path::PathBuf::from("missing.yaml"),
            source: std::io::Error::new(std::io::ErrorKind::NotFound, "missing"),
        };
        let diagnostic = spec_error_diagnostic(&error);
        assert_eq!(diagnostic.code, "spec.read");
        assert_eq!(diagnostic.path, "/");
        assert!(diagnostic.message.contains("missing.yaml"));
    }
}
