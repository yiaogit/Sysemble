//! Tauri command layer for the Sysemble desktop shell (P1-a).
//!
//! The IPC surface is deliberately tiny. Every command is a thin wrapper
//! around a plain function so the interesting behaviour can be unit-tested
//! without starting a WebView or a window.

use std::path::{Path, PathBuf};

use sysemble_core::{load_spec, resolve_plan, validate_spec, Diagnostic, Plan};

/// Resolve a path supplied by the UI.
///
/// Paths are relative to the directory the process was started from. Debug
/// builds additionally fall back to the repository root when a relative path
/// does not exist, because the desktop binary normally starts inside
/// `apps/desktop/src-tauri` while the example specs live at `<repo>/examples`.
/// Release builds only ever use the caller-supplied path.
fn resolve_path(raw: &str) -> PathBuf {
    let candidate = PathBuf::from(raw);
    if candidate.is_absolute() || candidate.exists() {
        return candidate;
    }

    #[cfg(debug_assertions)]
    {
        let repo_root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let from_repo = repo_root.join(&candidate);
        if from_repo.exists() {
            return from_repo;
        }
    }

    candidate
}

/// Read the raw spec text for the left-hand source pane.
pub fn read_spec_file(path: &str) -> Result<String, String> {
    let resolved = resolve_path(path);
    std::fs::read_to_string(&resolved)
        .map_err(|error| format!("cannot read spec `{path}`: {error}"))
}

/// Load and validate a spec, returning every diagnostic.
pub fn validate_spec_path(path: &str) -> Result<Vec<Diagnostic>, String> {
    let resolved = resolve_path(path);
    let spec =
        load_spec(&resolved).map_err(|error| format!("cannot validate `{path}`: {error}"))?;
    Ok(validate_spec(&spec))
}

/// Load a spec and resolve it into a build plan.
pub fn plan_spec_path(path: &str) -> Result<Plan, String> {
    let resolved = resolve_path(path);
    let spec = load_spec(&resolved).map_err(|error| format!("cannot plan `{path}`: {error}"))?;
    resolve_plan(&spec).map_err(|error| format!("cannot plan `{path}`: {error}"))
}

/// IPC: raw spec source.
#[tauri::command]
fn read_spec(path: String) -> Result<String, String> {
    read_spec_file(&path)
}

/// IPC: validation diagnostics.
#[tauri::command]
fn validate(path: String) -> Result<Vec<Diagnostic>, String> {
    validate_spec_path(&path)
}

/// IPC: resolved build plan.
#[tauri::command]
fn plan(path: String) -> Result<Plan, String> {
    plan_spec_path(&path)
}

/// Start the desktop application.
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![read_spec, validate, plan])
        .run(tauri::generate_context!())
        .expect("failed to run the Sysemble desktop window");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo_root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../..")
            .canonicalize()
            .expect("repository root should exist")
    }

    fn example(name: &str) -> String {
        repo_root()
            .join("examples")
            .join(name)
            .to_string_lossy()
            .into_owned()
    }

    #[test]
    fn debian_xfce_validates_without_errors() {
        let path = example("debian-xfce.yaml");
        let diagnostics = validate_spec_path(&path).expect("example spec should load");
        let errors: Vec<_> = diagnostics
            .iter()
            .filter(|diagnostic| diagnostic.is_error())
            .collect();
        assert!(
            errors.is_empty(),
            "example spec should produce no errors, got: {errors:#?}"
        );
    }

    #[test]
    fn debian_xfce_plans_a_non_empty_package_set() {
        let path = example("debian-xfce.yaml");
        let plan = plan_spec_path(&path).expect("example spec should plan");
        assert!(
            !plan.packages.is_empty(),
            "resolved plan should contain packages"
        );
        assert!(
            plan.estimates.image_mb > 0,
            "resolved plan should carry estimates"
        );
        assert!(
            !plan.modules.is_empty(),
            "resolved plan should list at least the base module"
        );
    }

    #[test]
    fn read_spec_returns_the_file_contents() {
        let path = example("minimal-debian.yaml");
        let text = read_spec_file(&path).expect("example spec should be readable");
        assert!(text.contains("apiVersion: sysemble/v1"));
        assert!(text.contains("minimal-debian"));
    }

    #[test]
    fn missing_paths_are_errors_for_every_command() {
        let path = example("no-such-spec.yaml");

        let results: [(&str, Result<(), String>); 3] = [
            ("read_spec", read_spec_file(&path).map(|_| ())),
            ("validate", validate_spec_path(&path).map(|_| ())),
            ("plan", plan_spec_path(&path).map(|_| ())),
        ];

        for (command, result) in results {
            match result {
                Ok(()) => panic!("`{command}` should fail for a missing path"),
                Err(error) => assert!(
                    error.contains(&path),
                    "`{command}` error should name the path, got: {error}"
                ),
            }
        }
    }
}
