//! Shared helpers for the `sysemble-core` integration tests.

#![allow(dead_code)]

use std::path::{Path, PathBuf};

use sysemble_core::{load_spec, BuildSpec};

/// Path to a frozen example spec at the workspace root.
pub fn example_path(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("examples")
        .join(name)
}

/// Load an example spec, panicking with the parser error if it fails.
pub fn load_example(name: &str) -> BuildSpec {
    load_spec(&example_path(name))
        .unwrap_or_else(|error| panic!("failed to load example `{name}`: {error}"))
}

/// Write a temporary spec with a `.yaml` extension and return its path.
pub fn write_temp_spec(label: &str, contents: &str) -> PathBuf {
    write_temp_spec_with_extension(label, "yaml", contents)
}

/// Write a temporary spec with an explicit extension and return its path.
pub fn write_temp_spec_with_extension(label: &str, extension: &str, contents: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("sysemble-core-test-{}-{label}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    let path = dir.join(format!("spec.{extension}"));
    std::fs::write(&path, contents).expect("write temp spec");
    path
}

/// Remove the directory created by [`write_temp_spec`].
pub fn remove_temp_spec(path: &Path) {
    if let Some(dir) = path.parent() {
        let _ = std::fs::remove_dir_all(dir);
    }
}
