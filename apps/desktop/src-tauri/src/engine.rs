//! Engine availability probe for the desktop shell (P1-e2).
//!
//! P1-e's target shape is a Linux engine VM on macOS/Windows. P1-e2 ships the
//! first usable form of that idea: a versioned Debian engine image executed by
//! docker or podman with `--platform linux/amd64`. This module answers the
//! question the Build button needs: where can a real build run right now?
//!
//! The probe order is frozen by `docs/plan/P1-e2-workplan.md` §2.2:
//! `local` (Linux root + tools) → `container` (docker → podman) → `none`.
//! Every probe command is bounded by [`PROBE_TIMEOUT`]; a failing or hung probe
//! only degrades the result, it never makes [`engine_info`] return `Err`.
//!
//! The runtime commands are spawned directly (no shell, no extra dependency)
//! because the desktop crate deliberately keeps its dependency list small.

use std::env;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde::Serialize;

/// Engine image produced by `engine/image/build-image.sh` (P1-e2a).
pub const DEFAULT_ENGINE_IMAGE: &str = "sysemble-engine:0.1.0";

/// Environment override for the engine image reference.
pub const ENGINE_IMAGE_ENV: &str = "SYSEMBLE_ENGINE_IMAGE";

/// Environment override for the container runtime executable.
///
/// When set, the docker → podman probe order is skipped and only this
/// executable is probed. Intended for tests and advanced users.
pub const ENGINE_RUNTIME_ENV: &str = "SYSEMBLE_ENGINE_RUNTIME";

/// Every probe command gets this long before it is killed and downgraded.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(4);

/// Container runtimes in the frozen probe order.
const CONTAINER_RUNTIMES: [&str; 2] = ["docker", "podman"];

/// Script that builds the missing engine image; quoted in the reason text.
const BUILD_IMAGE_SCRIPT: &str = "engine/image/build-image.sh";

/// How often a spawned probe child is polled for completion.
const PROBE_POLL_INTERVAL: Duration = Duration::from_millis(25);

/// Tools the Debian builder invokes on a Linux host.
#[cfg(target_os = "linux")]
const LOCAL_ENGINE_TOOLS: [&str; 4] = ["mmdebstrap", "sgdisk", "mkfs.ext4", "qemu-img"];

/// Whether this host has a usable build engine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EngineInfo {
    /// `local`, `container`, or `none`.
    pub kind: String,
    /// True only when a real (execute) build can run on this host.
    pub available: bool,
    /// `std::env::consts::OS`, for example `macos`, `linux`, or `windows`.
    pub platform: String,
    /// Human-readable explanation shown by the UI when `available` is false.
    pub reason: String,
    /// `docker` or `podman` for a container engine; `null` otherwise.
    pub runtime: Option<String>,
    /// Engine image reference for a container engine; `null` otherwise.
    pub image: Option<String>,
    /// Whether the engine image exists locally once a container daemon answered;
    /// `null` when no container runtime was probed.
    pub image_present: Option<bool>,
}

/// One probe result: the public [`EngineInfo`] plus the executable the build
/// layer must invoke when the engine is a container runtime.
///
/// The executable is kept out of [`EngineInfo`] because it is a host path that
/// has no business in the UI wire format.
#[derive(Debug, Clone)]
pub(crate) struct EngineProbe {
    pub(crate) info: EngineInfo,
    pub(crate) runtime_path: Option<PathBuf>,
}

/// Environment snapshot for one probe, so tests never mutate process state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct EngineEnv {
    pub(crate) image: String,
    pub(crate) runtime_override: Option<PathBuf>,
}

impl EngineEnv {
    fn from_process() -> Self {
        let image = env::var(ENGINE_IMAGE_ENV)
            .ok()
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| DEFAULT_ENGINE_IMAGE.to_string());
        let runtime_override = env::var_os(ENGINE_RUNTIME_ENV)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        Self {
            image,
            runtime_override,
        }
    }
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
    // A usable host builder wins unconditionally; do not pay for docker probes.
    let probes = if matches!(local, LocalProbe::Available(_)) {
        Vec::new()
    } else {
        probe_container_runtimes(env, timeout)
    };
    classify_engine(platform, &env.image, local, &probes)
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

/// Classification of the probe results; pure so every branch is unit-tested
/// without a docker daemon.
fn classify_engine(
    platform: &str,
    image: &str,
    local: LocalProbe,
    probes: &[RuntimeProbe],
) -> EngineProbe {
    if let LocalProbe::Available(info) = local {
        return EngineProbe {
            info,
            runtime_path: None,
        };
    }

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
                    format!("container engine: {} {version} · image {image}", probe.name),
                ),
                runtime_path: Some(probe.executable.clone()),
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
                    format!(
                        "container engine: {} {version} · image {image} not found{note}; build it with {BUILD_IMAGE_SCRIPT}",
                        probe.name
                    ),
                ),
                runtime_path: None,
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
            reason: no_engine_reason(platform, local_note, probes),
            runtime: None,
            image: None,
            image_present: None,
        },
        runtime_path: None,
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

fn no_engine_reason(platform: &str, local_note: Option<&str>, probes: &[RuntimeProbe]) -> String {
    let mut details: Vec<String> = Vec::new();
    if let Some(note) = local_note {
        details.push(note.to_string());
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

    #[test]
    fn engine_info_reports_the_host_capability() {
        let info = engine_info().expect("the local engine probe cannot fail");

        assert!(!info.platform.is_empty(), "platform must not be empty");
        assert!(!info.reason.trim().is_empty(), "reason must never be empty");
        assert!(
            ["local", "container", "none"].contains(&info.kind.as_str()),
            "unexpected engine kind: {}",
            info.kind
        );

        match info.kind.as_str() {
            "local" => {
                assert!(info.available, "kind local must be available");
                assert!(info.runtime.is_none());
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
            &[runtime("docker", reachable("29.1.2", true))],
        );

        assert_eq!(probe.info.kind, "local");
        assert!(probe.info.available);
        assert!(probe.runtime_path.is_none());
    }

    #[test]
    fn classification_accepts_a_container_with_the_image() {
        let probe = classify_engine(
            "macos",
            image(),
            LocalProbe::NotApplicable,
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
            image: image().to_string(),
            runtime_override: Some(runtime_path),
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
            image: "sysemble-engine:test".to_string(),
            runtime_override: Some(runtime_path.clone()),
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
            image: image().to_string(),
            runtime_override: Some(runtime_path),
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
            image: image().to_string(),
            runtime_override: Some(runtime_path),
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
