//! Engine availability probe for the desktop shell (P1-e2/P1-e4).
//!
//! P1-e's target shape is a Linux engine VM on macOS/Windows. P1-e2 shipped a
//! versioned Debian engine image executed by docker or podman with
//! `--platform linux/amd64`. P1-e4 adds the native macOS engine: the signed
//! `engine/vm/macos` helper boots the arm64 VM image with
//! Virtualization.framework. This module answers the question the Build button
//! needs: where can a real build run right now?
//!
//! The probe order is frozen by `docs/plan/P1-e4-workplan.md` §2.1:
//! `local` (Linux root + tools) → `vm` (macOS: signed helper + valid image) →
//! `container` (docker → podman) → `none`.
//! Every probe command is bounded by [`PROBE_TIMEOUT`]; a failing or hung probe
//! only degrades the result, it never makes [`engine_info`] return `Err`.
//!
//! The runtime commands are spawned directly (no shell, no extra dependency)
//! because the desktop crate deliberately keeps its dependency list small.

use std::env;
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::Value;

/// Engine image produced by `engine/image/build-image.sh` (P1-e2a).
pub const DEFAULT_ENGINE_IMAGE: &str = "sysemble-engine:0.1.0";

/// Environment override for the engine image reference.
pub const ENGINE_IMAGE_ENV: &str = "SYSEMBLE_ENGINE_IMAGE";

/// Environment override for the container runtime executable.
///
/// When set, the docker → podman probe order is skipped and only this
/// executable is probed. Intended for tests and advanced users.
pub const ENGINE_RUNTIME_ENV: &str = "SYSEMBLE_ENGINE_RUNTIME";

/// Environment override for the macOS VM helper executable (P1-e4).
///
/// When set, the repository and app-bundle helper candidates are skipped and
/// only this executable is probed, mirroring [`ENGINE_RUNTIME_ENV`]. Tests use
/// it to keep the host's real helper out of the container-probe tests.
pub const VM_HELPER_ENV: &str = "SYSEMBLE_VM_HELPER";

/// Environment override for the macOS VM image directory (P1-e4).
///
/// When set, the repository and Application Support candidates are skipped and
/// only this directory is validated.
pub const VM_IMAGE_DIR_ENV: &str = "SYSEMBLE_VM_IMAGE_DIR";

/// Image name used in the frozen `sysemble-vm:<version>` engine reference.
pub const VM_IMAGE_NAME: &str = "sysemble-vm";

/// Every probe command gets this long before it is killed and downgraded.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(4);

/// Container runtimes in the frozen probe order.
const CONTAINER_RUNTIMES: [&str; 2] = ["docker", "podman"];

/// Script that builds the missing engine image; quoted in the reason text.
const BUILD_IMAGE_SCRIPT: &str = "engine/image/build-image.sh";

/// Script that builds and signs the missing VM helper; quoted in reason texts.
pub(crate) const VM_HELPER_SCRIPT: &str = "engine/vm/macos/build.sh";

/// Script that builds the missing VM image; quoted in reason texts.
pub(crate) const VM_IMAGE_SCRIPT: &str = "engine/vm/image/build-image.sh";

/// Development-tree helper candidate, relative to the repository root.
const VM_HELPER_REPO_PATH: &str = "engine/vm/macos/.build/release/sysemble-vm";

/// Bundled helper candidate, relative to the desktop executable's directory.
/// E4c ships the helper as `.app/Contents/Helpers/sysemble-vm`.
const VM_HELPER_BUNDLE_PATH: &str = "../Helpers/sysemble-vm";

/// Development-tree image candidate, relative to the repository root.
const VM_IMAGE_REPO_PATH: &str = "engine/vm/image/build";

/// Installed image root, relative to `$HOME`. Every subdirectory is a
/// `<version>/` installation written by the E4c installer.
const VM_IMAGE_APP_DATA_PATH: &str = "Library/Application Support/Sysemble/engine-vm";

/// Frozen image manifest file name (P1-e3 workplan §2.1).
const VM_MANIFEST_FILE: &str = "sysemble-vm.json";

/// Frozen manifest schema version.
const VM_MANIFEST_SCHEMA: u64 = 1;

/// Frozen manifest `name` value.
const VM_MANIFEST_NAME: &str = "sysemble-vm";

/// The only guest architecture Virtualization.framework can boot on Apple
/// Silicon, and the only architecture the E3a image ships.
const VM_ARCH: &str = "arm64";

/// How often a spawned probe child is polled for completion.
const PROBE_POLL_INTERVAL: Duration = Duration::from_millis(25);

/// Tools the Debian builder invokes on a Linux host.
#[cfg(target_os = "linux")]
const LOCAL_ENGINE_TOOLS: [&str; 4] = ["mmdebstrap", "sgdisk", "mkfs.ext4", "qemu-img"];

/// Whether this host has a usable build engine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EngineInfo {
    /// `local`, `vm`, `container`, or `none`.
    pub kind: String,
    /// True only when a real (execute) build can run on this host.
    pub available: bool,
    /// `std::env::consts::OS`, for example `macos`, `linux`, or `windows`.
    pub platform: String,
    /// Human-readable explanation shown by the UI when `available` is false.
    pub reason: String,
    /// `docker` or `podman` for a container engine; `null` for `vm`, `local`,
    /// and `none`.
    pub runtime: Option<String>,
    /// `sysemble-vm:<version>` for the VM engine, the container image reference
    /// for a container engine; `null` otherwise.
    pub image: Option<String>,
    /// Whether the engine image is installed: the validated VM image for `vm`,
    /// the local container image for `container`; `null` when not determined.
    pub image_present: Option<bool>,
}

/// One probe result: the public [`EngineInfo`] plus the host resources the
/// build layer must invoke when the engine is a VM or a container runtime.
///
/// Those paths are kept out of [`EngineInfo`] because they have no business in
/// the UI wire format.
#[derive(Debug, Clone)]
pub(crate) struct EngineProbe {
    pub(crate) info: EngineInfo,
    pub(crate) runtime_path: Option<PathBuf>,
    /// Helper + image directory when `info.kind == "vm"` and it is available.
    pub(crate) vm: Option<VmHandle>,
}

/// A usable VM engine: the signed helper to run and the image to boot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct VmHandle {
    pub(crate) helper: PathBuf,
    pub(crate) image_dir: PathBuf,
}

/// Environment and host-path snapshot for one probe, so tests never mutate
/// process state and path discovery is injectable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct EngineEnv {
    pub(crate) image: String,
    pub(crate) runtime_override: Option<PathBuf>,
    /// `SYSEMBLE_VM_HELPER`; exclusive when set.
    pub(crate) vm_helper_override: Option<PathBuf>,
    /// `SYSEMBLE_VM_IMAGE_DIR`; exclusive when set.
    pub(crate) vm_image_override: Option<PathBuf>,
    /// Repository root used for the development-tree helper/image candidates.
    pub(crate) repo_root: Option<PathBuf>,
    /// Directory of the running executable, for `.app/Contents/Helpers`.
    pub(crate) exe_dir: Option<PathBuf>,
    /// `$HOME`, for `~/Library/Application Support/Sysemble/engine-vm`.
    pub(crate) home: Option<PathBuf>,
}

impl EngineEnv {
    fn from_process() -> Self {
        let image = env::var(ENGINE_IMAGE_ENV)
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| DEFAULT_ENGINE_IMAGE.to_string());
        let runtime_override = path_override(ENGINE_RUNTIME_ENV);
        let vm_helper_override = path_override(VM_HELPER_ENV);
        let vm_image_override = path_override(VM_IMAGE_DIR_ENV);
        let repo_root = Some(crate::repo_root());
        let exe_dir = env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(Path::to_path_buf));
        let home = env::var_os("HOME")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);

        Self {
            image,
            runtime_override,
            vm_helper_override,
            vm_image_override,
            repo_root,
            exe_dir,
            home,
        }
    }
}

/// Read a non-empty path-valued environment override.
fn path_override(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// Probe the current host for a usable build engine.
///
/// # Errors
///
/// Reserved for future backends. Probe failures only degrade the returned
/// [`EngineInfo`], so this always returns `Ok`.
pub fn engine_info() -> Result<EngineInfo, String> {
    Ok(probe_engine().info)
}

/// Run the frozen probe order once; `crate::build` also needs the runtime path.
pub(crate) fn probe_engine() -> EngineProbe {
    probe_engine_with(env::consts::OS, &EngineEnv::from_process(), PROBE_TIMEOUT)
}

/// Injectable probe core (platform + environment + timeout).
fn probe_engine_with(platform: &str, env: &EngineEnv, timeout: Duration) -> EngineProbe {
    let local = local_engine(platform);
    let local_available = matches!(local, LocalProbe::Available(_));

    // The VM helper is macOS-only; an injected non-macOS platform never probes
    // it (and never treats an injected result as usable).
    let vm = if local_available || platform != "macos" {
        VmProbe::NotApplicable
    } else {
        probe_vm(env, timeout)
    };

    // A usable host builder or VM wins unconditionally; do not pay for docker
    // probes when the engine is already known.
    let probes = if local_available || matches!(vm, VmProbe::Available(_)) {
        Vec::new()
    } else {
        probe_container_runtimes(env, timeout)
    };
    classify_engine(platform, &env.image, local, vm, &probes)
}

/// Outcome of the Linux-only local engine check.
#[derive(Debug, Clone)]
// Only a Linux host constructs `Available`/`Missing`; tests construct them on
// every platform to exercise the classification directly.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
enum LocalProbe {
    Available(EngineInfo),
    /// Linux host that is missing one or more requirements.
    Missing(String),
    /// Not a Linux host (or a simulated non-Linux platform in tests).
    NotApplicable,
}

#[cfg(target_os = "linux")]
fn local_engine(platform: &str) -> LocalProbe {
    if platform != "linux" {
        return LocalProbe::NotApplicable;
    }
    let info = linux_info(platform);
    if info.available {
        LocalProbe::Available(info)
    } else {
        LocalProbe::Missing(info.reason)
    }
}

#[cfg(not(target_os = "linux"))]
fn local_engine(_platform: &str) -> LocalProbe {
    LocalProbe::NotApplicable
}

#[cfg(target_os = "linux")]
fn linux_info(platform: &str) -> EngineInfo {
    // The builder writes disk images and needs root; geteuid mirrors the
    // check the builder itself will perform.
    let root = unsafe { libc::geteuid() } == 0;
    let missing: Vec<&str> = LOCAL_ENGINE_TOOLS
        .iter()
        .copied()
        .filter(|tool| !tool_in_path(tool))
        .collect();

    if root && missing.is_empty() {
        return EngineInfo {
            kind: "local".to_string(),
            available: true,
            platform: platform.to_string(),
            reason: "local Linux builder: root and all required tools are available".to_string(),
            runtime: None,
            image: None,
            image_present: None,
        };
    }

    let mut requirements: Vec<String> = Vec::new();
    if !root {
        requirements.push("root (geteuid() != 0)".to_string());
    }
    requirements.extend(missing.into_iter().map(str::to_string));

    EngineInfo {
        kind: "local".to_string(),
        available: false,
        platform: platform.to_string(),
        reason: format!("local builds need {}", requirements.join(", ")),
        runtime: None,
        image: None,
        image_present: None,
    }
}

/// True when `tool` names an existing file in one of the `PATH` directories.
#[cfg(target_os = "linux")]
fn tool_in_path(tool: &str) -> bool {
    env::var_os("PATH").is_some_and(|path| {
        env::split_paths(&path).any(|dir| !dir.as_os_str().is_empty() && dir.join(tool).is_file())
    })
}

/// State of one container runtime after probing.
#[derive(Debug, Clone, PartialEq, Eq)]
enum RuntimeStatus {
    Reachable {
        version: String,
        image_present: bool,
        /// Short daemon error when the image inspect failed.
        image_note: Option<String>,
    },
    Unreachable(String),
}

/// One runtime probe attempt, kept for reasons and for picking the executable.
#[derive(Debug, Clone, PartialEq, Eq)]
struct RuntimeProbe {
    name: String,
    executable: PathBuf,
    status: RuntimeStatus,
}

/// Probe the container runtimes in the frozen order (docker → podman), or only
/// the `SYSEMBLE_ENGINE_RUNTIME` override when it is set.
fn probe_container_runtimes(env: &EngineEnv, timeout: Duration) -> Vec<RuntimeProbe> {
    if let Some(executable) = &env.runtime_override {
        return vec![RuntimeProbe {
            name: runtime_name(executable),
            executable: executable.clone(),
            status: probe_runtime(executable, &env.image, timeout),
        }];
    }

    CONTAINER_RUNTIMES
        .iter()
        .map(|name| {
            let executable = PathBuf::from(name);
            RuntimeProbe {
                name: (*name).to_string(),
                status: probe_runtime(&executable, &env.image, timeout),
                executable,
            }
        })
        .collect()
}

/// Map a runtime executable to the `docker`/`podman` wire value.
///
/// The override is an executable path, so its file name decides the value; an
/// unknown name is reported as `docker` to keep the frozen `docker|podman`
/// domain.
fn runtime_name(executable: &Path) -> String {
    let stem = executable
        .file_stem()
        .map(|stem| stem.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    if stem.contains("podman") {
        "podman".to_string()
    } else {
        "docker".to_string()
    }
}

fn probe_runtime(executable: &Path, image: &str, timeout: Duration) -> RuntimeStatus {
    let version = match probe_runtime_version(executable, timeout) {
        Ok(version) => version,
        Err(error) => return RuntimeStatus::Unreachable(error),
    };
    let (image_present, image_note) = probe_image(executable, image, timeout);
    RuntimeStatus::Reachable {
        version,
        image_present,
        image_note,
    }
}

/// Ask the daemon for its version; this doubles as the reachability check.
///
/// docker and podman both answer `version`; the Go template differs on some
/// podman releases, so a template complaint retries the plain command before
/// declaring the runtime unreachable.
fn probe_runtime_version(executable: &Path, timeout: Duration) -> Result<String, String> {
    match run_probe(
        executable,
        &["version", "--format", "{{.Server.Version}}"],
        timeout,
    ) {
        Ok(output) => {
            let version = output
                .stdout
                .lines()
                .map(str::trim)
                .find(|line| !line.is_empty())
                .map(|line| truncate(line, 80));
            version.ok_or_else(|| "`version` returned no server version".to_string())
        }
        Err(failure) if failure.template_error => {
            let fallback = run_probe(executable, &["version"], timeout)
                .map_err(|fallback| fallback.message)?;
            parse_version_output(&fallback.stdout)
                .ok_or_else(|| "`version` returned no version line".to_string())
        }
        Err(failure) => Err(failure.message),
    }
}

/// Pull the first `Version:` value from the multi-line `version` output.
fn parse_version_output(stdout: &str) -> Option<String> {
    for line in stdout.lines() {
        if let Some(value) = line.trim().strip_prefix("Version:") {
            let value = value.trim();
            if !value.is_empty() {
                return Some(truncate(value, 80));
            }
        }
    }
    None
}

/// True when a failed probe looks like a bad Go template rather than an
/// unreachable engine.
fn looks_like_template_error(message: &str) -> bool {
    let lowered = message.to_ascii_lowercase();
    [
        "template",
        "can't evaluate",
        "cannot evaluate",
        "parse error",
    ]
    .iter()
    .any(|needle| lowered.contains(needle))
}

/// Check whether the engine image is present locally.
fn probe_image(executable: &Path, image: &str, timeout: Duration) -> (bool, Option<String>) {
    match run_probe(
        executable,
        &["image", "inspect", "--format", "{{.Id}}", image],
        timeout,
    ) {
        Ok(_) => (true, None),
        Err(failure) => (false, Some(failure.message)),
    }
}

/* ------------------------------------------------------------------- VM --- */

/// Outcome of the macOS Virtualization.framework probe.
///
/// Kept apart from [`EngineInfo`] because the helper/image paths are host paths
/// the UI must never see, and because classification needs to know whether a
/// helper merely *exists* (so `kind=vm, available=false` is more useful than
/// `none`) even when the engine is unusable.
#[derive(Debug, Clone)]
enum VmProbe {
    Available(VmAvailable),
    Unavailable(VmUnavailable),
    /// No helper candidate is configured (non-macOS host, or an injected test
    /// environment without paths).
    NotApplicable,
}

#[derive(Debug, Clone)]
struct VmAvailable {
    handle: VmHandle,
    version: String,
}

#[derive(Debug, Clone)]
struct VmUnavailable {
    /// Set when a helper executable exists but `probe --json` rejected it.
    helper: Option<PathBuf>,
    reason: String,
}

/// Validated `sysemble-vm.json`; only the fields this module needs are kept.
#[derive(Debug, Clone)]
struct VmManifest {
    version: String,
}

/// Probe the helper and the image in the frozen order (P1-e4 workplan §2.2).
///
/// Helper candidates are tried in order and the first one whose `probe --json`
/// passes wins; an existing but unusable helper is remembered so the caller can
/// report `kind=vm, available=false` instead of pretending no VM work exists.
fn probe_vm(env: &EngineEnv, timeout: Duration) -> VmProbe {
    let candidates = vm_helper_candidates(env);
    if candidates.is_empty() {
        return VmProbe::NotApplicable;
    }

    let mut existing: Option<PathBuf> = None;
    let mut first_failure: Option<String> = None;
    let mut selected: Option<PathBuf> = None;

    for candidate in &candidates {
        if !candidate.is_file() {
            continue;
        }
        existing.get_or_insert_with(|| candidate.clone());
        match run_vm_helper_probe(candidate, timeout) {
            Ok(()) => {
                selected = Some(candidate.clone());
                break;
            }
            Err(reason) => {
                first_failure.get_or_insert(reason);
            }
        }
    }

    let Some(helper) = selected else {
        let reason = first_failure.unwrap_or_else(|| {
            format!(
                "no {VM_IMAGE_NAME} helper found (looked at {}); build it with bash {VM_HELPER_SCRIPT}",
                display_paths(&candidates)
            )
        });
        return VmProbe::Unavailable(VmUnavailable {
            helper: existing,
            reason,
        });
    };
    let helper = fs::canonicalize(&helper).unwrap_or(helper);

    match find_vm_image(env) {
        Ok((image_dir, manifest)) => VmProbe::Available(VmAvailable {
            handle: VmHandle { helper, image_dir },
            version: manifest.version,
        }),
        Err(reason) => VmProbe::Unavailable(VmUnavailable {
            helper: Some(helper),
            reason: format!(
                "{reason}; build the image with {VM_IMAGE_SCRIPT} or install the app bundle image"
            ),
        }),
    }
}

/// Candidate helper paths in the frozen order (P1-e4 workplan §2.2).
///
/// The environment override is exclusive, like [`ENGINE_RUNTIME_ENV`]: an
/// explicit path must not be silently replaced by a repository helper.
fn vm_helper_candidates(env: &EngineEnv) -> Vec<PathBuf> {
    if let Some(override_path) = &env.vm_helper_override {
        return vec![override_path.clone()];
    }
    let mut candidates = Vec::new();
    if let Some(repo) = &env.repo_root {
        candidates.push(repo.join(VM_HELPER_REPO_PATH));
    }
    if let Some(exe_dir) = &env.exe_dir {
        candidates.push(exe_dir.join(VM_HELPER_BUNDLE_PATH));
    }
    candidates
}

/// Run `<helper> probe --json` and decide whether the helper can boot a VM.
///
/// The frozen contract is `entitled == true` plus `supported == true`, or
/// `supported == "unknown"` on macOS 13 where the framework does not expose
/// `VZVirtualMachine.isSupported`; `run` lets `validate()` decide there.
fn run_vm_helper_probe(helper: &Path, timeout: Duration) -> Result<(), String> {
    let output = run_probe(helper, &["probe", "--json"], timeout)
        .map_err(|failure| format!("`{} probe --json` failed: {}", helper.display(), failure.message))?;

    let text = output.stdout.trim();
    if text.is_empty() {
        return Err(format!("`{} probe --json` printed no JSON", helper.display()));
    }
    let json: Value = serde_json::from_str(text).map_err(|error| {
        format!(
            "`{} probe --json` did not print valid JSON: {error}",
            helper.display()
        )
    })?;

    let detail = json
        .get("reason")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|detail| !detail.is_empty())
        .map(|detail| format!(" ({})", truncate(detail, 200)))
        .unwrap_or_default();

    let mut problems: Vec<String> = Vec::new();
    if json.get("entitled").and_then(Value::as_bool) != Some(true) {
        problems.push("the helper is not signed with com.apple.security.virtualization".to_string());
    }
    match json.get("supported") {
        Some(Value::Bool(true)) => {}
        // macOS 13: `run` still lets VZVirtualMachineConfiguration.validate()
        // decide, so an unknown support status is usable when entitled.
        Some(Value::String(value)) if value == "unknown" => {}
        Some(Value::Bool(false)) => {
            problems.push("Virtualization.framework is not supported on this host".to_string());
        }
        other => problems.push(match other {
            None => "`probe --json` did not report `supported`".to_string(),
            Some(value) => {
                format!("`probe --json` reported an unusable supported value: {value}")
            }
        }),
    }
    match json.get("arch").and_then(Value::as_str) {
        Some(VM_ARCH) => {}
        Some(arch) => problems.push(format!(
            "the host architecture is {arch}; the engine image is arm64-only"
        )),
        None => problems.push("`probe --json` did not report the host architecture".to_string()),
    }

    if problems.is_empty() {
        Ok(())
    } else {
        Err(format!("{}{}", problems.join("; "), detail))
    }
}

/// Find the first valid image directory in the frozen candidate order.
///
/// The environment override is exclusive; otherwise the development tree is
/// preferred over installed (`Application Support`) versions. Installed
/// versions are `<version>/` directories, so the highest valid one is chosen.
fn find_vm_image(env: &EngineEnv) -> Result<(PathBuf, VmManifest), String> {
    if let Some(dir) = &env.vm_image_override {
        return load_vm_manifest(dir).map_err(|error| {
            format!(
                "{VM_IMAGE_DIR_ENV} points at `{}`, which is not a usable VM image: {error}",
                dir.display()
            )
        });
    }

    let mut tried: Vec<String> = Vec::new();
    if let Some(repo) = &env.repo_root {
        let dir = repo.join(VM_IMAGE_REPO_PATH);
        match load_vm_manifest(&dir) {
            Ok(found) => return Ok(found),
            Err(error) => tried.push(format!("{}: {error}", dir.display())),
        }
    }
    if let Some(home) = &env.home {
        let root = home.join(VM_IMAGE_APP_DATA_PATH);
        match newest_installed_vm_image(&root) {
            Ok(Some(found)) => return Ok(found),
            Ok(None) => tried.push(format!(
                "{}: no <version> directory with a valid {VM_MANIFEST_FILE}",
                root.display()
            )),
            Err(error) => tried.push(format!("{}: {error}", root.display())),
        }
    }
    if tried.is_empty() {
        return Err("no VM image directory candidate is configured".to_string());
    }
    Err(format!("no valid VM image: {}", tried.join("; ")))
}

/// Validate `<dir>/sysemble-vm.json` and the files it names.
///
/// The manifest is the frozen contract from the P1-e3 workplan §2.1: schema 1,
/// name `sysemble-vm`, arch `arm64`, and kernel/initrd/disk present. The disk is
/// additionally required to be a non-empty multiple of 512 bytes (a raw block
/// image) and to match the manifest's `size_bytes` when declared, which catches
/// a truncated copy without hashing six gigabytes.
fn load_vm_manifest(dir: &Path) -> Result<(PathBuf, VmManifest), String> {
    let dir = fs::canonicalize(dir)
        .map_err(|error| format!("cannot resolve `{}`: {error}", dir.display()))?;
    let manifest_path = dir.join(VM_MANIFEST_FILE);
    let text = fs::read_to_string(&manifest_path)
        .map_err(|error| format!("cannot read `{}`: {error}", manifest_path.display()))?;
    let json: Value = serde_json::from_str(&text)
        .map_err(|error| format!("`{}` is not valid JSON: {error}", manifest_path.display()))?;

    let schema = json.get("schema").and_then(Value::as_u64);
    if schema != Some(VM_MANIFEST_SCHEMA) {
        return Err(format!(
            "`{}` has schema {schema:?}, expected {VM_MANIFEST_SCHEMA}",
            manifest_path.display()
        ));
    }
    let name = json.get("name").and_then(Value::as_str).unwrap_or("");
    if name != VM_MANIFEST_NAME {
        return Err(format!(
            "`{}` names `{name}`, expected `{VM_MANIFEST_NAME}`",
            manifest_path.display()
        ));
    }
    let version = json
        .get("version")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|version| !version.is_empty())
        .map(str::to_string)
        .ok_or_else(|| format!("`{}` has no `version`", manifest_path.display()))?;
    let arch = json.get("arch").and_then(Value::as_str).unwrap_or("");
    if arch != VM_ARCH {
        return Err(format!(
            "`{}` targets `{arch}`, expected `{VM_ARCH}`",
            manifest_path.display()
        ));
    }

    manifest_file(&json, "kernel", &dir, &manifest_path)?;
    manifest_file(&json, "initrd", &dir, &manifest_path)?;
    let disk = manifest_file(&json, "disk", &dir, &manifest_path)?;
    let disk_size = fs::metadata(&disk)
        .map_err(|error| format!("cannot stat `{}`: {error}", disk.display()))?
        .len();
    if disk_size == 0 {
        return Err(format!("the disk image `{}` is empty", disk.display()));
    }
    if disk_size % 512 != 0 {
        return Err(format!(
            "the disk image `{}` size {disk_size} is not a multiple of 512 bytes",
            disk.display()
        ));
    }
    if let Some(declared) = json
        .get("disk")
        .and_then(|entry| entry.get("size_bytes"))
        .and_then(Value::as_u64)
    {
        if declared != disk_size {
            return Err(format!(
                "the disk image `{}` is {disk_size} bytes but the manifest declares {declared} (truncated?)",
                disk.display()
            ));
        }
    }

    // Keep the kernel/initrd validation in the error path above: the helper
    // would also reject a missing file, but a readable probe error is cheaper.
    Ok((dir, VmManifest { version }))
}

/// Resolve one `{ "path": ... }` manifest entry to an existing file.
fn manifest_file(
    json: &Value,
    key: &str,
    dir: &Path,
    manifest_path: &Path,
) -> Result<PathBuf, String> {
    let relative = json
        .get(key)
        .and_then(|entry| entry.get("path"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|path| !path.is_empty())
        .ok_or_else(|| format!("`{}` has no `{key}.path`", manifest_path.display()))?;
    let resolved = dir.join(relative);
    if !resolved.is_file() {
        return Err(format!(
            "the {key} file `{}` named by `{}` is missing",
            resolved.display(),
            manifest_path.display()
        ));
    }
    Ok(resolved)
}

/// Highest valid `<version>/` installation under `root`, or `None`.
///
/// Broken installations are skipped rather than fatal: a half-written upgrade
/// must not make an older, still-valid version unusable.
fn newest_installed_vm_image(root: &Path) -> Result<Option<(PathBuf, VmManifest)>, String> {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("cannot read `{}`: {error}", root.display())),
    };

    let mut best: Option<(VmManifest, PathBuf)> = None;
    for entry in entries {
        let entry = entry.map_err(|error| format!("cannot read `{}`: {error}", root.display()))?;
        let installed = entry.path();
        let is_dir = entry
            .file_type()
            .map_err(|error| format!("cannot inspect `{}`: {error}", installed.display()))?
            .is_dir();
        if !is_dir {
            continue;
        }
        let Some(dir_version) = installed.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        let Ok((found_dir, manifest)) = load_vm_manifest(&installed) else {
            continue;
        };
        // The installer keys each directory by the manifest version; anything
        // else is not a trustworthy installation.
        if manifest.version != dir_version {
            continue;
        }
        let newer = match &best {
            None => true,
            Some((current, _)) => version_is_newer(&manifest.version, &current.version),
        };
        if newer {
            best = Some((manifest, found_dir));
        }
    }

    Ok(best.map(|(manifest, dir)| (dir, manifest)))
}

/// Compare dotted numeric versions (`0.2.0` < `0.10.0`); otherwise compare the
/// raw strings so an unexpected version style still selects deterministically.
fn version_is_newer(candidate: &str, current: &str) -> bool {
    match (version_rank(candidate), version_rank(current)) {
        (Some(candidate), Some(current)) => candidate > current,
        _ => candidate > current,
    }
}

fn version_rank(version: &str) -> Option<Vec<u64>> {
    version.split('.').map(|part| part.parse::<u64>().ok()).collect()
}

fn display_paths(paths: &[PathBuf]) -> String {
    paths
        .iter()
        .map(|path| path.display().to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Classification of the probe results; pure so every branch is unit-tested
/// without a docker daemon, a helper, or a VM image.
fn classify_engine(
    platform: &str,
    image: &str,
    local: LocalProbe,
    vm: VmProbe,
    probes: &[RuntimeProbe],
) -> EngineProbe {
    if let LocalProbe::Available(info) = local {
        return EngineProbe {
            info,
            runtime_path: None,
            vm: None,
        };
    }

    // Virtualization.framework only exists on macOS; an injected VM result on
    // any other platform is never reported.
    let vm = if platform == "macos" {
        vm
    } else {
        VmProbe::NotApplicable
    };

    if let VmProbe::Available(available) = &vm {
        return EngineProbe {
            info: EngineInfo {
                kind: "vm".to_string(),
                available: true,
                platform: platform.to_string(),
                reason: format!(
                    "vm engine: {VM_IMAGE_NAME} {} · helper signed · image {VM_ARCH}",
                    available.version
                ),
                runtime: None,
                image: Some(format!("{VM_IMAGE_NAME}:{}", available.version)),
                image_present: Some(true),
            },
            runtime_path: None,
            vm: Some(available.handle.clone()),
        };
    }

    let vm_note = match &vm {
        VmProbe::Unavailable(unavailable) => Some(truncate(&unavailable.reason, 240)),
        VmProbe::Available(_) | VmProbe::NotApplicable => None,
    };

    // Prefer a runtime that actually has the image, even if it comes second.
    for probe in probes {
        if let RuntimeStatus::Reachable {
            version,
            image_present: true,
            ..
        } = &probe.status
        {
            return EngineProbe {
                info: container_info(
                    platform,
                    image,
                    probe,
                    true,
                    with_vm_note(
                        format!("container engine: {} {version} · image {image}", probe.name),
                        vm_note.as_deref(),
                    ),
                ),
                runtime_path: Some(probe.executable.clone()),
                vm: None,
            };
        }
    }

    // A reachable daemon with no image still beats "no engine": the reason can
    // tell the user exactly which script builds the image.
    for probe in probes {
        if let RuntimeStatus::Reachable {
            version,
            image_note,
            ..
        } = &probe.status
        {
            let note = image_note
                .as_deref()
                .map(|note| format!(" ({note})"))
                .unwrap_or_default();
            return EngineProbe {
                info: container_info(
                    platform,
                    image,
                    probe,
                    false,
                    with_vm_note(
                        format!(
                            "container engine: {} {version} · image {image} not found{note}; build it with {BUILD_IMAGE_SCRIPT}",
                            probe.name
                        ),
                        vm_note.as_deref(),
                    ),
                ),
                runtime_path: None,
                vm: None,
            };
        }
    }

    // The helper exists but cannot be used: report the more specific `vm`
    // failure instead of the generic `none`, unless a container already won.
    if let VmProbe::Unavailable(unavailable) = &vm {
        if unavailable.helper.is_some() {
            return EngineProbe {
                info: EngineInfo {
                    kind: "vm".to_string(),
                    available: false,
                    platform: platform.to_string(),
                    reason: format!("vm engine unavailable: {}", unavailable.reason),
                    runtime: None,
                    image: None,
                    image_present: None,
                },
                runtime_path: None,
                vm: None,
            };
        }
    }

    let local_note = match &local {
        LocalProbe::Missing(note) => Some(note.as_str()),
        LocalProbe::Available(_) | LocalProbe::NotApplicable => None,
    };
    EngineProbe {
        info: EngineInfo {
            kind: "none".to_string(),
            available: false,
            platform: platform.to_string(),
            reason: no_engine_reason(platform, local_note, vm_note.as_deref(), probes),
            runtime: None,
            image: None,
            image_present: None,
        },
        runtime_path: None,
        vm: None,
    }
}

/// Append a short VM note to a container reason when the VM engine is broken
/// but the container backend still works.
fn with_vm_note(base: String, vm_note: Option<&str>) -> String {
    match vm_note {
        Some(note) => format!("{base} · vm: {note}"),
        None => base,
    }
}

fn container_info(
    platform: &str,
    image: &str,
    probe: &RuntimeProbe,
    image_present: bool,
    reason: String,
) -> EngineInfo {
    EngineInfo {
        kind: "container".to_string(),
        available: image_present,
        platform: platform.to_string(),
        reason,
        runtime: Some(probe.name.clone()),
        image: Some(image.to_string()),
        image_present: Some(image_present),
    }
}

fn no_engine_reason(
    platform: &str,
    local_note: Option<&str>,
    vm_note: Option<&str>,
    probes: &[RuntimeProbe],
) -> String {
    let mut details: Vec<String> = Vec::new();
    if let Some(note) = local_note {
        details.push(note.to_string());
    }
    if let Some(note) = vm_note {
        details.push(format!("vm: {note}"));
    }
    for probe in probes {
        if let RuntimeStatus::Unreachable(error) = &probe.status {
            details.push(format!("{}: {error}", probe.name));
        }
    }
    if details.is_empty() {
        details.push("no container runtime was found".to_string());
    }
    format!(
        "no usable build engine on {platform}: {} — start Docker Desktop (or run `podman machine start`) and retry",
        details.join("; ")
    )
}

/// Why a probe command failed.
#[derive(Debug, Clone)]
struct ProbeFailure {
    message: String,
    /// The runtime rejected the output template; a plain `version` may work.
    template_error: bool,
}

/// Output of a successful probe command.
#[derive(Debug)]
struct ProbeOutput {
    stdout: String,
}

/// Run one probe command, killing it after `timeout`.
fn run_probe(
    executable: &Path,
    args: &[&str],
    timeout: Duration,
) -> Result<ProbeOutput, ProbeFailure> {
    let mut command = Command::new(executable);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    let mut child = command.spawn().map_err(|error| ProbeFailure {
        message: format!("cannot run `{}`: {error}", executable.display()),
        template_error: false,
    })?;
    let started = Instant::now();

    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let stdout = read_pipe(child.stdout.take());
                let stderr = read_pipe(child.stderr.take());
                if status.success() {
                    return Ok(ProbeOutput { stdout });
                }
                let detail = first_line(&stderr);
                let message = if detail.is_empty() {
                    format!("exited with {status}")
                } else {
                    detail
                };
                return Err(ProbeFailure {
                    template_error: looks_like_template_error(&message),
                    message,
                });
            }
            Ok(None) if started.elapsed() >= timeout => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(ProbeFailure {
                    message: format!("timed out after {}", human_duration(timeout)),
                    template_error: false,
                });
            }
            Ok(None) => thread::sleep(PROBE_POLL_INTERVAL),
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(ProbeFailure {
                    message: format!("cannot wait for `{}`: {error}", executable.display()),
                    template_error: false,
                });
            }
        }
    }
}

fn read_pipe(pipe: Option<impl Read>) -> String {
    let Some(mut pipe) = pipe else {
        return String::new();
    };
    let mut text = String::new();
    let _ = pipe.read_to_string(&mut text);
    text
}

fn first_line(text: &str) -> String {
    text.lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map_or_else(String::new, |line| truncate(line, 200))
}

fn truncate(text: &str, max_chars: usize) -> String {
    if text.chars().count() <= max_chars {
        return text.to_string();
    }
    let mut truncated: String = text.chars().take(max_chars.saturating_sub(1)).collect();
    truncated.push('…');
    truncated
}

fn human_duration(duration: Duration) -> String {
    if duration.as_secs() >= 1 {
        format!("{}s", duration.as_secs())
    } else {
        format!("{}ms", duration.as_millis())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn image() -> &'static str {
        DEFAULT_ENGINE_IMAGE
    }

    fn local_info() -> EngineInfo {
        EngineInfo {
            kind: "local".to_string(),
            available: true,
            platform: "linux".to_string(),
            reason: "local Linux builder: root and all required tools are available".to_string(),
            runtime: None,
            image: None,
            image_present: None,
        }
    }

    fn runtime(name: &str, status: RuntimeStatus) -> RuntimeProbe {
        RuntimeProbe {
            name: name.to_string(),
            executable: PathBuf::from(name),
            status,
        }
    }

    fn reachable(version: &str, image_present: bool) -> RuntimeStatus {
        RuntimeStatus::Reachable {
            version: version.to_string(),
            image_present,
            image_note: None,
        }
    }

    /// Per-test directory keyed by pid so tests can run in parallel.
    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new(tag: &str) -> Self {
            let path =
                env::temp_dir().join(format!("sysemble-engine-{tag}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).expect("temp directory should be creatable");
            Self { path }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    #[cfg(unix)]
    fn write_script(path: &Path, body: &str) {
        use std::os::unix::fs::PermissionsExt;

        fs::write(path, body).expect("fake runtime should be writable");
        let mut permissions = fs::metadata(path)
            .expect("fake runtime metadata should be readable")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).expect("fake runtime should be executable");
    }

    /// A probe environment with every VM path unset, so only the container
    /// probe can answer. Tests opt into VM discovery explicitly.
    fn container_env(image: &str) -> EngineEnv {
        EngineEnv {
            image: image.to_string(),
            runtime_override: None,
            vm_helper_override: None,
            vm_image_override: None,
            repo_root: None,
            exe_dir: None,
            home: None,
        }
    }

    fn vm_handle(tag: &str) -> VmHandle {
        VmHandle {
            helper: PathBuf::from(format!("/{tag}/sysemble-vm")),
            image_dir: PathBuf::from(format!("/{tag}/image")),
        }
    }

    fn vm_available(tag: &str, version: &str) -> VmProbe {
        VmProbe::Available(VmAvailable {
            handle: vm_handle(tag),
            version: version.to_string(),
        })
    }

    fn vm_unavailable(helper: Option<&str>, reason: &str) -> VmProbe {
        VmProbe::Unavailable(VmUnavailable {
            helper: helper.map(PathBuf::from),
            reason: reason.to_string(),
        })
    }

    /// `probe --json` output of a healthy helper.
    fn healthy_probe_json() -> &'static str {
        r#"{"supported":true,"entitled":true,"arch":"arm64","macos":"26.6.2","cpus":10,"reason":"ok: Virtualization.framework is supported and VZVirtualMachineConfiguration.validate() accepted the signature."}"#
    }

    /// Create a valid `<dir>/` VM image with the given manifest version.
    fn write_vm_image(dir: &Path, version: &str) -> PathBuf {
        fs::create_dir_all(dir).expect("image directory should be creatable");
        fs::write(dir.join("vmlinuz"), b"kernel").expect("kernel should be writable");
        fs::write(dir.join("initrd.img"), b"initrd").expect("initrd should be writable");
        fs::write(dir.join("disk.img"), vec![0u8; 1024]).expect("disk should be writable");
        let manifest = serde_json::json!({
            "schema": 1,
            "name": "sysemble-vm",
            "version": version,
            "arch": "arm64",
            "kernel": {"path": "vmlinuz"},
            "initrd": {"path": "initrd.img"},
            "disk": {"path": "disk.img", "size_bytes": 1024},
        });
        fs::write(
            dir.join(VM_MANIFEST_FILE),
            serde_json::to_string_pretty(&manifest).expect("manifest should serialize"),
        )
        .expect("manifest should be writable");
        dir.to_path_buf()
    }

    /// Create `<repo>/engine/vm/image/build` plus the helper directory shape.
    fn fake_repo_with_image(tag: &str, version: &str) -> (TempDir, PathBuf) {
        let repo = TempDir::new(tag);
        let image_dir = repo.path.join(VM_IMAGE_REPO_PATH);
        write_vm_image(&image_dir, version);
        let helper_dir = repo
            .path
            .join(VM_HELPER_REPO_PATH)
            .parent()
            .expect("helper path should have a parent")
            .to_path_buf();
        fs::create_dir_all(&helper_dir).expect("helper directory should be creatable");
        let repo_abs = fs::canonicalize(&repo.path).expect("fake repository should resolve");
        (repo, repo_abs)
    }

    #[test]
    fn engine_info_reports_the_host_capability() {
        let info = engine_info().expect("the local engine probe cannot fail");

        assert!(!info.platform.is_empty(), "platform must not be empty");
        assert!(!info.reason.trim().is_empty(), "reason must never be empty");
        assert!(
            ["local", "vm", "container", "none"].contains(&info.kind.as_str()),
            "unexpected engine kind: {}",
            info.kind
        );

        match info.kind.as_str() {
            "local" => {
                assert!(info.available, "kind local must be available");
                assert!(info.runtime.is_none());
            }
            "vm" => {
                assert!(info.available, "a reported vm engine must be available");
                assert!(info.runtime.is_none(), "a vm engine has no container runtime");
                assert!(
                    info.image
                        .as_deref()
                        .is_some_and(|image| image.starts_with("sysemble-vm:")),
                    "vm image reference should be sysemble-vm:<version>: {:?}",
                    info.image
                );
                assert_eq!(info.image_present, Some(true));
            }
            "container" => {
                assert!(info.runtime.is_some(), "container engine needs a runtime");
                assert_eq!(
                    info.available,
                    info.image_present.unwrap_or(false),
                    "availability must follow image presence"
                );
            }
            _ => assert!(!info.available, "kind none must not be available"),
        }

        #[cfg(any(target_os = "macos", target_os = "windows"))]
        assert_ne!(info.kind, "local", "local builds are Linux-only");

        eprintln!(
            "EngineInfo={}",
            serde_json::to_string_pretty(&info).expect("engine info should serialize")
        );
    }

    #[test]
    fn engine_info_serializes_the_e2_fields() {
        let info = engine_info().expect("the engine probe cannot fail");
        let json = serde_json::to_value(&info).expect("engine info should serialize");

        for field in [
            "kind",
            "available",
            "platform",
            "reason",
            "runtime",
            "image",
            "image_present",
        ] {
            assert!(
                json.get(field).is_some(),
                "serialized engine info is missing `{field}`: {json}"
            );
        }

        assert_eq!(json["kind"], info.kind);
        assert_eq!(json["available"], info.available);
        assert_eq!(json["platform"], env::consts::OS);
        assert!(json["runtime"].is_null() || json["runtime"].is_string());
        assert!(json["image"].is_null() || json["image"].is_string());
        assert!(json["image_present"].is_null() || json["image_present"].is_boolean());
    }

    #[test]
    fn classification_prefers_the_local_engine() {
        let probe = classify_engine(
            "linux",
            image(),
            LocalProbe::Available(local_info()),
            vm_available("local-priority", "0.1.0"),
            &[runtime("docker", reachable("29.1.2", true))],
        );

        assert_eq!(probe.info.kind, "local");
        assert!(probe.info.available);
        assert!(probe.runtime_path.is_none());
        assert!(probe.vm.is_none());
    }

    #[test]
    fn classification_accepts_a_container_with_the_image() {
        let probe = classify_engine(
            "macos",
            image(),
            LocalProbe::NotApplicable,
            VmProbe::NotApplicable,
            &[runtime("docker", reachable("29.1.2", true))],
        );

        assert_eq!(probe.info.kind, "container");
        assert!(probe.info.available);
        assert_eq!(probe.info.runtime.as_deref(), Some("docker"));
        assert_eq!(probe.info.image.as_deref(), Some(image()));
        assert_eq!(probe.info.image_present, Some(true));
        assert_eq!(
            probe.info.reason,
            format!("container engine: docker 29.1.2 · image {}", image())
        );
        assert_eq!(probe.runtime_path, Some(PathBuf::from("docker")));
    }

    #[test]
    fn classification_points_at_the_image_script_when_the_image_is_missing() {
        let probe = classify_engine(
            "macos",
            image(),
            LocalProbe::NotApplicable,
            VmProbe::NotApplicable,
            &[runtime("docker", reachable("29.1.2", false))],
        );

        assert_eq!(probe.info.kind, "container");
        assert!(!probe.info.available);
        assert_eq!(probe.info.runtime.as_deref(), Some("docker"));
        assert_eq!(probe.info.image_present, Some(false));
        assert!(
            probe.info.reason.contains(BUILD_IMAGE_SCRIPT),
            "reason should point at the image build script: {}",
            probe.info.reason
        );
    }

    #[test]
    fn classification_reports_none_when_no_engine_answers() {
        let probe = classify_engine(
            "macos",
            image(),
            LocalProbe::NotApplicable,
            VmProbe::NotApplicable,
            &[
                runtime(
                    "docker",
                    RuntimeStatus::Unreachable("cannot connect to the daemon".to_string()),
                ),
                runtime(
                    "podman",
                    RuntimeStatus::Unreachable("no such file".to_string()),
                ),
            ],
        );

        assert_eq!(probe.info.kind, "none");
        assert!(!probe.info.available);
        assert!(probe.info.runtime.is_none());
        assert_eq!(probe.info.image_present, None);
        assert!(
            probe
                .info
                .reason
                .contains("docker: cannot connect to the daemon"),
            "reason should carry the docker error: {}",
            probe.info.reason
        );
        assert!(
            probe.info.reason.contains("podman: no such file"),
            "reason should carry the podman error: {}",
            probe.info.reason
        );
        assert!(
            probe.info.reason.contains("start Docker Desktop"),
            "reason should tell the user how to start the daemon: {}",
            probe.info.reason
        );
    }

    #[test]
    fn classification_prefers_a_runtime_that_has_the_image() {
        let probe = classify_engine(
            "macos",
            image(),
            LocalProbe::NotApplicable,
            VmProbe::NotApplicable,
            &[
                runtime("docker", reachable("29.1.2", false)),
                runtime("podman", reachable("5.4.1", true)),
            ],
        );

        assert_eq!(probe.info.runtime.as_deref(), Some("podman"));
        assert!(probe.info.available);
        assert_eq!(probe.runtime_path, Some(PathBuf::from("podman")));
    }

    #[cfg(unix)]
    #[test]
    fn probe_marks_hung_runtime_commands_unreachable() {
        let temp = TempDir::new("timeout");
        let runtime_path = temp.path.join("docker");
        write_script(&runtime_path, "#!/bin/sh\nexec sleep 30\n");

        let env = EngineEnv {
            runtime_override: Some(runtime_path),
            ..container_env(image())
        };
        let began = Instant::now();
        let probe = probe_engine_with("macos", &env, Duration::from_millis(250));
        let elapsed = began.elapsed();

        assert_eq!(PROBE_TIMEOUT, Duration::from_secs(4));
        assert!(
            elapsed < Duration::from_secs(5),
            "a hung runtime must be killed at the probe timeout, took {elapsed:?}"
        );
        assert_eq!(probe.info.kind, "none");
        assert!(!probe.info.available);
        assert!(
            probe.info.reason.contains("timed out"),
            "reason should mention the timeout: {}",
            probe.info.reason
        );
    }

    #[cfg(unix)]
    #[test]
    fn probe_reads_the_runtime_version_and_image_presence() {
        let temp = TempDir::new("ready");
        let runtime_path = temp.path.join("podman");
        write_script(
            &runtime_path,
            "#!/bin/sh\ncase \"$1\" in\n  version) printf '5.4.1\\n' ;;\n  image) exit 0 ;;\nesac\n",
        );

        let env = EngineEnv {
            runtime_override: Some(runtime_path.clone()),
            ..container_env("sysemble-engine:test")
        };
        let probe = probe_engine_with("macos", &env, PROBE_TIMEOUT);

        assert_eq!(probe.info.kind, "container");
        assert!(probe.info.available);
        assert_eq!(probe.info.runtime.as_deref(), Some("podman"));
        assert_eq!(probe.info.image.as_deref(), Some("sysemble-engine:test"));
        assert_eq!(probe.info.image_present, Some(true));
        assert!(
            probe.info.reason.contains("5.4.1"),
            "reason should carry the runtime version: {}",
            probe.info.reason
        );
        assert_eq!(probe.runtime_path, Some(runtime_path));
    }

    #[cfg(unix)]
    #[test]
    fn probe_reports_a_missing_image_without_failing() {
        let temp = TempDir::new("missing-image");
        let runtime_path = temp.path.join("docker");
        write_script(
            &runtime_path,
            "#!/bin/sh\ncase \"$1\" in\n  version) printf '29.1.2\\n' ;;\n  image) printf 'Error response from daemon: No such image\\n' >&2; exit 1 ;;\nesac\n",
        );

        let env = EngineEnv {
            runtime_override: Some(runtime_path),
            ..container_env(image())
        };
        let probe = probe_engine_with("macos", &env, PROBE_TIMEOUT);

        assert_eq!(probe.info.kind, "container");
        assert!(!probe.info.available);
        assert_eq!(probe.info.image_present, Some(false));
        assert!(probe.runtime_path.is_none());
        assert!(
            probe.info.reason.contains(BUILD_IMAGE_SCRIPT),
            "reason should name the image build script: {}",
            probe.info.reason
        );
    }

    #[cfg(unix)]
    #[test]
    fn probe_falls_back_to_plain_version_for_template_errors() {
        let temp = TempDir::new("template-fallback");
        let runtime_path = temp.path.join("podman");
        write_script(
            &runtime_path,
            r#"#!/bin/sh
case "$1" in
  version)
    if [ "$2" = "--format" ]; then
      printf '%s\n' "template: can't evaluate field Server" >&2
      exit 1
    fi
    printf 'Client: Podman Engine\nVersion: 5.4.1\n'
    ;;
  image)
    exit 0
    ;;
esac
"#,
        );

        let env = EngineEnv {
            runtime_override: Some(runtime_path),
            ..container_env(image())
        };
        let probe = probe_engine_with("macos", &env, PROBE_TIMEOUT);

        assert_eq!(probe.info.runtime.as_deref(), Some("podman"));
        assert!(probe.info.available, "reason: {}", probe.info.reason);
        assert!(
            probe.info.reason.contains("5.4.1"),
            "reason should carry the parsed version: {}",
            probe.info.reason
        );
    }

    #[test]
    fn classification_prefers_the_vm_engine() {
        let probe = classify_engine(
            "macos",
            image(),
            LocalProbe::NotApplicable,
            vm_available("vm-wins", "0.1.0"),
            &[runtime("docker", reachable("29.1.2", true))],
        );

        assert_eq!(probe.info.kind, "vm");
        assert!(probe.info.available);
        assert_eq!(
            probe.info.reason,
            "vm engine: sysemble-vm 0.1.0 · helper signed · image arm64"
        );
        assert_eq!(probe.info.image.as_deref(), Some("sysemble-vm:0.1.0"));
        assert_eq!(probe.info.image_present, Some(true));
        assert!(probe.info.runtime.is_none());
        assert!(probe.runtime_path.is_none());
        assert_eq!(probe.vm, Some(vm_handle("vm-wins")));
    }

    #[test]
    fn classification_ignores_a_vm_engine_on_non_macos_hosts() {
        let probe = classify_engine(
            "linux",
            image(),
            LocalProbe::NotApplicable,
            vm_available("linux-vm", "0.1.0"),
            &[runtime("docker", reachable("29.1.2", true))],
        );

        assert_eq!(probe.info.kind, "container");
        assert!(probe.info.available);
        assert!(probe.vm.is_none());
    }

    #[test]
    fn classification_falls_back_to_the_container_when_the_vm_image_is_missing() {
        let probe = classify_engine(
            "macos",
            image(),
            LocalProbe::NotApplicable,
            vm_unavailable(
                Some("/repo/engine/vm/macos/.build/release/sysemble-vm"),
                "no valid VM image: disk.img is empty; build the image with engine/vm/image/build-image.sh or install the app bundle image",
            ),
            &[runtime("docker", reachable("29.1.2", true))],
        );

        assert_eq!(probe.info.kind, "container");
        assert!(probe.info.available);
        assert_eq!(probe.info.runtime.as_deref(), Some("docker"));
        assert!(probe.vm.is_none());
        assert!(
            probe.info.reason.contains(" · vm: no valid VM image"),
            "container reason should carry the VM note: {}",
            probe.info.reason
        );
    }

    #[test]
    fn classification_reports_an_unavailable_vm_when_only_the_helper_exists() {
        let probe = classify_engine(
            "macos",
            image(),
            LocalProbe::NotApplicable,
            vm_unavailable(
                Some("/repo/engine/vm/macos/.build/release/sysemble-vm"),
                "no valid VM image: disk.img is empty; build the image with engine/vm/image/build-image.sh or install the app bundle image",
            ),
            &[
                runtime(
                    "docker",
                    RuntimeStatus::Unreachable("cannot connect to the daemon".to_string()),
                ),
                runtime(
                    "podman",
                    RuntimeStatus::Unreachable("no such file".to_string()),
                ),
            ],
        );

        assert_eq!(probe.info.kind, "vm");
        assert!(!probe.info.available);
        assert!(probe.info.runtime.is_none());
        assert!(probe.vm.is_none());
        assert!(
            probe.info.reason.contains("vm engine unavailable"),
            "reason should name the VM failure: {}",
            probe.info.reason
        );
        assert!(
            probe.info.reason.contains(VM_IMAGE_SCRIPT),
            "reason should point at the image build script: {}",
            probe.info.reason
        );
    }

    #[test]
    fn classification_keeps_none_when_no_helper_exists() {
        let probe = classify_engine(
            "macos",
            image(),
            LocalProbe::NotApplicable,
            vm_unavailable(
                None,
                "no sysemble-vm helper found (looked at /repo/engine/vm/macos/.build/release/sysemble-vm); build it with bash engine/vm/macos/build.sh",
            ),
            &[runtime(
                "docker",
                RuntimeStatus::Unreachable("cannot connect to the daemon".to_string()),
            )],
        );

        assert_eq!(probe.info.kind, "none");
        assert!(!probe.info.available);
        assert!(
            probe.info.reason.contains("vm: no sysemble-vm helper found"),
            "reason should carry the helper note: {}",
            probe.info.reason
        );
        assert!(
            probe.info.reason.contains("start Docker Desktop"),
            "reason should keep the daemon hint: {}",
            probe.info.reason
        );
    }

    #[cfg(unix)]
    #[test]
    fn probe_accepts_unknown_support_when_entitled() {
        let temp = TempDir::new("vm-unknown-support");
        let helper = temp.path.join("sysemble-vm");
        write_script(
            &helper,
            r#"#!/bin/sh
printf '%s\n' '{"supported":"unknown","entitled":true,"arch":"arm64","macos":"13.6","cpus":8,"reason":"VZVirtualMachine.isSupported is only consulted on macOS 14+; reporting unknown on macOS 13.6."}'
"#,
        );

        run_vm_helper_probe(&helper, PROBE_TIMEOUT)
            .expect("macOS 13 unknown support stays usable when the helper is entitled");
    }

    #[cfg(unix)]
    #[test]
    fn probe_rejects_unsigned_unsupported_and_foreign_helpers() {
        let temp = TempDir::new("vm-probe-failures");

        let unsigned = temp.path.join("unsigned");
        write_script(
            &unsigned,
            r#"#!/bin/sh
printf '%s\n' '{"supported":true,"entitled":false,"arch":"arm64","macos":"26.6.2","cpus":10,"reason":"validate() rejected this executable: missing entitlement"}'
"#,
        );
        let error = run_vm_helper_probe(&unsigned, PROBE_TIMEOUT)
            .expect_err("an unsigned helper must be rejected");
        assert!(
            error.contains("com.apple.security.virtualization"),
            "error should name the entitlement: {error}"
        );

        let unsupported = temp.path.join("unsupported");
        write_script(
            &unsupported,
            r#"#!/bin/sh
printf '%s\n' '{"supported":false,"entitled":true,"arch":"arm64","macos":"26.6.2","cpus":10,"reason":"VZVirtualMachine.isSupported is false"}'
"#,
        );
        let error = run_vm_helper_probe(&unsupported, PROBE_TIMEOUT)
            .expect_err("an unsupported host must be rejected");
        assert!(
            error.contains("not supported"),
            "error should name the missing support: {error}"
        );

        let intel = temp.path.join("intel");
        write_script(
            &intel,
            r#"#!/bin/sh
printf '%s\n' '{"supported":true,"entitled":true,"arch":"x86_64","macos":"13.6","cpus":8,"reason":"ok"}'
"#,
        );
        let error =
            run_vm_helper_probe(&intel, PROBE_TIMEOUT).expect_err("an Intel host must be rejected");
        assert!(
            error.contains("arm64-only"),
            "error should explain the architecture: {error}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn probe_marks_hung_vm_helpers_unreachable() {
        let temp = TempDir::new("vm-timeout");
        let helper = temp.path.join("sysemble-vm");
        write_script(&helper, "#!/bin/sh\nexec sleep 30\n");

        let began = Instant::now();
        let error = run_vm_helper_probe(&helper, Duration::from_millis(250))
            .expect_err("a hung helper must be killed at the probe timeout");

        assert!(
            began.elapsed() < Duration::from_secs(5),
            "the VM probe timeout was not honored: {:?}",
            began.elapsed()
        );
        assert!(
            error.contains("timed out"),
            "error should mention the timeout: {error}"
        );
    }

    #[cfg(unix)]
    #[test]
    fn probe_vm_uses_the_first_helper_that_passes() {
        let temp = TempDir::new("vm-first-passing-helper");
        let repo = temp.path.join("repo");
        write_vm_image(&repo.join(VM_IMAGE_REPO_PATH), "0.1.0");

        // The repository helper is first in the frozen order but unsigned.
        let repo_helper = repo.join(VM_HELPER_REPO_PATH);
        fs::create_dir_all(repo_helper.parent().expect("helper path should have a parent"))
            .expect("helper directory should be creatable");
        write_script(
            &repo_helper,
            r#"#!/bin/sh
printf '%s\n' '{"supported":true,"entitled":false,"arch":"arm64","macos":"26.6.2","cpus":10,"reason":"not signed"}'
"#,
        );

        // The bundled (app) helper is the second candidate and passes.
        let exe_dir = temp.path.join("app/Contents/MacOS");
        let bundle_helper = exe_dir.join(VM_HELPER_BUNDLE_PATH);
        fs::create_dir_all(
            bundle_helper
                .parent()
                .expect("bundle helper path should have a parent"),
        )
        .expect("bundle helper directory should be creatable");
        write_script(
            &bundle_helper,
            &format!("#!/bin/sh\nprintf '%s\\n' '{}'\n", healthy_probe_json()),
        );

        let env = EngineEnv {
            repo_root: Some(repo.clone()),
            exe_dir: Some(exe_dir),
            ..container_env(image())
        };
        let VmProbe::Available(available) = probe_vm(&env, PROBE_TIMEOUT) else {
            panic!("the second helper should make the vm available");
        };

        assert_eq!(available.version, "0.1.0");
        assert!(
            available.handle.helper.ends_with("Helpers/sysemble-vm"),
            "the signed bundled helper must win: {:?}",
            available.handle.helper
        );
        assert_eq!(
            available.handle.image_dir,
            repo_abs(&repo.join(VM_IMAGE_REPO_PATH))
        );
    }

    fn repo_abs(path: &Path) -> PathBuf {
        fs::canonicalize(path).expect("path should resolve")
    }

    #[cfg(unix)]
    #[test]
    fn probe_vm_keeps_an_existing_unsigned_helper_for_the_reason() {
        let temp = TempDir::new("vm-unsigned");
        let repo = temp.path.join("repo");
        write_vm_image(&repo.join(VM_IMAGE_REPO_PATH), "0.1.0");
        let helper = repo.join(VM_HELPER_REPO_PATH);
        fs::create_dir_all(helper.parent().expect("helper path should have a parent"))
            .expect("helper directory should be creatable");
        write_script(
            &helper,
            r#"#!/bin/sh
printf '%s\n' '{"supported":true,"entitled":false,"arch":"arm64","macos":"26.6.2","cpus":10,"reason":"missing entitlement"}'
"#,
        );

        let env = EngineEnv {
            repo_root: Some(repo),
            ..container_env(image())
        };
        match probe_vm(&env, PROBE_TIMEOUT) {
            VmProbe::Unavailable(unavailable) => {
                assert!(unavailable.helper.is_some());
                assert!(
                    unavailable.reason.contains("com.apple.security.virtualization"),
                    "reason: {}",
                    unavailable.reason
                );
            }
            other => panic!("expected an unavailable vm, got {other:?}"),
        }
    }

    #[test]
    fn vm_helper_env_override_is_exclusive() {
        let env = EngineEnv {
            vm_helper_override: Some(PathBuf::from("/opt/sysemble/helpers/sysemble-vm")),
            repo_root: Some(PathBuf::from("/repo")),
            exe_dir: Some(PathBuf::from("/app/Contents/MacOS")),
            ..container_env(image())
        };

        assert_eq!(
            vm_helper_candidates(&env),
            vec![PathBuf::from("/opt/sysemble/helpers/sysemble-vm")]
        );
    }

    #[test]
    fn vm_helper_candidates_follow_the_frozen_order() {
        let env = EngineEnv {
            repo_root: Some(PathBuf::from("/repo")),
            exe_dir: Some(PathBuf::from("/app/Contents/MacOS")),
            ..container_env(image())
        };

        assert_eq!(
            vm_helper_candidates(&env),
            vec![
                PathBuf::from("/repo").join(VM_HELPER_REPO_PATH),
                PathBuf::from("/app/Contents/MacOS").join(VM_HELPER_BUNDLE_PATH),
            ]
        );
    }

    #[test]
    fn vm_image_env_override_wins_over_the_repository() {
        let temp = TempDir::new("vm-image-override");
        let repo = temp.path.join("repo");
        write_vm_image(&repo.join(VM_IMAGE_REPO_PATH), "0.1.0");
        let override_dir = temp.path.join("override image 中文");
        write_vm_image(&override_dir, "9.9.9");

        let env = EngineEnv {
            vm_image_override: Some(override_dir.clone()),
            repo_root: Some(repo),
            ..container_env(image())
        };
        let (dir, manifest) = find_vm_image(&env).expect("the override image should be used");

        assert_eq!(manifest.version, "9.9.9");
        assert_eq!(dir, repo_abs(&override_dir));
    }

    #[test]
    fn vm_image_falls_back_to_the_repository() {
        let (_repo, repo_root) = fake_repo_with_image("vm-image-repo", "0.1.0");
        let env = EngineEnv {
            repo_root: Some(repo_root.clone()),
            ..container_env(image())
        };

        let (dir, manifest) = find_vm_image(&env).expect("the repository image should be used");

        assert_eq!(manifest.version, "0.1.0");
        assert_eq!(dir, repo_abs(&repo_root.join(VM_IMAGE_REPO_PATH)));
    }

    #[test]
    fn installed_images_pick_the_highest_valid_version() {
        let temp = TempDir::new("vm-image-appdata");
        let home = temp.path.join("home");
        let root = home.join(VM_IMAGE_APP_DATA_PATH);
        write_vm_image(&root.join("0.1.0"), "0.1.0");
        write_vm_image(&root.join("0.2.0"), "0.2.0");
        write_vm_image(&root.join("0.10.0"), "0.10.0");
        // A manifest version that disagrees with its directory is not trusted.
        write_vm_image(&root.join("9.0.0"), "0.3.0");
        // A declared-size mismatch (truncated copy) is skipped as invalid.
        let truncated = write_vm_image(&root.join("0.11.0"), "0.11.0");
        fs::write(truncated.join("disk.img"), vec![0u8; 512])
            .expect("truncated disk should be writable");

        let env = EngineEnv {
            home: Some(home),
            ..container_env(image())
        };
        let (dir, manifest) = find_vm_image(&env).expect("the installed image should be used");

        assert_eq!(manifest.version, "0.10.0", "0.10.0 must sort above 0.2.0");
        assert_eq!(dir, repo_abs(&root.join("0.10.0")));
    }

    #[test]
    fn a_broken_image_override_is_a_readable_error() {
        let temp = TempDir::new("vm-image-broken-override");
        let env = EngineEnv {
            vm_image_override: Some(temp.path.join("missing-image")),
            ..container_env(image())
        };

        let error = find_vm_image(&env).expect_err("a broken override must be reported");
        assert!(
            error.contains(VM_IMAGE_DIR_ENV),
            "error should name the override: {error}"
        );
        assert!(
            error.contains("missing-image"),
            "error should name the path: {error}"
        );
    }

    #[test]
    fn vm_manifest_validation_rejects_broken_images() {
        let temp = TempDir::new("vm-manifest-cases");

        let missing_disk = temp.path.join("missing-disk");
        write_vm_image(&missing_disk, "0.1.0");
        fs::remove_file(missing_disk.join("disk.img")).expect("disk should be removable");
        let error = load_vm_manifest(&missing_disk).expect_err("a missing disk must be rejected");
        assert!(
            error.contains("disk file") && error.contains("missing"),
            "error should name the missing file: {error}"
        );

        let odd_disk = temp.path.join("odd-disk");
        write_vm_image(&odd_disk, "0.1.0");
        fs::write(odd_disk.join("disk.img"), vec![0u8; 513]).expect("odd disk should be writable");
        let error = load_vm_manifest(&odd_disk).expect_err("a 513-byte disk must be rejected");
        assert!(
            error.contains("multiple of 512"),
            "error should explain the block size: {error}"
        );

        let truncated = temp.path.join("truncated");
        write_vm_image(&truncated, "0.1.0");
        fs::write(truncated.join("disk.img"), vec![0u8; 512])
            .expect("truncated disk should be writable");
        let error = load_vm_manifest(&truncated).expect_err("a truncated disk must be rejected");
        assert!(
            error.contains("truncated"),
            "error should mention truncation: {error}"
        );

        let wrong_arch = temp.path.join("wrong-arch");
        write_vm_image(&wrong_arch, "0.1.0");
        let manifest_path = wrong_arch.join(VM_MANIFEST_FILE);
        let mut json: Value = serde_json::from_str(
            &fs::read_to_string(&manifest_path).expect("manifest should be readable"),
        )
        .expect("manifest should parse");
        json["arch"] = Value::String("x86_64".to_string());
        fs::write(
            &manifest_path,
            serde_json::to_string(&json).expect("manifest should serialize"),
        )
        .expect("manifest should be writable");
        let error = load_vm_manifest(&wrong_arch).expect_err("an x86_64 image must be rejected");
        assert!(
            error.contains("arm64"),
            "error should name the expected arch: {error}"
        );
    }

    #[test]
    fn default_engine_image_matches_the_version_file() {
        let version_file =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../engine/image/version");
        let Ok(contents) = fs::read_to_string(&version_file) else {
            eprintln!(
                "skipping: {} does not exist yet (P1-e2a)",
                version_file.display()
            );
            return;
        };
        let version = contents.trim();
        assert!(
            !version.is_empty(),
            "{} should not be empty",
            version_file.display()
        );
        assert_eq!(DEFAULT_ENGINE_IMAGE, format!("sysemble-engine:{version}"));
    }
}
