//! Tests for reading specs from disk.

mod common;

use sysemble_core::{load_spec, SpecError, API_VERSION};

const MINIMAL_SPEC: &str = r#"
apiVersion: sysemble/v1
meta:
  name: temp-spec
target:
  base:
    kind: debian
    release: trixie
  arch: x86_64
  output: [qcow2]
system:
  hostname: temp
"#;

#[test]
fn loads_both_examples() {
    let debian = common::load_example("debian-kde-dev.yaml");
    assert_eq!(debian.api_version, API_VERSION);
    assert_eq!(debian.meta.name, "debian-kde-dev");
    assert_eq!(debian.target.base.kind.as_str(), "debian");
    assert_eq!(debian.target.base.release.as_deref(), Some("trixie"));
    assert_eq!(
        debian.desktop.as_ref().unwrap().session.unwrap().as_str(),
        "plasma"
    );

    let alpine = common::load_example("minimal-alpine.yaml");
    assert_eq!(alpine.api_version, API_VERSION);
    assert_eq!(alpine.meta.name, "alpine-edge-node");
    assert_eq!(alpine.target.base.kind.as_str(), "alpine");
    assert!(alpine.desktop.is_none());
    assert!(alpine.virtualization.is_none());
}

#[test]
fn rejects_unknown_fields() {
    let contents = format!("{MINIMAL_SPEC}\nbogus: 1\n");
    let path = common::write_temp_spec("unknown-field", &contents);

    let error = load_spec(&path).expect_err("a spec with an unknown key must not load");
    assert!(matches!(error, SpecError::Parse { .. }));
    let message = error.to_string();
    assert!(
        message.contains("bogus"),
        "error should name the unknown field: {message}"
    );
    assert!(
        message.contains("spec.yaml"),
        "error should name the file: {message}"
    );

    common::remove_temp_spec(&path);
}

#[test]
fn rejects_missing_required_sections() {
    let contents = "apiVersion: sysemble/v1\nmeta:\n  name: no-system\n";
    let path = common::write_temp_spec("missing-section", contents);

    let error = load_spec(&path).expect_err("a spec without target/system must not load");
    let message = error.to_string();
    assert!(
        message.contains("target") || message.contains("system"),
        "error should name the missing section: {message}"
    );

    common::remove_temp_spec(&path);
}

#[test]
fn reports_yaml_location_and_path() {
    let path =
        common::write_temp_spec("syntax-error", "apiVersion: sysemble/v1\nmeta: [unclosed\n");

    let error = load_spec(&path).expect_err("broken YAML must not load");
    let message = error.to_string();
    assert!(
        message.contains("spec.yaml"),
        "error should name the file: {message}"
    );
    assert!(
        message.contains("line"),
        "serde_yaml location should be preserved: {message}"
    );

    common::remove_temp_spec(&path);
}

#[test]
fn loads_json_specs_through_the_yaml_parser() {
    let contents = r#"{
        "apiVersion": "sysemble/v1",
        "meta": { "name": "json-spec" },
        "target": {
            "base": { "kind": "ubuntu", "release": "noble" },
            "arch": "x86_64",
            "output": ["qcow2"]
        },
        "system": { "hostname": "json-box" }
    }"#;
    let path = common::write_temp_spec_with_extension("json-spec", "json", contents);

    let spec = load_spec(&path).expect("JSON should load because it is a YAML subset");
    assert_eq!(spec.meta.name, "json-spec");
    assert_eq!(spec.target.base.kind.as_str(), "ubuntu");

    common::remove_temp_spec(&path);
}

#[test]
fn loads_specs_regardless_of_file_extension() {
    let path = common::write_temp_spec_with_extension("txt-spec", "txt", MINIMAL_SPEC);

    let spec = load_spec(&path).expect("YAML content should load even with a .txt suffix");
    assert_eq!(spec.meta.name, "temp-spec");

    common::remove_temp_spec(&path);
}

#[test]
fn reports_missing_files_with_the_path() {
    let path = common::example_path("does-not-exist.yaml");

    let error = load_spec(&path).expect_err("a missing file must fail");
    assert!(matches!(error, SpecError::Read { .. }));
    assert!(error.to_string().contains("does-not-exist.yaml"));
}

#[test]
fn unknown_api_version_still_parses_so_validation_can_explain_it() {
    let contents = MINIMAL_SPEC.replace("sysemble/v1", "sysemble/v2");
    let path = common::write_temp_spec("future-version", &contents);

    let spec = load_spec(&path).expect("version checking belongs to validate_spec");
    assert_eq!(spec.api_version, "sysemble/v2");

    common::remove_temp_spec(&path);
}
