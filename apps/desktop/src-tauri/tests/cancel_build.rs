//! Cancellation integration test (P1-b).
//!
//! This lives in its own test binary on purpose: it sets `SYMBLE_BUILDER`, and
//! Cargo runs every integration-test binary in its own process, so neither the
//! unit tests in the crate nor other test binaries observe the override.

use std::fs;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant};

use sysemble_desktop_lib::build::{BuildManager, BuildState};

fn temp_dir() -> PathBuf {
    let path = std::env::temp_dir().join(format!("sysemble-cancel-{}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).expect("temp directory should be creatable");
    path
}

#[test]
fn cancel_build_kills_the_builder_and_marks_the_build_cancelled() {
    let dir = temp_dir();
    let builder = dir.join("fake-builder.sh");
    let out = dir.join("out");

    // A builder that outlives the test unless cancellation works.
    fs::write(
        &builder,
        "#!/usr/bin/env bash\nprintf 'fake builder started\\n'\nsleep 30\n",
    )
    .expect("fake builder should be writable");

    // Safe here: this binary contains exactly one test, so nothing else in
    // this process reads the environment concurrently.
    std::env::set_var("SYMBLE_BUILDER", &builder);

    let manager = BuildManager::new();
    let spec = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join("examples/minimal-debian.yaml");

    let started = manager
        .start_build(&spec.to_string_lossy(), &out.to_string_lossy(), "dry-run")
        .expect("fake build should start");

    // Let the supervisor claim the child and the fake builder print its first
    // line before cancelling.
    thread::sleep(Duration::from_millis(300));
    assert_eq!(
        manager
            .get_build(&started.id)
            .expect("build should be registered")
            .state,
        BuildState::Running
    );

    manager
        .cancel_build(&started.id)
        .expect("running build should be cancellable");

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let status = manager
            .get_build(&started.id)
            .expect("build should still be registered");
        if status.state == BuildState::Cancelled {
            assert_eq!(status.exit_code, None);
            assert!(status.finished_at.is_some());
            break;
        }
        assert!(
            Instant::now() < deadline,
            "build did not reach cancelled, last status: {status:?}"
        );
        thread::sleep(Duration::from_millis(50));
    }

    // The supervisor reaps the killed child after cancellation; it must not
    // rewrite the terminal state to failed.
    thread::sleep(Duration::from_millis(200));
    assert_eq!(
        manager
            .get_build(&started.id)
            .expect("build should still be registered")
            .state,
        BuildState::Cancelled
    );

    assert!(Path::new(&started.log_path).is_file());
    let log = manager
        .get_build_log(&started.id, None)
        .expect("build log should be readable");
    assert!(
        !log.contains("Dry run complete"),
        "cancelled fake builder should not have completed: {log}"
    );

    std::env::remove_var("SYMBLE_BUILDER");
    let _ = fs::remove_dir_all(&dir);
}
