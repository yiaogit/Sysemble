//! Real VM end-to-end test (P1-e4 W3/W5).
//!
//! **Ignored by default.** It boots the real Virtualization.framework VM from
//! the local signed helper and arm64 image, runs a full Debian rootfs build
//! twice in the same output directory, and verifies the exported artifacts.
//! Run it explicitly:
//!
//! ```text
//! cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml \
//!   -- --ignored --nocapture real_vm
//! ```
//!
//! The test needs:
//! - macOS arm64 with Virtualization.framework (`engine/vm/macos/build.sh`);
//! - the E3a image under `engine/vm/image/build/` (`engine/vm/image/build-image.sh`);
//! - the repository's `builders/debian/build.sh` and
//!   `engine/vm/guest/minimal-build.sh`.
//!
//! Output goes to `/tmp/sysemble-real-vm-<pid>` (never the repository `out/`).
//! It is removed on success; a failing run keeps it, including `build.log`,
//! `vm-serial.log`, `.sysemble-vm/log`, `artifact-vm.json`, and the tarball, for
//! inspection. Each run takes roughly two to four minutes.

#![cfg(target_os = "macos")]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use sysemble_desktop_lib::build::{BuildManager, BuildState, BuildStatus};
use sysemble_desktop_lib::engine;

/// Boot + mmdebstrap is minutes; leave room for a slow machine.
const BUILD_TIMEOUT: Duration = Duration::from_secs(1800);

fn spec_path() -> String {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join("examples/minimal-debian.yaml")
        .to_string_lossy()
        .into_owned()
}

fn wait_for_terminal(manager: &BuildManager, id: &str) -> BuildStatus {
    let started = Instant::now();
    loop {
        let status = manager.get_build(id).expect("build should be registered");
        if status.state != BuildState::Running {
            return status;
        }
        assert!(
            started.elapsed() < BUILD_TIMEOUT,
            "build `{id}` was still running after {BUILD_TIMEOUT:?}"
        );
        thread::sleep(Duration::from_millis(500));
    }
}

fn sha256_file(path: &Path) -> String {
    let output = Command::new("shasum")
        .args(["-a", "256"])
        .arg(path)
        .output()
        .unwrap_or_else(|error| panic!("cannot run shasum for {}: {error}", path.display()));
    assert!(
        output.status.success(),
        "shasum failed for {}: {}",
        path.display(),
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout
        .split_whitespace()
        .next()
        .map(str::to_string)
        .unwrap_or_else(|| panic!("shasum printed no digest for {}", path.display()))
}

fn read_json(path: &Path) -> serde_json::Value {
    let text = fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("{} is not valid JSON: {error}", path.display()))
}

/// Print the files a run left in `out` so `--nocapture` logs are evidence.
fn print_out_files(out: &Path, run: usize) {
    eprintln!("real_vm: run {run}: files in {}", out.display());
    let Ok(entries) = fs::read_dir(out) else {
        eprintln!("real_vm: run {run}: cannot list {}", out.display());
        return;
    };
    let mut names: Vec<(String, u64)> = entries
        .filter_map(Result::ok)
        .map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            let size = entry.metadata().map(|meta| meta.len()).unwrap_or(0);
            (name, size)
        })
        .collect();
    names.sort();
    for (name, size) in names {
        eprintln!("real_vm: run {run}:   {name} ({size} B)");
        if name == ".sysemble-vm" {
            if let Ok(work) = fs::read_dir(out.join(&name)) {
                let mut work_names: Vec<(String, u64)> = work
                    .filter_map(Result::ok)
                    .map(|entry| {
                        let name = entry.file_name().to_string_lossy().into_owned();
                        let size = entry.metadata().map(|meta| meta.len()).unwrap_or(0);
                        (name, size)
                    })
                    .collect();
                work_names.sort();
                for (work_name, work_size) in work_names {
                    eprintln!("real_vm: run {run}:     .sysemble-vm/{work_name} ({work_size} B)");
                }
            }
        }
    }
}

/// Assert one VM run produced every frozen artifact with matching hashes.
fn assert_run_artifacts(out: &Path, run: usize) {
    let tar = out.join("rootfs.tar.gz");
    assert!(tar.is_file(), "run {run}: missing {}", tar.display());
    let tar_size = fs::metadata(&tar)
        .unwrap_or_else(|error| panic!("run {run}: cannot stat {}: {error}", tar.display()))
        .len();
    assert!(tar_size > 0, "run {run}: rootfs.tar.gz is empty");

    let artifact = read_json(&out.join("artifact-vm.json"));
    assert_eq!(artifact["schema"], 1, "run {run}: artifact schema");
    assert_eq!(artifact["name"], "sysemble-vm-build", "run {run}: artifact name");
    assert_eq!(artifact["arch"], "arm64", "run {run}: artifact arch");
    assert_eq!(
        artifact["builder_dry_run"], "pass",
        "run {run}: the guest builder dry-run must pass"
    );
    assert!(
        artifact["rootfs_files"].as_u64().unwrap_or(0) > 0,
        "run {run}: rootfs_files must be positive"
    );
    assert_eq!(
        artifact["tar_size_bytes"].as_u64(),
        Some(tar_size),
        "run {run}: artifact tar_size_bytes must match the file"
    );

    let artifact_sha = artifact["tar_sha256"]
        .as_str()
        .unwrap_or_else(|| panic!("run {run}: artifact has no tar_sha256"))
        .to_string();
    assert_eq!(artifact_sha.len(), 64, "run {run}: tar_sha256 length");

    let computed = sha256_file(&tar);
    assert_eq!(
        artifact_sha, computed,
        "run {run}: artifact sha256 must match the recomputed tarball hash"
    );

    // The guest also writes rootfs.tar.gz.sha256; all three digests must agree.
    let sha_file = out.join("rootfs.tar.gz.sha256");
    assert!(sha_file.is_file(), "run {run}: missing {}", sha_file.display());
    let listed = fs::read_to_string(&sha_file)
        .unwrap_or_else(|error| panic!("run {run}: cannot read {}: {error}", sha_file.display()))
        .split_whitespace()
        .next()
        .map(str::to_string)
        .unwrap_or_default();
    assert_eq!(listed, computed, "run {run}: rootfs.tar.gz.sha256 disagrees");

    let build_log = fs::read_to_string(out.join("build.log")).expect("build.log should be readable");
    assert!(
        !build_log.trim().is_empty(),
        "run {run}: build.log must not be empty"
    );
    assert!(
        build_log.contains("\"rc\"") && build_log.contains("\"elapsed_seconds\""),
        "run {run}: the helper JSON result should be in build.log:\n{}",
        tail(&build_log, 20)
    );

    let guest_log = out.join(".sysemble-vm").join("log");
    assert!(guest_log.is_file(), "run {run}: missing guest log");
    let guest_text = fs::read_to_string(&guest_log).expect("guest log should be readable");
    assert!(
        guest_text.contains("VM-BUILD: complete"),
        "run {run}: guest build did not complete:\n{}",
        tail(&guest_text, 20)
    );
    assert!(
        out.join(".sysemble-vm").join("done").is_file(),
        "run {run}: missing .sysemble-vm/done"
    );

    eprintln!(
        "real_vm: run {run}: rootfs.tar.gz size={tar_size} sha256={computed} (artifact and .sha256 agree)"
    );
    eprintln!(
        "real_vm: run {run}: artifact-vm.json={}",
        serde_json::to_string(&artifact).expect("artifact should serialize")
    );
    eprintln!(
        "real_vm: run {run}: build.log tail:\n{}",
        tail(&build_log, 30)
    );
    eprintln!(
        "real_vm: run {run}: guest log tail:\n{}",
        tail(&guest_text, 10)
    );
    print_out_files(out, run);
}

fn tail(text: &str, lines: usize) -> String {
    let all: Vec<&str> = text.lines().collect();
    all[all.len().saturating_sub(lines)..].join("\n")
}

/// Remove the temporary output on success; keep it when the test fails.
struct OutputDir {
    path: PathBuf,
}

impl Drop for OutputDir {
    fn drop(&mut self) {
        if std::thread::panicking() {
            eprintln!(
                "real_vm: keeping {} for inspection (build.log, vm-serial.log, .sysemble-vm/log)",
                self.path.display()
            );
        } else {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

#[test]
#[ignore = "boots a real Virtualization.framework VM; run explicitly with `--ignored real_vm`"]
fn real_vm_build_manager_executes_twice() {
    assert!(
        std::env::var_os("SYMBLE_BUILDER").is_none(),
        "the real VM E2E must not run with SYMBLE_BUILDER set"
    );

    let info = engine::engine_info().expect("engine_info never returns Err");
    eprintln!(
        "real_vm: EngineInfo={}",
        serde_json::to_string(&info).expect("engine info should serialize")
    );
    assert_eq!(info.kind, "vm", "expected the native vm engine");
    assert!(info.available, "expected an available vm engine");
    assert_eq!(info.runtime, None);
    assert!(
        info.image
            .as_deref()
            .is_some_and(|image| image.starts_with("sysemble-vm:")),
        "unexpected image reference: {:?}",
        info.image
    );
    assert_eq!(info.image_present, Some(true));

    let out = PathBuf::from("/tmp").join(format!("sysemble-real-vm-{}", std::process::id()));
    let _ = fs::remove_dir_all(&out);
    fs::create_dir_all(&out).expect("temporary output should be creatable");
    let output = OutputDir { path: out.clone() };

    let manager = BuildManager::new();
    let spec = spec_path();
    let mut runs = Vec::new();

    for run in 1..=2 {
        let began = Instant::now();
        let started = manager
            .start_build(&spec, &output.path.to_string_lossy(), "execute")
            .unwrap_or_else(|error| panic!("run {run}: execute must start: {error}"));

        let status = wait_for_terminal(&manager, &started.id);
        let elapsed = began.elapsed();
        eprintln!(
            "real_vm: run {run}: state={:?} rc={:?} elapsed={:.1}s out={}",
            status.state,
            status.exit_code,
            elapsed.as_secs_f64(),
            output.path.display()
        );

        assert_eq!(
            status.state,
            BuildState::Exited,
            "run {run}: build did not exit cleanly (see build.log): {:?}",
            status
        );
        assert_eq!(status.exit_code, Some(0), "run {run}: guest rc");
        assert!(status.finished_at.is_some());

        assert!(Path::new(&started.plan_path).is_file());
        assert_run_artifacts(&output.path, run);
        runs.push(elapsed);
    }

    eprintln!(
        "real_vm: both runs passed; elapsed = {:.1}s + {:.1}s; artifacts under {} were removed",
        runs[0].as_secs_f64(),
        runs[1].as_secs_f64(),
        output.path.display()
    );
}
