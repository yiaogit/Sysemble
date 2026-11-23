//! Black-box tests for the `sysemble` binary.
//!
//! These spawn the real executable so process exit codes and the split between
//! stdout and stderr are covered, not just the in-process logic.

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU32, Ordering};

const BIN: &str = env!("CARGO_BIN_EXE_sysemble");

/// Smallest spec that parses and validates without findings.
const MINIMAL_SPEC: &str = "\
apiVersion: sysemble/v1
meta:
  name: cli-test
target:
  base:
    kind: debian
    release: trixie
  arch: x86_64
  output: [qcow2]
system:
  hostname: cli-test
";

/// Same spec without a pinned release: one warning, no errors.
const SPEC_WITHOUT_RELEASE: &str = "\
apiVersion: sysemble/v1
meta:
  name: cli-test
target:
  base:
    kind: debian
  arch: x86_64
  output: [qcow2]
system:
  hostname: cli-test
";

fn repo_path(relative: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(relative)
}

/// A unique path under the system temporary directory.
fn temp_path(label: &str) -> PathBuf {
    static NEXT_ID: AtomicU32 = AtomicU32::new(0);
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("sysemble-cli-{}-{id}-{label}", std::process::id()))
}

/// A temporary spec that removes itself when the test ends, panic or not.
struct TempSpec {
    path: PathBuf,
}

impl TempSpec {
    fn new(label: &str, contents: &str) -> Self {
        let path = temp_path(&format!("{label}.yaml"));
        std::fs::write(&path, contents).expect("write temporary spec");
        Self { path }
    }

    fn as_str(&self) -> &str {
        self.path.to_str().expect("temporary path must be UTF-8")
    }
}

impl Drop for TempSpec {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn run(args: &[&str]) -> Output {
    Command::new(BIN)
        .args(args)
        .output()
        .unwrap_or_else(|error| panic!("failed to run {BIN}: {error}"))
}

fn exit_code(output: &Output) -> i32 {
    output
        .status
        .code()
        .expect("sysemble was terminated by a signal")
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn path_str(path: &Path) -> &str {
    path.to_str().expect("test path must be UTF-8")
}

#[test]
fn examples_validate_without_errors() {
    for example in [
        "examples/debian-kde-dev.yaml",
        "examples/minimal-alpine.yaml",
    ] {
        let path = repo_path(example);
        let output = run(&["validate", path_str(&path)]);
        assert_eq!(
            exit_code(&output),
            0,
            "`{example}` should validate cleanly; stderr:\n{}",
            stderr(&output)
        );
        assert!(
            !stderr(&output).contains("error["),
            "`{example}` reported errors:\n{}",
            stderr(&output)
        );
    }
}

#[test]
fn unknown_field_is_rejected() {
    let spec = TempSpec::new("unknown-field", &format!("{MINIMAL_SPEC}bogus: 1\n"));
    let output = run(&["validate", spec.as_str()]);

    assert_eq!(exit_code(&output), 1, "stderr:\n{}", stderr(&output));
    assert!(
        stderr(&output).contains("bogus"),
        "stderr should name the unknown field:\n{}",
        stderr(&output)
    );
}

#[test]
fn plan_debian_kde_dev_contains_expected_packages() {
    let path = repo_path("examples/debian-kde-dev.yaml");
    let output = run(&["plan", path_str(&path)]);

    assert_eq!(exit_code(&output), 0, "stderr:\n{}", stderr(&output));

    let plan: serde_json::Value =
        serde_json::from_str(&stdout(&output)).expect("stdout must contain only the plan JSON");
    assert_eq!(plan["apiVersion"], "sysemble/plan/v1");
    assert_eq!(plan["spec"], "debian-kde-dev");

    let packages: Vec<&str> = plan["packages"]
        .as_array()
        .expect("plan.packages must be an array")
        .iter()
        .filter_map(serde_json::Value::as_str)
        .collect();
    for expected in ["plasma-desktop", "sddm", "firefox-esr"] {
        assert!(
            packages.contains(&expected),
            "plan is missing `{expected}`; got {packages:?}"
        );
    }

    assert!(
        stderr(&output).starts_with("plan: "),
        "successful plan should print a summary to stderr, got:\n{}",
        stderr(&output)
    );
}

#[test]
fn plan_rejects_unsupported_base() {
    let path = repo_path("examples/minimal-alpine.yaml");
    let output = run(&["plan", path_str(&path)]);

    assert_eq!(exit_code(&output), 1, "stderr:\n{}", stderr(&output));
    assert!(
        stdout(&output).is_empty(),
        "stdout must stay empty when planning fails, got:\n{}",
        stdout(&output)
    );

    let message = stderr(&output);
    assert!(message.contains("alpine"), "stderr:\n{message}");
    assert!(message.contains("not supported"), "stderr:\n{message}");
}

#[test]
fn missing_file_exits_2_for_both_commands() {
    let path = temp_path("missing.yaml");
    let _ = std::fs::remove_file(&path);

    for command in ["validate", "plan"] {
        let output = run(&[command, path_str(&path)]);
        assert_eq!(
            exit_code(&output),
            2,
            "`{command}` on a missing file should exit 2; stderr:\n{}",
            stderr(&output)
        );
        assert!(
            stderr(&output).contains("missing.yaml"),
            "`{command}` error should name the path:\n{}",
            stderr(&output)
        );
    }
}

#[test]
fn unknown_command_exits_2() {
    let output = run(&["frobnicate"]);
    assert_eq!(exit_code(&output), 2);
    assert!(
        stderr(&output).contains("unknown command"),
        "stderr:\n{}",
        stderr(&output)
    );
}

#[test]
fn usage_errors_exit_2() {
    let cases: [&[&str]; 4] = [
        &["validate"],
        &["plan"],
        &["validate", "a.yaml", "b.yaml"],
        &["validate", "--bogus", "a.yaml"],
    ];
    for args in cases {
        let output = run(args);
        assert_eq!(
            exit_code(&output),
            2,
            "args {args:?} should be a usage error; stderr:\n{}",
            stderr(&output)
        );
    }
}

#[test]
fn validate_json_emits_a_diagnostics_array() {
    let spec = TempSpec::new("warning", SPEC_WITHOUT_RELEASE);
    let output = run(&["validate", spec.as_str(), "--json"]);

    assert_eq!(exit_code(&output), 0, "stderr:\n{}", stderr(&output));
    let diagnostics: serde_json::Value =
        serde_json::from_str(&stdout(&output)).expect("stdout must be a JSON array");
    let diagnostics = diagnostics.as_array().expect("stdout must be a JSON array");
    assert!(
        diagnostics.iter().any(|diagnostic| {
            diagnostic["severity"] == "warning"
                && diagnostic["code"] == "spec.target.base.release.missing"
        }),
        "missing release warning; got {diagnostics:?}"
    );
}

#[test]
fn validate_json_without_findings_is_an_empty_array() {
    let spec = TempSpec::new("clean", MINIMAL_SPEC);
    let output = run(&["validate", spec.as_str(), "--json"]);

    assert_eq!(exit_code(&output), 0, "stderr:\n{}", stderr(&output));
    assert_eq!(stdout(&output).trim(), "[]");
}

#[test]
fn validate_json_parse_errors_keep_the_diagnostic_shape() {
    let spec = TempSpec::new("bad-json", &format!("{MINIMAL_SPEC}bogus: 1\n"));
    let output = run(&["validate", spec.as_str(), "--json"]);

    assert_eq!(exit_code(&output), 1, "stderr:\n{}", stderr(&output));
    let diagnostics: serde_json::Value =
        serde_json::from_str(&stdout(&output)).expect("stdout must be a JSON array");
    let first = &diagnostics.as_array().expect("stdout must be a JSON array")[0];
    assert_eq!(first["severity"], "error");
    assert_eq!(first["code"], "spec.parse");
    assert!(
        first["message"]
            .as_str()
            .is_some_and(|message| message.contains("bogus")),
        "parse diagnostic should mention `bogus`: {first:?}"
    );
}

#[test]
fn plan_json_flag_matches_the_default_output() {
    let path = repo_path("examples/debian-kde-dev.yaml");
    let plain = run(&["plan", path_str(&path)]);
    let flagged = run(&["plan", path_str(&path), "--json"]);

    assert_eq!(exit_code(&plain), 0, "stderr:\n{}", stderr(&plain));
    assert_eq!(exit_code(&flagged), 0, "stderr:\n{}", stderr(&flagged));
    assert_eq!(stdout(&plain), stdout(&flagged));
}

#[test]
fn help_version_and_stages_succeed() {
    let help = run(&["--help"]);
    assert_eq!(exit_code(&help), 0);
    let help_text = stdout(&help);
    for command in ["validate", "plan", "version", "stages"] {
        assert!(
            help_text.contains(command),
            "help should mention `{command}`:\n{help_text}"
        );
    }

    let validate_help = run(&["validate", "--help"]);
    assert_eq!(exit_code(&validate_help), 0);
    assert!(stdout(&validate_help).contains("sysemble validate"));

    let version = run(&["version"]);
    assert_eq!(exit_code(&version), 0);
    assert!(
        stdout(&version).contains("sysemble/v1"),
        "version output:\n{}",
        stdout(&version)
    );

    let stages = run(&["stages"]);
    assert_eq!(exit_code(&stages), 0);
    let stages_text = stdout(&stages);
    assert!(stages_text.contains("draft"), "stages:\n{stages_text}");
    assert!(stages_text.contains("ready"), "stages:\n{stages_text}");
}
