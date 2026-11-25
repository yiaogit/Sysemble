//! Live engine probe wiring (P1-e2b).
//!
//! This lives in its own test binary because it changes process environment
//! variables: `SYSEMBLE_ENGINE_RUNTIME` points at a fake runtime, so the probe
//! runs end to end without a docker daemon or network access.

#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use sysemble_desktop_lib::engine::{
    self, ENGINE_IMAGE_ENV, ENGINE_RUNTIME_ENV, VM_HELPER_ENV, VM_IMAGE_DIR_ENV,
};

fn temp_dir(tag: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("sysemble-engine-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&path);
    fs::create_dir_all(&path).expect("temp directory should be creatable");
    path
}

fn write_script(path: &Path, body: &str) {
    fs::write(path, body).expect("fake runtime should be writable");
    let permissions = fs::Permissions::from_mode(0o755);
    fs::set_permissions(path, permissions).expect("fake runtime should be executable");
}

/// A Linux root host with the local toolchain answers `local` before the
/// container probe; these assertions are container-specific and skip there.
#[cfg(target_os = "linux")]
fn local_engine_wins() -> bool {
    engine::engine_info().is_ok_and(|info| info.kind == "local")
}

#[cfg(not(target_os = "linux"))]
fn local_engine_wins() -> bool {
    false
}

/// Remove the overrides even when an assertion fails.
struct EnvGuard;

impl Drop for EnvGuard {
    fn drop(&mut self) {
        std::env::remove_var(ENGINE_IMAGE_ENV);
        std::env::remove_var(ENGINE_RUNTIME_ENV);
        std::env::remove_var(VM_HELPER_ENV);
        std::env::remove_var(VM_IMAGE_DIR_ENV);
    }
}

#[test]
fn environment_overrides_drive_the_engine_probe() {
    let _guard = EnvGuard;
    std::env::remove_var(ENGINE_IMAGE_ENV);
    std::env::remove_var(ENGINE_RUNTIME_ENV);
    std::env::remove_var(VM_IMAGE_DIR_ENV);
    if local_engine_wins() {
        eprintln!("skipping: the local Linux engine wins on this host");
        return;
    }

    let temp = temp_dir("probe");
    // This test asserts the container probe order. Point the VM helper at a
    // missing path so a developer Mac with a signed helper and a built image
    // still probes the container runtime instead of answering `vm`.
    std::env::set_var(VM_HELPER_ENV, temp.join("missing-sysemble-vm"));
    let runtime = temp.join("docker");

    // 1. A reachable daemon with the image present.
    write_script(
        &runtime,
        r#"#!/bin/sh
case "$1" in
  version) printf '9.9.9\n' ;;
  image) exit 0 ;;
esac
"#,
    );
    std::env::set_var(ENGINE_RUNTIME_ENV, &runtime);
    std::env::set_var(ENGINE_IMAGE_ENV, "sysemble-engine:test");

    let info = engine::engine_info().expect("the probe never returns Err");
    assert_eq!(info.kind, "container");
    assert!(info.available);
    assert_eq!(info.runtime.as_deref(), Some("docker"));
    assert_eq!(info.image.as_deref(), Some("sysemble-engine:test"));
    assert_eq!(info.image_present, Some(true));
    assert!(
        info.reason.contains("9.9.9"),
        "reason should carry the runtime version: {}",
        info.reason
    );
    // W1/W6: the missing VM helper degrades to the container probe and the
    // reason keeps a readable note about it (macOS only; other hosts skip the
    // VM probe entirely).
    #[cfg(target_os = "macos")]
    assert!(
        info.reason.contains("vm: no sysemble-vm helper found"),
        "reason should keep the VM degradation note: {}",
        info.reason
    );

    // 2. A reachable daemon without the image: unavailable, with the build hint.
    write_script(
        &runtime,
        r#"#!/bin/sh
case "$1" in
  version) printf '9.9.9\n' ;;
  image) printf 'No such image\n' >&2; exit 1 ;;
esac
"#,
    );

    let info = engine::engine_info().expect("the probe never returns Err");
    assert_eq!(info.kind, "container");
    assert!(!info.available);
    assert_eq!(info.image_present, Some(false));
    assert!(
        info.reason.contains("engine/image/build-image.sh"),
        "reason should point at the image build script: {}",
        info.reason
    );

    // 3. A hung runtime is killed at the 4s probe timeout.
    write_script(&runtime, "#!/bin/sh\nexec sleep 30\n");

    let began = Instant::now();
    let info = engine::engine_info().expect("the probe never returns Err");
    let elapsed = began.elapsed();

    assert!(
        elapsed >= Duration::from_secs(3),
        "the 4s probe timeout did not elapse: {elapsed:?}"
    );
    assert!(
        elapsed < Duration::from_secs(12),
        "the probe waited far longer than its timeout: {elapsed:?}"
    );
    assert_eq!(info.kind, "none");
    assert!(!info.available);
    assert!(
        info.reason.contains("timed out after 4s"),
        "reason should mention the timeout: {}",
        info.reason
    );
    assert!(
        info.reason.contains("start Docker Desktop"),
        "reason should tell the user how to start the daemon: {}",
        info.reason
    );

    // 4. A runtime executable that does not exist is a readable `none`.
    std::env::set_var(ENGINE_RUNTIME_ENV, temp.join("missing-docker"));

    let info = engine::engine_info().expect("the probe never returns Err");
    assert_eq!(info.kind, "none");
    assert!(!info.available);
    assert!(
        info.reason.contains("docker: cannot run"),
        "reason should carry the runtime error: {}",
        info.reason
    );
    assert!(
        info.reason.contains("start Docker Desktop"),
        "reason should keep the daemon hint: {}",
        info.reason
    );
    #[cfg(target_os = "macos")]
    assert!(
        info.reason.contains("vm: no sysemble-vm helper found"),
        "the all-unavailable reason should keep the VM note: {}",
        info.reason
    );

    let _ = fs::remove_dir_all(&temp);
}
