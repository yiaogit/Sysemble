//! Engine gating with the P1-b builder hook (P1-e2b).
//!
//! `SYMBLE_BUILDER` is the P1-b test/builder-replacement hook. This binary
//! verifies that execute builds are gated when no engine answers and that the
//! hook still bypasses the gate, keeping the existing cancellation test
//! engine-free. It owns its process, so mutating the environment is safe.

use std::fs;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use sysemble_desktop_lib::build::{BuildManager, BuildState};
#[cfg(target_os = "linux")]
use sysemble_desktop_lib::engine;
use sysemble_desktop_lib::engine::ENGINE_RUNTIME_ENV;

/// A Linux root host with the local toolchain would satisfy the gate, so the
/// container-specific assertions below skip there.
#[cfg(target_os = "linux")]
fn local_engine_wins() -> bool {
    engine::engine_info().is_ok_and(|info| info.kind == "local")
}

#[cfg(not(target_os = "linux"))]
fn local_engine_wins() -> bool {
    false
}

fn temp_dir() -> PathBuf {
    let path = std::env::temp_dir().join(format!("sysemble-engine-gate-{}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).expect("temp directory should be creatable");
    path
}

#[test]
fn builder_override_bypasses_the_engine_gate() {
    let dir = temp_dir();
    let builder = dir.join("fake-builder.sh");
    let out = dir.join("out");
    let gated_out = dir.join("gated-out");

    fs::write(
        &builder,
        "#!/usr/bin/env bash\nprintf 'fake execute builder ran\\n'\n",
    )
    .expect("fake builder should be writable");

    std::env::remove_var("SYMBLE_BUILDER");
    std::env::remove_var(ENGINE_RUNTIME_ENV);
    if local_engine_wins() {
        eprintln!("skipping: the local Linux engine wins on this host");
        return;
    }

    // Make the probe fail deterministically without touching real docker.
    std::env::set_var(ENGINE_RUNTIME_ENV, dir.join("missing-runtime"));

    let manager = BuildManager::new();
    let spec = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join("examples/minimal-debian.yaml");
    let spec = spec.to_string_lossy().into_owned();

    // 1. No engine and no hook: execute is gated with a readable error.
    let error = manager
        .start_build(&spec, &gated_out.to_string_lossy(), "execute")
        .expect_err("execute must be gated when no engine answers");
    assert!(
        error.contains("start Docker Desktop"),
        "error should carry the probe reason: {error}"
    );
    assert!(
        error.contains("dry-run"),
        "error should point at the still-available dry run: {error}"
    );
    assert!(
        !gated_out.join("build.log").exists(),
        "a gated build must not write output"
    );

    // 2. The P1-b hook substitutes the builder and skips the engine gate.
    std::env::set_var("SYMBLE_BUILDER", &builder);
    let started = manager
        .start_build(&spec, &out.to_string_lossy(), "execute")
        .expect("SYMBLE_BUILDER must bypass the engine gate");

    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let status = manager
            .get_build(&started.id)
            .expect("build should be registered");
        if status.state != BuildState::Running {
            assert_eq!(status.state, BuildState::Exited, "status: {status:?}");
            assert_eq!(status.exit_code, Some(0));
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the hooked builder did not finish in time"
        );
        thread::sleep(Duration::from_millis(50));
    }

    let log = manager
        .get_build_log(&started.id, None)
        .expect("build log should be readable");
    assert!(log.contains("fake execute builder ran"), "log:\n{log}");
    assert!(Path::new(&started.plan_path).is_file());

    std::env::remove_var("SYMBLE_BUILDER");
    std::env::remove_var(ENGINE_RUNTIME_ENV);
    let _ = fs::remove_dir_all(&dir);
}
