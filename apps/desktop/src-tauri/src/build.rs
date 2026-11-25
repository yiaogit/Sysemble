//! Build execution for the Sysemble desktop shell (P1-b/P1-e2).
//!
//! A [`BuildManager`] owns every build started by this process. A build is a
//! child process whose combined stdout/stderr is redirected to `<out>/build.log`.
//! A supervisor thread blocks in [`std::process::Child::wait`] and publishes the
//! terminal state, while cancellation signals the builder's process group. The
//! supervisor therefore never holds the registry lock while waiting, and
//! cancellation never blocks on a running build.
//!
//! P1-e2 adds the container backend: `--execute` runs the same
//! `builders/debian/build.sh` inside the engine image with
//! `<runtime> run --rm --init --privileged --platform linux/amd64 ...`, while
//! `--dry-run` keeps running the builder directly on the host. The frozen
//! parameter order lives in `docs/plan/P1-e2-workplan.md` §2.3 and in
//! [`container_invocation`].
//!
//! The command layer lives in `lib.rs`; this module is plain Rust so the
//! lifecycle can be tested without a WebView.

use std::collections::HashMap;
use std::ffi::OsString;
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
#[cfg(unix)]
use std::time::{Duration, Instant};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use sysemble_core::{load_spec, resolve_plan};

use crate::engine::{self, EngineInfo, EngineProbe, VmHandle};
use crate::{repo_root, resolve_path};

/// Log lines returned by [`BuildManager::get_build_log`] when the caller does
/// not request a specific count.
pub const DEFAULT_LOG_TAIL_LINES: u32 = 200;

/// Registry shared by the command layer and the supervisor threads.
type Registry = Arc<Mutex<HashMap<String, BuildRecord>>>;

/// Resolves the engine for a build. Production probes the host every time, so
/// a daemon that starts after the window opened is picked up on the next build.
type EngineResolver = Arc<dyn Fn() -> EngineProbe + Send + Sync>;

/// Target platform of the engine image (frozen by the P1-e2 workplan).
const CONTAINER_PLATFORM: &str = "linux/amd64";

/// Container entry point (v2): runs inside the image, builds on the container's
/// case-sensitive filesystem, and exports only the top-level artifacts.
const CONTAINER_ENTRY_SCRIPT: &str = "engine/runtime/container-entry.sh";

/// Guest job timeout passed to the VM helper (P1-e3/P1-e4 workplan §2.3).
const VM_BUILD_TIMEOUT_SECONDS: &str = "1800";

/// How long a cancelled process group gets to handle SIGTERM (the macOS VM
/// helper stops the VM and exits 143) before it is killed outright.
#[cfg(unix)]
const CANCEL_TERM_GRACE: Duration = Duration::from_secs(20);

/// Poll interval of the SIGTERM→SIGKILL escalation watchdog.
#[cfg(unix)]
const CANCEL_WATCHDOG_INTERVAL: Duration = Duration::from_millis(100);

static NEXT_BUILD_ID: AtomicU64 = AtomicU64::new(1);

/// Lifecycle of a desktop-started build.
///
/// `Cancelled` is terminal: a cancelled build is never reported as `Failed`
/// even though the killed child has no normal exit code.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BuildState {
    Running,
    Exited,
    Failed,
    Cancelled,
}

impl BuildState {
    /// Lower-case wire name, also used in human-readable error messages.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Running => "running",
            Self::Exited => "exited",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }
}

/// Returned by `start_build`: everything the UI needs to poll and display the
/// new build. Paths are absolute so they stay valid regardless of the process
/// working directory.
#[derive(Debug, Clone, Serialize)]
pub struct BuildStarted {
    pub id: String,
    pub plan_path: String,
    pub log_path: String,
}

/// Returned by `get_build`.
#[derive(Debug, Clone, Serialize)]
pub struct BuildStatus {
    pub state: BuildState,
    pub exit_code: Option<i32>,
    pub started_at: String,
    pub finished_at: Option<String>,
}

/// Build mode accepted by `start_build`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BuildMode {
    DryRun,
    Execute,
}

impl BuildMode {
    fn parse(mode: &str) -> Result<Self, String> {
        match mode {
            "dry-run" => Ok(Self::DryRun),
            "execute" => Ok(Self::Execute),
            other => Err(format!(
                "invalid build mode `{other}`: expected `dry-run` or `execute`"
            )),
        }
    }

    fn flag(self) -> &'static str {
        match self {
            Self::DryRun => "--dry-run",
            Self::Execute => "--execute",
        }
    }
}

/// Which launch path an execute build takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ExecutionBackend {
    /// P1-b host builder: `bash <builder> --plan … --out … --execute`.
    Host,
    /// Engine image: `<runtime> run … bash <builder> …`.
    Container,
    /// macOS Virtualization.framework: `<helper> run --image-dir … --repo …`.
    Vm,
}

/// Pick the launch path from the probed engine.
///
/// A `local` engine already means "root and the builder tools are on this
/// host", so it keeps the P1-b host path and never needs a runtime executable.
/// `container` runs inside docker/podman; `vm` runs through the signed
/// Virtualization.framework helper. `None` means no probe was taken (dry run or
/// the `SYMBLE_BUILDER` hook) and also uses the host path.
fn execution_backend(probe: Option<&EngineProbe>) -> Result<ExecutionBackend, String> {
    match probe {
        None => Ok(ExecutionBackend::Host),
        Some(probe) => match probe.info.kind.as_str() {
            "local" => Ok(ExecutionBackend::Host),
            "container" => Ok(ExecutionBackend::Container),
            "vm" if probe.info.available => Ok(ExecutionBackend::Vm),
            // An unavailable engine is gated in `start_build`; keeping the
            // readable reason here makes the helper safe to call directly.
            "vm" => Err(unavailable_engine_error(&probe.info)),
            other => Err(format!("engine kind `{other}` cannot run execute builds")),
        },
    }
}

/// One entry in the build registry.
struct BuildRecord {
    state: BuildState,
    exit_code: Option<i32>,
    started_at: String,
    finished_at: Option<String>,
    log_path: PathBuf,
    /// Builder process id, kept for cancellation.
    pid: u32,
    /// Container this build runs in, when the engine is a container runtime.
    container: Option<ContainerHandle>,
    /// The child is claimed by the supervisor thread for `wait()`. It is put
    /// back once the process has been reaped so the record keeps its handle.
    child: Option<Child>,
}

/// Identifies the container a build started so cancellation can kill it.
///
/// Killing the `docker run` client does not necessarily stop the container it
/// created, so the daemon-side container is killed by name as well.
#[derive(Debug, Clone)]
struct ContainerHandle {
    runtime: PathBuf,
    name: String,
}

/// Everything needed to launch a containerized builder.
#[derive(Debug, Clone, PartialEq, Eq)]
struct ContainerInvocation {
    program: PathBuf,
    args: Vec<OsString>,
    name: String,
}

/// Everything needed to launch the macOS VM helper.
#[derive(Debug, Clone, PartialEq, Eq)]
struct VmInvocation {
    program: PathBuf,
    args: Vec<OsString>,
}

/// Owns the builds started by this desktop process.
///
/// The registry is an `Arc<Mutex<HashMap<...>>>` shared with the supervisor
/// threads. A separate cancellation gate serialises cancellation against the
/// supervisor's final state update: a build can never be reported as `failed`
/// after a successful cancel, and a failed cancel cannot be hidden by a
/// concurrent natural exit.
pub struct BuildManager {
    registry: Registry,
    cancel_gate: Arc<Mutex<()>>,
    /// Resolved on every execute build; dry runs never consult it.
    engine: EngineResolver,
    /// Repository shared with the engine. Production uses [`repo_root`]; tests
    /// inject a temporary repository.
    repo: PathBuf,
}

impl Default for BuildManager {
    fn default() -> Self {
        Self::with_engine_resolver(Arc::new(engine::probe_engine))
    }
}

impl BuildManager {
    pub fn new() -> Self {
        Self::default()
    }

    /// Build a manager around an explicit engine resolver.
    ///
    /// Production uses [`engine::probe_engine`]; tests inject a fixed probe so
    /// the execute gate and the container argv can be asserted without a
    /// docker daemon.
    fn with_engine_resolver(resolver: EngineResolver) -> Self {
        Self::with_repo(resolver, repo_root())
    }

    fn with_repo(resolver: EngineResolver, repo: PathBuf) -> Self {
        Self {
            registry: Arc::new(Mutex::new(HashMap::new())),
            cancel_gate: Arc::new(Mutex::new(())),
            engine: resolver,
            repo,
        }
    }

    /// Test/harness constructor: always resolve to the given probe.
    #[cfg(test)]
    fn with_engine_probe(probe: EngineProbe) -> Self {
        Self::with_engine_resolver(Arc::new(move || probe.clone()))
    }

    /// Test/harness constructor: fixed probe plus an injected repository root.
    #[cfg(test)]
    fn with_engine_probe_and_repo(probe: EngineProbe, repo: PathBuf) -> Self {
        Self::with_repo(Arc::new(move || probe.clone()), repo)
    }

    fn lock(&self) -> Result<MutexGuard<'_, HashMap<String, BuildRecord>>, String> {
        self.registry
            .lock()
            .map_err(|_| "the build registry lock is poisoned".to_string())
    }

    /// Start a builder for `spec_path`, writing the resolved plan and the
    /// combined log under `out_dir`.
    ///
    /// `mode` is `"dry-run"` or `"execute"`. The builder is always launched
    /// with argument arrays (never a shell string), so paths containing spaces
    /// need no quoting.
    pub fn start_build(
        &self,
        spec_path: &str,
        out_dir: &str,
        mode: &str,
    ) -> Result<BuildStarted, String> {
        let mode = BuildMode::parse(mode)?;

        let resolved_spec = resolve_path(spec_path);
        let spec = load_spec(&resolved_spec)
            .map_err(|error| format!("cannot load spec `{spec_path}`: {error}"))?;
        let plan = resolve_plan(&spec)
            .map_err(|error| format!("cannot plan spec `{spec_path}`: {error}"))?;

        let builder = builder_path()?;

        // `SYMBLE_BUILDER` is the P1-b test/builder-replacement hook: when it
        // is set, both modes run that script directly on the host and the
        // engine gate is skipped, so the cancellation tests keep working
        // without a container runtime.
        let builder_override = std::env::var_os("SYMBLE_BUILDER").is_some();

        // Gate execute builds on a usable engine before writing any output.
        let engine_probe = if mode == BuildMode::Execute && !builder_override {
            let probe = (self.engine)();
            if !probe.info.available {
                return Err(unavailable_engine_error(&probe.info));
            }
            Some(probe)
        } else {
            None
        };

        // A `local` engine keeps the P1-b host path; a container engine launches
        // a runtime and a vm engine launches the signed helper, so each backend
        // only requires its own host resources.
        let backend = execution_backend(engine_probe.as_ref())?;

        let vm_handle: Option<VmHandle> = match backend {
            ExecutionBackend::Vm => {
                let handle = engine_probe
                    .as_ref()
                    .and_then(|probe| probe.vm.clone())
                    .ok_or_else(|| {
                        "the vm engine did not report a helper and image directory".to_string()
                    })?;
                // The probe validated both paths moments ago; re-check before
                // any output is written so a concurrent uninstall is readable.
                if !handle.helper.is_file() {
                    return Err(format!(
                        "cannot run an execute build: the VM helper `{}` is missing; re-probe the engine (build it with bash {})",
                        handle.helper.display(),
                        engine::VM_HELPER_SCRIPT
                    ));
                }
                if !handle.image_dir.is_dir() {
                    return Err(format!(
                        "cannot run an execute build: the VM image directory `{}` is missing; build it with {}",
                        handle.image_dir.display(),
                        engine::VM_IMAGE_SCRIPT
                    ));
                }
                // `--image-dir`/`--repo`/`--out` are frozen as absolute paths.
                let handle = VmHandle {
                    helper: fs::canonicalize(&handle.helper).unwrap_or(handle.helper),
                    image_dir: fs::canonicalize(&handle.image_dir)
                        .unwrap_or(handle.image_dir),
                };
                Some(handle)
            }
            ExecutionBackend::Host | ExecutionBackend::Container => None,
        };

        // Engine builds share the canonical repository root; the container also
        // needs its v2 entry script inside that repository. Validate everything
        // before writing output or spawning anything.
        let repo_abs = match backend {
            ExecutionBackend::Container | ExecutionBackend::Vm => {
                let repo = fs::canonicalize(&self.repo).map_err(|error| {
                    format!("cannot resolve the repository root for an engine build: {error}")
                })?;
                if backend == ExecutionBackend::Container {
                    container_entry_script(&repo)?;
                } else {
                    vm_repo_inputs(&repo)?;
                }
                Some(repo)
            }
            ExecutionBackend::Host => None,
        };

        fs::create_dir_all(out_dir)
            .map_err(|error| format!("cannot create output directory `{out_dir}`: {error}"))?;
        let out_abs = fs::canonicalize(out_dir)
            .map_err(|error| format!("cannot resolve output directory `{out_dir}`: {error}"))?;
        let plan_path = out_abs.join("plan.json");
        let log_path = out_abs.join("build.log");

        let plan_json = serde_json::to_string_pretty(&plan)
            .map_err(|error| format!("cannot serialise the build plan: {error}"))?;
        fs::write(&plan_path, format!("{plan_json}\n"))
            .map_err(|error| format!("cannot write plan `{}`: {error}", plan_path.display()))?;

        let log = File::create(&log_path).map_err(|error| {
            format!("cannot create build log `{}`: {error}", log_path.display())
        })?;
        let stderr_log = log.try_clone().map_err(|error| {
            format!(
                "cannot open build log `{}` for stderr: {error}",
                log_path.display()
            )
        })?;

        // The id is generated before the launch so container builds can use it
        // in `--name sysemble-build-<id>`.
        let id = next_build_id();

        let (mut command, container) = match backend {
            ExecutionBackend::Container => {
                let probe = engine_probe.as_ref().ok_or_else(|| {
                    "the container engine did not report a runtime executable".to_string()
                })?;
                let runtime = probe.runtime_path.clone().ok_or_else(|| {
                    "the container engine did not report a runtime executable".to_string()
                })?;
                let image = probe
                    .info
                    .image
                    .as_deref()
                    .unwrap_or(engine::DEFAULT_ENGINE_IMAGE);
                let repo = repo_abs
                    .as_deref()
                    .ok_or_else(|| "the container build has no repository root".to_string())?;
                let invocation = container_invocation(&runtime, image, &id, repo, &out_abs)?;
                let mut command = Command::new(&invocation.program);
                command.args(&invocation.args);
                let handle = ContainerHandle {
                    runtime: invocation.program.clone(),
                    name: invocation.name.clone(),
                };
                (command, Some(handle))
            }
            ExecutionBackend::Vm => {
                let vm = vm_handle
                    .as_ref()
                    .ok_or_else(|| "the vm build has no helper".to_string())?;
                let repo = repo_abs
                    .as_deref()
                    .ok_or_else(|| "the vm build has no repository root".to_string())?;
                // Frozen argv (P1-e4 workplan §2.3): helper stdout/stderr are
                // the build log, and the helper exits with the guest's code.
                let invocation = vm_invocation(&vm.helper, &vm.image_dir, repo, &out_abs);
                let mut command = Command::new(&invocation.program);
                command.args(&invocation.args);
                (command, None)
            }
            ExecutionBackend::Host => {
                let mut command = Command::new("bash");
                command
                    .arg(&builder)
                    .arg("--plan")
                    .arg(&plan_path)
                    .arg("--out")
                    .arg(&out_abs)
                    .arg(mode.flag());
                (command, None)
            }
        };

        command
            .stdin(Stdio::null())
            .stdout(Stdio::from(log))
            .stderr(Stdio::from(stderr_log));
        configure_process_group(&mut command);

        let child = command.spawn().map_err(|error| {
            if let Some(handle) = &container {
                return format!(
                    "cannot start the container runtime `{}`: {error}",
                    handle.runtime.display()
                );
            }
            if let Some(vm) = &vm_handle {
                return format!(
                    "cannot start the VM helper `{}`: {error}",
                    vm.helper.display()
                );
            }
            format!("cannot start builder `{}` with bash: {error}", builder.display())
        })?;
        let pid = child.id();
        let started_at = now_iso8601();

        let record = BuildRecord {
            state: BuildState::Running,
            exit_code: None,
            started_at,
            finished_at: None,
            log_path: log_path.clone(),
            pid,
            container,
            child: Some(child),
        };

        self.lock()?.insert(id.clone(), record);

        let registry = Arc::clone(&self.registry);
        let cancel_gate = Arc::clone(&self.cancel_gate);
        let supervisor_id = id.clone();
        let spawned = thread::Builder::new()
            .name(format!("sysemble-build-{id}"))
            .spawn(move || supervise(registry, cancel_gate, supervisor_id));

        if let Err(error) = spawned {
            if let Ok(mut registry) = self.registry.lock() {
                if let Some(mut record) = registry.remove(&id) {
                    if let Some(mut child) = record.child.take() {
                        let _ = child.kill();
                        let _ = child.wait();
                    }
                }
            }
            return Err(format!("cannot start the build supervisor: {error}"));
        }

        Ok(BuildStarted {
            id,
            plan_path: plan_path.display().to_string(),
            log_path: log_path.display().to_string(),
        })
    }

    /// Snapshot the state of `id`.
    pub fn get_build(&self, id: &str) -> Result<BuildStatus, String> {
        let registry = self.lock()?;
        let record = registry.get(id).ok_or_else(|| unknown_build(id))?;
        Ok(BuildStatus {
            state: record.state,
            exit_code: record.exit_code,
            started_at: record.started_at.clone(),
            finished_at: record.finished_at.clone(),
        })
    }

    /// Return the last `tail_lines` lines of the build log.
    ///
    /// The file is read backwards in chunks so a large `--execute` log is never
    /// loaded in full just to show its tail. `None` means
    /// [`DEFAULT_LOG_TAIL_LINES`]; `Some(0)` returns an empty string.
    pub fn get_build_log(&self, id: &str, tail_lines: Option<u32>) -> Result<String, String> {
        let log_path = {
            let registry = self.lock()?;
            registry
                .get(id)
                .ok_or_else(|| unknown_build(id))?
                .log_path
                .clone()
        };

        let lines = tail_lines.unwrap_or(DEFAULT_LOG_TAIL_LINES) as usize;
        read_tail(&log_path, lines)
            .map_err(|error| format!("cannot read build log `{}`: {error}", log_path.display()))
    }

    /// Kill the builder process group and mark the build cancelled.
    ///
    /// Returns an error (and leaves the record running) when the process has
    /// already exited or cannot be signalled.
    pub fn cancel_build(&self, id: &str) -> Result<(), String> {
        // Holding the gate until the state update is published keeps the
        // supervisor from finalising the build between the kill and the
        // update, which would otherwise turn a successful cancel into
        // `failed` depending on thread scheduling.
        let _gate = self
            .cancel_gate
            .lock()
            .map_err(|_| "the build cancellation lock is poisoned".to_string())?;

        let (pid, container) = {
            let registry = self.lock()?;
            let record = registry.get(id).ok_or_else(|| unknown_build(id))?;
            if record.state != BuildState::Running {
                return Err(format!(
                    "build `{id}` is not running (state: {})",
                    record.state.as_str()
                ));
            }
            (record.pid, record.container.clone())
        };

        let group_result = terminate_process_group(pid);

        // Killing the `docker run` client does not reliably stop the container
        // it created, so ask the runtime to kill it by name as well. This is
        // best effort: a runtime that vanished or a container that already
        // exited must not fail the cancellation.
        if let Some(container) = container {
            kill_container(&container);
        }

        group_result.map_err(|error| format!("cannot cancel build `{id}`: {error}"))?;

        let mut registry = self.lock()?;
        if let Some(record) = registry.get_mut(id) {
            if record.state == BuildState::Running {
                record.state = BuildState::Cancelled;
                record.exit_code = None;
                record.finished_at = Some(now_iso8601());
            }
        }
        Ok(())
    }
}

/// Reap the child and publish the terminal state.
fn supervise(registry: Registry, cancel_gate: Arc<Mutex<()>>, id: String) {
    let child = {
        let mut registry = match registry.lock() {
            Ok(registry) => registry,
            Err(_) => return,
        };
        registry.get_mut(&id).and_then(|record| record.child.take())
    };
    let Some(mut child) = child else {
        return;
    };

    let status = child.wait();
    let finished_at = now_iso8601();

    // Take the cancellation gate so a concurrent cancel either completes its
    // state update before we look at the record, or sees a terminal record.
    let _gate = cancel_gate.lock().ok();
    let mut registry = match registry.lock() {
        Ok(registry) => registry,
        Err(_) => return,
    };
    let Some(record) = registry.get_mut(&id) else {
        return;
    };
    record.child = Some(child);

    if record.state == BuildState::Cancelled {
        // Cancel already published the terminal status; do not overwrite it
        // with the signal-derived exit status of the killed process.
        record.finished_at.get_or_insert(finished_at);
        return;
    }

    record.finished_at = Some(finished_at);
    match status {
        Ok(status) => {
            record.exit_code = status.code();
            record.state = if status.success() {
                BuildState::Exited
            } else {
                BuildState::Failed
            };
        }
        Err(_) => {
            record.exit_code = None;
            record.state = BuildState::Failed;
        }
    }
}

fn unknown_build(id: &str) -> String {
    format!("unknown build `{id}`")
}

fn next_build_id() -> String {
    let sequence = NEXT_BUILD_ID.fetch_add(1, Ordering::Relaxed);
    format!("build-{}-{sequence}", std::process::id())
}

/// Resolve the builder script. `SYMBLE_BUILDER` wins so tests can substitute a
/// fake builder; setting it also bypasses the P1-e2 engine gate (both modes run
/// the host script), which keeps the P1-b cancellation test engine-free.
/// Otherwise the script lives at the repository root next to the desktop app.
fn builder_path() -> Result<PathBuf, String> {
    if let Some(raw) = std::env::var_os("SYMBLE_BUILDER") {
        let path = PathBuf::from(raw);
        if path.is_file() {
            return Ok(path);
        }
        return Err(format!(
            "SYMBLE_BUILDER points at `{}`, which is not a file",
            path.display()
        ));
    }

    let from_repo = repo_root().join("builders/debian/build.sh");
    if from_repo.is_file() {
        return Ok(from_repo);
    }

    if let Ok(cwd) = std::env::current_dir() {
        let from_cwd = cwd.join("builders/debian/build.sh");
        if from_cwd.is_file() {
            return Ok(from_cwd);
        }
    }

    Err(format!(
        "cannot find the Debian builder at `{}`; set SYMBLE_BUILDER to override it",
        from_repo.display()
    ))
}

/// Readable error for an execute build when no engine can run it.
fn unavailable_engine_error(info: &EngineInfo) -> String {
    format!(
        "cannot start an execute build: {} (engine kind: {}); use --dry-run to validate the plan on this host",
        info.reason, info.kind
    )
}

/// Resolve the v2 container entry script inside `repo` and require it to exist.
///
/// The argv passes the script as the repository-relative path
/// [`CONTAINER_ENTRY_SCRIPT`], so the script must live inside the repository
/// that gets mounted at `/work`.
fn container_entry_script(repo: &Path) -> Result<PathBuf, String> {
    let script = repo.join(CONTAINER_ENTRY_SCRIPT);
    if script.is_file() {
        Ok(script)
    } else {
        Err(format!(
            "cannot find the engine entry script `{CONTAINER_ENTRY_SCRIPT}` in the repository `{}`; container builds mount the repository read-only at /work",
            repo.display()
        ))
    }
}

/// Guest-side script the VM helper's fixed job runs inside the VM.
const VM_GUEST_SCRIPT: &str = "engine/vm/guest/minimal-build.sh";

/// Require the repository inputs the VM helper needs before booting.
///
/// The helper shares the repository read-only at `/work` and its frozen job
/// runs [`VM_GUEST_SCRIPT`]; failing here keeps the output directory untouched.
fn vm_repo_inputs(repo: &Path) -> Result<(), String> {
    for relative in ["builders/debian/build.sh", VM_GUEST_SCRIPT] {
        let path = repo.join(relative);
        if !path.is_file() {
            return Err(format!(
                "cannot find `{relative}` in the repository `{}`; VM builds share the repository read-only at /work",
                repo.display()
            ));
        }
    }
    Ok(())
}

/// Build the frozen VM helper argv (P1-e4 workplan §2.3).
///
/// `image_dir`, `repo`, and `out` must be canonical absolute host paths. The
/// helper shares the repository read-only at `/work` and the output directory
/// at `/export`, and only copies the plan when `--plan` names a different file;
/// pointing it at the `<out>/plan.json` BuildManager wrote is therefore
/// idempotent (Runner.swift).
fn vm_invocation(helper: &Path, image_dir: &Path, repo: &Path, out: &Path) -> VmInvocation {
    let plan = out.join("plan.json");
    let args: Vec<OsString> = vec![
        OsString::from("run"),
        OsString::from("--image-dir"),
        image_dir.as_os_str().to_os_string(),
        OsString::from("--repo"),
        repo.as_os_str().to_os_string(),
        OsString::from("--out"),
        out.as_os_str().to_os_string(),
        OsString::from("--plan"),
        plan.as_os_str().to_os_string(),
        OsString::from("--timeout"),
        OsString::from(VM_BUILD_TIMEOUT_SECONDS),
        OsString::from("--json"),
    ];
    VmInvocation {
        program: helper.to_path_buf(),
        args,
    }
}

/// Build the frozen v2 container argv (P1-e2 workplan §2.3).
///
/// `repo` and `out` must be canonical absolute host paths. The repository is
/// mounted read-only at `/work`; the host output directory is mounted at
/// `/export`. The container builds on its own case-sensitive filesystem under
/// `/out` (macOS APFS would otherwise turn case-only path pairs into ELOOP) and
/// exports only top-level artifacts to `/export`.
fn container_invocation(
    runtime: &Path,
    image: &str,
    build_id: &str,
    repo: &Path,
    out: &Path,
) -> Result<ContainerInvocation, String> {
    let name = format!("sysemble-build-{build_id}");

    let mut args: Vec<OsString> = [
        "run",
        "--rm",
        "--init",
        "--privileged",
        "--platform",
        CONTAINER_PLATFORM,
        "--name",
    ]
    .into_iter()
    .map(OsString::from)
    .collect();
    args.push(OsString::from(&name));

    let mut repo_mount = repo.as_os_str().to_os_string();
    repo_mount.push(":/work:ro");
    args.push(OsString::from("-v"));
    args.push(repo_mount);

    let mut export_mount = out.as_os_str().to_os_string();
    export_mount.push(":/export");
    args.push(OsString::from("-v"));
    args.push(export_mount);

    args.push(OsString::from("-w"));
    args.push(OsString::from("/work"));
    args.push(OsString::from(image));
    args.push(OsString::from("bash"));
    args.push(OsString::from(CONTAINER_ENTRY_SCRIPT));
    args.push(OsString::from("--plan"));
    args.push(OsString::from("/export/plan.json"));
    args.push(OsString::from("--out"));
    args.push(OsString::from("/out"));
    args.push(OsString::from("--export"));
    args.push(OsString::from("/export"));
    args.push(OsString::from("--mode"));
    args.push(OsString::from("execute"));

    Ok(ContainerInvocation {
        program: runtime.to_path_buf(),
        args,
        name,
    })
}

/// Ask the container runtime to kill `container`, without blocking the caller.
fn kill_container(container: &ContainerHandle) {
    let mut command = Command::new(&container.runtime);
    command
        .arg("kill")
        .arg(&container.name)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let Ok(mut child) = command.spawn() else {
        return;
    };
    // Reap on a helper thread: cancellation must never wait on the runtime.
    let _ = thread::Builder::new()
        .name("sysemble-container-kill".to_string())
        .spawn(move || {
            let _ = child.wait();
        });
}

#[cfg(unix)]
fn configure_process_group(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    // The builder becomes its own process-group leader so cancellation can
    // signal the whole tree (mmdebstrap, xorriso, ...), not just bash.
    command.process_group(0);
}

#[cfg(not(unix))]
fn configure_process_group(_command: &mut Command) {}

#[cfg(unix)]
fn terminate_process_group(pid: u32) -> Result<(), String> {
    // The macOS VM helper catches SIGTERM, stops the Virtualization.framework
    // VM and exits 143 (P1-e3), so SIGTERM is the graceful first step for every
    // backend. A watchdog escalates to SIGKILL if the group ignores it, keeping
    // P1-b's guarantee that a cancelled build cannot keep running forever.
    signal_process_group(pid, libc::SIGTERM)?;
    spawn_cancel_watchdog(pid);
    Ok(())
}

#[cfg(unix)]
fn signal_process_group(pid: u32, signal: i32) -> Result<(), String> {
    // A negative pid signals the process group led by the builder.
    let result = unsafe { libc::kill(-(pid as i32), signal) };
    if result == 0 {
        return Ok(());
    }

    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        return Err("the builder process has already exited".to_string());
    }
    Err(error.to_string())
}

/// True while any process in the build's process group still exists.
#[cfg(unix)]
fn process_group_exists(pid: u32) -> bool {
    let result = unsafe { libc::kill(-(pid as i32), 0) };
    result == 0 || io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

/// Escalate a SIGTERM cancellation to SIGKILL after [`CANCEL_TERM_GRACE`].
///
/// Runs on its own thread so `cancel_build` never blocks on a helper that is
/// shutting a VM down; the group is gone long before the grace expires in the
/// normal case.
#[cfg(unix)]
fn spawn_cancel_watchdog(pid: u32) {
    let _ = thread::Builder::new()
        .name("sysemble-cancel-kill".to_string())
        .spawn(move || {
            let deadline = Instant::now() + CANCEL_TERM_GRACE;
            while process_group_exists(pid) {
                if Instant::now() >= deadline {
                    let _ = signal_process_group(pid, libc::SIGKILL);
                    return;
                }
                thread::sleep(CANCEL_WATCHDOG_INTERVAL);
            }
        });
}

#[cfg(windows)]
fn terminate_process_group(pid: u32) -> Result<(), String> {
    let status = Command::new("taskkill")
        .args(["/PID", &pid.to_string(), "/T", "/F"])
        .status()
        .map_err(|error| format!("cannot run taskkill: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("taskkill exited with {status}"))
    }
}

#[cfg(not(any(unix, windows)))]
fn terminate_process_group(_pid: u32) -> Result<(), String> {
    Err("build cancellation is not supported on this platform".to_string())
}

/// Read the last `max_lines` lines of a file without loading it all.
fn read_tail(path: &Path, max_lines: usize) -> io::Result<String> {
    if max_lines == 0 {
        return Ok(String::new());
    }

    let mut file = File::open(path)?;
    let length = file.metadata()?.len();
    if length == 0 {
        return Ok(String::new());
    }

    // A trailing newline terminates the last line instead of starting an empty
    // one, matching `tail -n`: it must not consume one of the requested lines.
    let mut end = length;
    let mut last = [0u8; 1];
    file.seek(SeekFrom::Start(length - 1))?;
    file.read_exact(&mut last)?;
    if last[0] == b'\n' {
        end -= 1;
    }

    let mut start = 0;
    let mut newlines = 0usize;
    let mut position = end;
    let mut chunk = [0u8; 8192];
    'scan: while position > 0 {
        let take = position.min(chunk.len() as u64) as usize;
        position -= take as u64;
        file.seek(SeekFrom::Start(position))?;
        file.read_exact(&mut chunk[..take])?;
        for index in (0..take).rev() {
            if chunk[index] == b'\n' {
                newlines += 1;
                if newlines == max_lines {
                    start = position + index as u64 + 1;
                    break 'scan;
                }
            }
        }
    }

    let remaining = length - start;
    if remaining == 0 {
        return Ok(String::new());
    }

    file.seek(SeekFrom::Start(start))?;
    let mut bytes = Vec::new();
    file.take(remaining).read_to_end(&mut bytes)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

fn now_iso8601() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_secs());
    format_utc(seconds)
}

/// Format Unix seconds as `YYYY-MM-DDTHH:MM:SSZ` without a date dependency.
fn format_utc(seconds: u64) -> String {
    let days = (seconds / 86_400) as i64;
    let remainder = seconds % 86_400;
    let (year, month, day) = civil_from_days(days);
    let hour = remainder / 3_600;
    let minute = (remainder % 3_600) / 60;
    let second = remainder % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}Z")
}

/// Howard Hinnant's days-to-civil algorithm (proleptic Gregorian).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let shifted = days + 719_468;
    let era = if shifted >= 0 {
        shifted
    } else {
        shifted - 146_096
    } / 146_097;
    let day_of_era = shifted - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = if month_prime < 10 {
        month_prime + 3
    } else {
        month_prime - 9
    };
    let year = if month <= 2 { year + 1 } else { year };
    (year, month as u32, day as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn repo_root_for_tests() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
    }

    fn example(name: &str) -> PathBuf {
        repo_root_for_tests().join("examples").join(name)
    }

    fn as_str(path: &Path) -> String {
        path.to_string_lossy().into_owned()
    }

    /// Per-test directory keyed by pid so tests can run in parallel.
    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new(tag: &str) -> Self {
            let path =
                std::env::temp_dir().join(format!("sysemble-desktop-{tag}-{}", std::process::id()));
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

    fn wait_for_terminal(manager: &BuildManager, id: &str, timeout: Duration) -> BuildStatus {
        let deadline = Instant::now() + timeout;
        loop {
            let status = manager.get_build(id).expect("build should be registered");
            if status.state != BuildState::Running {
                return status;
            }
            assert!(
                Instant::now() < deadline,
                "build `{id}` was still running after {timeout:?}"
            );
            thread::sleep(Duration::from_millis(50));
        }
    }

    fn engine_probe(kind: &str, available: bool, reason: &str) -> EngineProbe {
        EngineProbe {
            info: EngineInfo {
                kind: kind.to_string(),
                available,
                platform: std::env::consts::OS.to_string(),
                reason: reason.to_string(),
                runtime: None,
                image: None,
                image_present: None,
            },
            runtime_path: None,
            vm: None,
        }
    }

    fn container_probe(runtime: &Path) -> EngineProbe {
        EngineProbe {
            info: EngineInfo {
                kind: "container".to_string(),
                available: true,
                platform: std::env::consts::OS.to_string(),
                reason: format!(
                    "container engine: docker 9.9.9 · image {}",
                    engine::DEFAULT_ENGINE_IMAGE
                ),
                runtime: Some("docker".to_string()),
                image: Some(engine::DEFAULT_ENGINE_IMAGE.to_string()),
                image_present: Some(true),
            },
            runtime_path: Some(runtime.to_path_buf()),
            vm: None,
        }
    }

    /// A fixed `vm` probe with the given helper and image directory.
    fn vm_probe(helper: &Path, image_dir: &Path) -> EngineProbe {
        EngineProbe {
            info: EngineInfo {
                kind: "vm".to_string(),
                available: true,
                platform: std::env::consts::OS.to_string(),
                reason: "vm engine: sysemble-vm 0.1.0 · helper signed · image arm64".to_string(),
                runtime: None,
                image: Some("sysemble-vm:0.1.0".to_string()),
                image_present: Some(true),
            },
            runtime_path: None,
            vm: Some(VmHandle {
                helper: helper.to_path_buf(),
                image_dir: image_dir.to_path_buf(),
            }),
        }
    }

    /// A minimal repository shape with every input a VM build needs.
    fn fake_vm_repo(tag: &str) -> (TempDir, PathBuf) {
        let repo = TempDir::new(tag);
        for relative in [
            "builders/debian/build.sh",
            VM_GUEST_SCRIPT,
            CONTAINER_ENTRY_SCRIPT,
        ] {
            let path = repo.path.join(relative);
            fs::create_dir_all(path.parent().expect("script path should have a parent"))
                .expect("fake repository should be creatable");
            fs::write(&path, "#!/usr/bin/env bash\nexit 0\n")
                .expect("fake repository script should be writable");
        }
        let repo_abs = fs::canonicalize(&repo.path).expect("fake repository should resolve");
        (repo, repo_abs)
    }

    /// Create a minimal repository shape with the v2 container entry script.
    fn fake_repo(tag: &str) -> (TempDir, PathBuf) {
        let repo = TempDir::new(tag);
        fs::create_dir_all(repo.path.join("engine/runtime"))
            .expect("fake repository should be creatable");
        fs::write(
            repo.path.join(CONTAINER_ENTRY_SCRIPT),
            "#!/usr/bin/env bash\nexit 0\n",
        )
        .expect("fake entry script should be writable");
        let repo_abs = fs::canonicalize(&repo.path).expect("fake repository should resolve");
        (repo, repo_abs)
    }

    #[cfg(unix)]
    fn write_runtime(path: &Path, body: &str) {
        use std::os::unix::fs::PermissionsExt;

        fs::write(path, body).expect("fake runtime should be writable");
        let mut permissions = fs::metadata(path)
            .expect("fake runtime metadata should be readable")
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).expect("fake runtime should be executable");
    }

    #[test]
    fn container_argv_uses_the_v2_entry_script_and_mounts() {
        let (_repo, repo_abs) = fake_repo("container-argv-v2");
        let out_dir = TempDir::new("container-argv-v2-out");
        let out_abs = fs::canonicalize(&out_dir.path).expect("output directory should resolve");

        let invocation = container_invocation(
            Path::new("docker"),
            engine::DEFAULT_ENGINE_IMAGE,
            "build-1",
            &repo_abs,
            &out_abs,
        )
        .expect("container invocation should assemble");

        let args: Vec<String> = invocation
            .args
            .iter()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            args,
            vec![
                "run".to_string(),
                "--rm".to_string(),
                "--init".to_string(),
                "--privileged".to_string(),
                "--platform".to_string(),
                "linux/amd64".to_string(),
                "--name".to_string(),
                "sysemble-build-build-1".to_string(),
                "-v".to_string(),
                format!("{}:/work:ro", repo_abs.display()),
                "-v".to_string(),
                format!("{}:/export", out_abs.display()),
                "-w".to_string(),
                "/work".to_string(),
                engine::DEFAULT_ENGINE_IMAGE.to_string(),
                "bash".to_string(),
                "engine/runtime/container-entry.sh".to_string(),
                "--plan".to_string(),
                "/export/plan.json".to_string(),
                "--out".to_string(),
                "/out".to_string(),
                "--export".to_string(),
                "/export".to_string(),
                "--mode".to_string(),
                "execute".to_string(),
            ]
        );
        assert_eq!(invocation.program, PathBuf::from("docker"));
        assert_eq!(invocation.name, "sysemble-build-build-1");
    }

    #[test]
    fn container_argv_exports_an_in_repo_output_at_export() {
        let (_repo, repo_abs) = fake_repo("container-argv-in-repo");
        let out = repo_abs.join("out");
        fs::create_dir_all(&out).expect("output directory should be creatable");

        let invocation = container_invocation(
            Path::new("podman"),
            engine::DEFAULT_ENGINE_IMAGE,
            "build-2",
            &repo_abs,
            &out,
        )
        .expect("container invocation should assemble");

        let args: Vec<String> = invocation
            .args
            .iter()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        assert!(
            args.contains(&format!("{}:/work:ro", repo_abs.display())),
            "repository must be mounted read-only: {args:?}"
        );
        assert!(
            args.contains(&format!("{}:/export", out.display())),
            "v2 always exports the host out directory separately: {args:?}"
        );
        assert!(
            !args
                .iter()
                .any(|arg| arg == &format!("{}:/work", repo_abs.display())),
            "the mutable /work mount is gone in v2: {args:?}"
        );
        assert!(
            !args.iter().any(|arg| arg.starts_with("/work/")),
            "v2 container paths must not derive from the repository: {args:?}"
        );

        let plan_index = args
            .iter()
            .position(|arg| arg == "--plan")
            .expect("--plan should be present");
        assert_eq!(args[plan_index + 1], "/export/plan.json");
        let out_index = args
            .iter()
            .position(|arg| arg == "--out")
            .expect("--out should be present");
        assert_eq!(args[out_index + 1], "/out");
    }

    #[test]
    fn execute_without_the_container_entry_script_is_a_readable_error() {
        let repo = TempDir::new("execute-entry-missing");
        let out = TempDir::new("execute-entry-missing-out");
        let manager = BuildManager::with_engine_probe_and_repo(
            container_probe(Path::new("docker")),
            repo.path.clone(),
        );

        let error = manager
            .start_build(
                &as_str(&example("minimal-debian.yaml")),
                &as_str(&out.path),
                "execute",
            )
            .expect_err("execute must validate the v2 container entry script");

        assert!(
            error.contains("cannot find the engine entry script"),
            "error should be readable: {error}"
        );
        assert!(
            error.contains(CONTAINER_ENTRY_SCRIPT),
            "error should name the missing script: {error}"
        );
        assert!(
            !out.path.join("build.log").exists(),
            "the entry script must be validated before output is written"
        );
    }

    #[test]
    fn execute_without_an_engine_returns_a_readable_error() {
        let manager = BuildManager::with_engine_probe(engine_probe(
            "container",
            false,
            "container engine: docker 29.1.2 · image sysemble-engine:0.1.0 not found; build it with engine/image/build-image.sh",
        ));
        let temp = TempDir::new("execute-no-engine");

        let error = manager
            .start_build(
                &as_str(&example("minimal-debian.yaml")),
                &as_str(&temp.path),
                "execute",
            )
            .expect_err("execute must be gated on a usable engine");

        assert!(
            error.contains("engine/image/build-image.sh"),
            "error should carry the probe reason: {error}"
        );
        assert!(
            error.contains("dry-run"),
            "error should point at the still-available dry run: {error}"
        );
        assert!(
            !temp.path.join("build.log").exists(),
            "a gated build must not create a log"
        );
    }

    #[test]
    fn local_engine_keeps_the_host_backend_without_a_runtime_path() {
        let local = engine_probe(
            "local",
            true,
            "local Linux builder: root and all required tools are available",
        );
        assert!(
            local.runtime_path.is_none(),
            "a local engine has no container runtime to invoke"
        );
        assert_eq!(
            execution_backend(Some(&local)),
            Ok(ExecutionBackend::Host),
            "kind local must keep the P1-b host path"
        );

        // No probe at all (dry run or the SYMBLE_BUILDER hook) is also host.
        assert_eq!(execution_backend(None), Ok(ExecutionBackend::Host));
    }

    #[test]
    fn only_a_container_engine_uses_the_container_backend() {
        let container = container_probe(Path::new("docker"));
        assert_eq!(
            execution_backend(Some(&container)),
            Ok(ExecutionBackend::Container)
        );

        let none = engine_probe("none", false, "no usable build engine");
        let error =
            execution_backend(Some(&none)).expect_err("kind `none` must not reach a launch path");
        assert!(
            error.contains("none"),
            "error should name the engine kind: {error}"
        );
    }

    #[test]
    fn vm_engine_uses_the_vm_backend() {
        let vm = vm_probe(
            Path::new("/helpers/sysemble-vm"),
            Path::new("/images/sysemble-vm/0.1.0"),
        );
        assert_eq!(execution_backend(Some(&vm)), Ok(ExecutionBackend::Vm));

        let unavailable = engine_probe(
            "vm",
            false,
            "vm engine unavailable: no valid VM image; build the image with engine/vm/image/build-image.sh",
        );
        let error = execution_backend(Some(&unavailable))
            .expect_err("an unavailable vm must not reach a launch path");
        assert!(
            error.contains("vm engine unavailable"),
            "error should carry the probe reason: {error}"
        );
    }

    #[test]
    fn execute_without_a_usable_vm_is_a_readable_error() {
        let manager = BuildManager::with_engine_probe(engine_probe(
            "vm",
            false,
            "vm engine unavailable: no valid VM image: disk.img is empty; build the image with engine/vm/image/build-image.sh or install the app bundle image",
        ));
        let temp = TempDir::new("execute-vm-unavailable");

        let error = manager
            .start_build(
                &as_str(&example("minimal-debian.yaml")),
                &as_str(&temp.path),
                "execute",
            )
            .expect_err("execute must be gated on a usable VM engine");

        assert!(
            error.contains("vm engine unavailable"),
            "error should carry the probe reason: {error}"
        );
        assert!(
            error.contains("engine/vm/image/build-image.sh"),
            "error should point at the VM image build script: {error}"
        );
        assert!(
            error.contains("dry-run"),
            "error should point at the still-available dry run: {error}"
        );
        assert!(
            !temp.path.join("build.log").exists() && !temp.path.join("plan.json").exists(),
            "a gated VM build must not write output"
        );
    }

    #[test]
    fn dry_run_does_not_probe_the_engine() {
        let manager = BuildManager::with_engine_resolver(Arc::new(|| -> EngineProbe {
            panic!("a dry-run build must never probe the engine")
        }));
        let temp = TempDir::new("dry-run-no-probe");

        let started = manager
            .start_build(
                &as_str(&example("minimal-debian.yaml")),
                &as_str(&temp.path),
                "dry-run",
            )
            .expect("dry-run must not depend on the engine probe");

        let status = wait_for_terminal(&manager, &started.id, Duration::from_secs(30));
        assert_eq!(status.state, BuildState::Exited, "status: {status:?}");
        assert_eq!(status.exit_code, Some(0));
    }

    #[test]
    fn vm_argv_matches_the_frozen_contract() {
        let temp = TempDir::new("vm-argv");
        let helper = temp.path.join("helper dir").join("中文").join("sysemble-vm");
        let image_dir = temp.path.join("image dir 中文");
        let repo = temp.path.join("repo with space").join("sysemble 仓库");
        let out = temp.path.join("out with space").join("构建");
        for dir in [&image_dir, &repo, &out] {
            fs::create_dir_all(dir).expect("test directory should be creatable");
        }
        fs::create_dir_all(helper.parent().expect("helper path should have a parent"))
            .expect("helper directory should be creatable");
        let helper_abs = fs::canonicalize(
            helper
                .parent()
                .expect("helper path should have a parent"),
        )
        .expect("helper directory should resolve")
        .join("sysemble-vm");
        let image_abs = fs::canonicalize(&image_dir).expect("image directory should resolve");
        let repo_abs = fs::canonicalize(&repo).expect("repository should resolve");
        let out_abs = fs::canonicalize(&out).expect("output directory should resolve");

        let invocation = vm_invocation(&helper_abs, &image_abs, &repo_abs, &out_abs);
        let args: Vec<String> = invocation
            .args
            .iter()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();

        assert_eq!(invocation.program, helper_abs);
        assert_eq!(
            args,
            vec![
                "run".to_string(),
                "--image-dir".to_string(),
                image_abs.display().to_string(),
                "--repo".to_string(),
                repo_abs.display().to_string(),
                "--out".to_string(),
                out_abs.display().to_string(),
                "--plan".to_string(),
                out_abs.join("plan.json").display().to_string(),
                "--timeout".to_string(),
                "1800".to_string(),
                "--json".to_string(),
            ],
            "the VM argv is frozen by the P1-e4 workplan §2.3"
        );
        assert_eq!(args.len(), 12);
        assert!(
            args[2].contains(' ') && args[2].contains('中'),
            "a path with spaces and CJK characters must stay one argv token: {:?}",
            args[2]
        );
    }

    #[cfg(unix)]
    #[test]
    fn execute_runs_the_vm_helper_and_captures_the_build_log() {
        let temp = TempDir::new("execute-vm");
        let (_repo, repo_abs) = fake_vm_repo("execute-vm-repo");
        let argv_log = temp.path.join("argv.txt");
        let helper = temp.path.join("sysemble-vm");
        let body = format!(
            r#"#!/bin/sh
printf '%s\n' "$@" > '{}'
printf 'vm helper stdout\n'
printf 'vm helper stderr\n' >&2
exit 0
"#,
            argv_log.display()
        );
        write_runtime(&helper, &body);
        let image_dir = temp.path.join("image");
        fs::create_dir_all(&image_dir).expect("image directory should be creatable");

        let manager =
            BuildManager::with_engine_probe_and_repo(vm_probe(&helper, &image_dir), repo_abs);
        let out = temp.path.join("out");
        let started = manager
            .start_build(
                &as_str(&example("minimal-debian.yaml")),
                &as_str(&out),
                "execute",
            )
            .expect("vm build should start");

        let status = wait_for_terminal(&manager, &started.id, Duration::from_secs(30));
        assert_eq!(status.state, BuildState::Exited, "status: {status:?}");
        assert_eq!(status.exit_code, Some(0));

        let recorded = fs::read_to_string(&argv_log).expect("the helper argv should be recorded");
        let args: Vec<String> = recorded.lines().map(str::to_string).collect();
        assert_eq!(args.first().map(String::as_str), Some("run"));
        let image_index = args
            .iter()
            .position(|arg| arg == "--image-dir")
            .expect("--image-dir should be present");
        assert_eq!(
            args[image_index + 1],
            as_str(&fs::canonicalize(&image_dir).expect("image directory should resolve"))
        );
        let plan_index = args
            .iter()
            .position(|arg| arg == "--plan")
            .expect("--plan should be present");
        assert_eq!(
            args[plan_index + 1],
            as_str(
                &fs::canonicalize(&out)
                    .expect("output directory should resolve")
                    .join("plan.json")
            )
        );
        let timeout_index = args
            .iter()
            .position(|arg| arg == "--timeout")
            .expect("--timeout should be present");
        assert_eq!(args[timeout_index + 1], "1800");
        assert_eq!(args.last().map(String::as_str), Some("--json"));

        let log = fs::read_to_string(&started.log_path).expect("the build log should be readable");
        assert!(log.contains("vm helper stdout"), "log:\n{log}");
        assert!(log.contains("vm helper stderr"), "log:\n{log}");
        assert!(Path::new(&started.plan_path).is_file());
    }

    #[cfg(unix)]
    fn process_alive(pid: i32) -> bool {
        #[cfg(target_os = "linux")]
        {
            // A zombie still answers kill(pid, 0). Busy CI runners can leave a
            // killed grandchild as a zombie for a moment, which is not a live
            // process; treat state Z as gone so the test measures the cancel
            // path rather than the init reaper's timing. An unreadable /proc
            // entry means the process is gone; an unparsable one (unexpected)
            // is treated as alive to avoid hiding a leak.
            match fs::read_to_string(format!("/proc/{pid}/stat")) {
                Ok(stat) => {
                    let state = stat
                        .rsplit(')')
                        .next()
                        .and_then(|rest| rest.split_whitespace().next());
                    !matches!(state, Some("Z"))
                }
                Err(_) => false,
            }
        }
        #[cfg(not(target_os = "linux"))]
        unsafe {
            libc::kill(pid, 0) == 0
        }
    }

    #[cfg(unix)]
    #[test]
    fn cancel_vm_build_marks_cancelled_and_leaves_no_helper_process() {
        let temp = TempDir::new("cancel-vm");
        let (_repo, repo_abs) = fake_vm_repo("cancel-vm-repo");
        let pid_file = temp.path.join("pids.txt");
        let term_file = temp.path.join("term.txt");
        let helper = temp.path.join("sysemble-vm");
        // SIGTERM is what the real helper catches to stop the VM; the trap
        // records that the signal arrived while the fake helper was running.
        let body = format!(
            r#"#!/bin/sh
printf '%s\n' "$$" > '{pids}'
trap 'printf term > {term}; exit 143' TERM
sleep 300 &
printf '%s\n' "$!" >> '{pids}'
wait
"#,
            pids = pid_file.display(),
            term = term_file.display()
        );
        write_runtime(&helper, &body);
        let image_dir = temp.path.join("image");
        fs::create_dir_all(&image_dir).expect("image directory should be creatable");

        let manager =
            BuildManager::with_engine_probe_and_repo(vm_probe(&helper, &image_dir), repo_abs);
        let out = temp.path.join("out");
        let started = manager
            .start_build(
                &as_str(&example("minimal-debian.yaml")),
                &as_str(&out),
                "execute",
            )
            .expect("vm build should start");

        // Wait until the helper recorded itself and its sleep child.
        let deadline = Instant::now() + Duration::from_secs(10);
        let pids: Vec<i32> = loop {
            if let Ok(text) = fs::read_to_string(&pid_file) {
                let pids: Vec<i32> = text
                    .lines()
                    .filter_map(|line| line.trim().parse().ok())
                    .collect();
                if pids.len() == 2 {
                    break pids;
                }
            }
            assert!(
                Instant::now() < deadline,
                "the fake helper never recorded its pid and child"
            );
            thread::sleep(Duration::from_millis(20));
        };

        manager
            .cancel_build(&started.id)
            .expect("a running vm build should be cancellable");
        let status = wait_for_terminal(
            &manager,
            &started.id,
            CANCEL_TERM_GRACE + Duration::from_secs(15),
        );
        assert_eq!(status.state, BuildState::Cancelled, "status: {status:?}");
        assert_eq!(status.exit_code, None);

        // The helper's SIGTERM handler must have run instead of being SIGKILLed.
        let deadline = Instant::now() + Duration::from_secs(10);
        while !term_file.is_file() {
            assert!(
                Instant::now() < deadline,
                "the VM helper never handled SIGTERM"
            );
            thread::sleep(Duration::from_millis(20));
        }

        // Neither the helper nor its child may survive the cancellation. The
        // watchdog escalates TERM to KILL after CANCEL_TERM_GRACE, so wait past
        // that deadline: a fake /bin/sh helper may only die on the escalation.
        let deadline = Instant::now() + CANCEL_TERM_GRACE + Duration::from_secs(15);
        loop {
            let alive: Vec<i32> = pids
                .iter()
                .copied()
                .filter(|pid| process_alive(*pid))
                .collect();
            if alive.is_empty() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "residual helper processes after cancel: {alive:?}"
            );
            thread::sleep(Duration::from_millis(50));
        }

        assert!(Path::new(&started.log_path).is_file());
    }

    #[test]
    fn dry_run_still_runs_when_the_engine_is_unavailable() {
        let manager = BuildManager::with_engine_probe(engine_probe(
            "none",
            false,
            "no usable build engine on macos",
        ));
        let temp = TempDir::new("dry-run-no-engine");

        let started = manager
            .start_build(
                &as_str(&example("minimal-debian.yaml")),
                &as_str(&temp.path),
                "dry-run",
            )
            .expect("dry-run must not depend on the engine probe");

        let status = wait_for_terminal(&manager, &started.id, Duration::from_secs(30));
        assert_eq!(status.state, BuildState::Exited, "status: {status:?}");
        assert_eq!(status.exit_code, Some(0));

        let log = manager
            .get_build_log(&started.id, None)
            .expect("build log should be readable");
        assert!(log.contains("Dry run complete"), "log:\n{log}");
    }

    #[cfg(unix)]
    #[test]
    fn execute_builds_through_the_container_runtime() {
        let temp = TempDir::new("execute-container");
        let invocation_log = temp.path.join("run-argv.txt");
        let runtime = temp.path.join("docker");
        let body = format!(
            r#"#!/usr/bin/env bash
if [ "$1" = "run" ]; then
  printf '%s\n' "$@" > '{}'
fi
exit 0
"#,
            invocation_log.display()
        );
        write_runtime(&runtime, &body);

        let manager = BuildManager::with_engine_probe(container_probe(&runtime));
        let out = temp.path.join("out");

        let started = manager
            .start_build(
                &as_str(&example("minimal-debian.yaml")),
                &as_str(&out),
                "execute",
            )
            .expect("container build should start");
        let status = wait_for_terminal(&manager, &started.id, Duration::from_secs(30));

        assert_eq!(status.state, BuildState::Exited, "status: {status:?}");
        assert_eq!(status.exit_code, Some(0));

        let recorded =
            fs::read_to_string(&invocation_log).expect("the runtime argv should be recorded");
        let args: Vec<&str> = recorded.lines().collect();
        assert_eq!(args.first().copied(), Some("run"));
        assert!(args.contains(&"--privileged"), "argv: {args:?}");
        assert!(args.contains(&"--platform"), "argv: {args:?}");
        assert!(args.contains(&"linux/amd64"), "argv: {args:?}");
        assert!(
            args.contains(&"engine/runtime/container-entry.sh"),
            "the v2 entry script must run inside the container: {args:?}"
        );
        assert!(
            args.iter().any(|arg| arg.ends_with(":/work:ro")),
            "the repository must be mounted read-only: {args:?}"
        );
        assert!(
            args.iter().any(|arg| arg.ends_with(":/export")),
            "the host out directory must be exported: {args:?}"
        );
        assert_eq!(args.last().copied(), Some("execute"));
        let mode_index = args
            .iter()
            .position(|arg| *arg == "--mode")
            .expect("--mode should be present");
        assert_eq!(args[mode_index + 1], "execute");

        let name_index = args
            .iter()
            .position(|arg| *arg == "--name")
            .expect("--name should be present");
        let name = args[name_index + 1];
        assert!(
            name.starts_with("sysemble-build-"),
            "unexpected container name: {name}"
        );

        // Only the -v mount sources may be host paths; plan/out stay inside.
        let plan_index = args
            .iter()
            .position(|arg| *arg == "--plan")
            .expect("--plan should be present");
        assert_eq!(args[plan_index + 1], "/export/plan.json");
        let out_index = args
            .iter()
            .position(|arg| *arg == "--out")
            .expect("--out should be present");
        assert_eq!(args[out_index + 1], "/out");
        let export_index = args
            .iter()
            .position(|arg| *arg == "--export")
            .expect("--export should be present");
        assert_eq!(args[export_index + 1], "/export");
        assert!(Path::new(&started.plan_path).is_file());
    }

    #[cfg(unix)]
    #[test]
    fn cancel_kills_the_named_container() {
        let temp = TempDir::new("cancel-container");
        let run_log = temp.path.join("run-argv.txt");
        let kill_log = temp.path.join("kill-argv.txt");
        let runtime = temp.path.join("docker");
        let body = format!(
            r#"#!/usr/bin/env bash
if [ "$1" = "run" ]; then
  printf '%s\n' "$@" > '{}'
  sleep 30
fi
if [ "$1" = "kill" ]; then
  printf '%s\n' "$@" > '{}'
fi
exit 0
"#,
            run_log.display(),
            kill_log.display()
        );
        write_runtime(&runtime, &body);

        let manager = BuildManager::with_engine_probe(container_probe(&runtime));
        let out = temp.path.join("out");
        let started = manager
            .start_build(
                &as_str(&example("minimal-debian.yaml")),
                &as_str(&out),
                "execute",
            )
            .expect("container build should start");

        // Wait until the fake runtime has recorded the run argv.
        let deadline = Instant::now() + Duration::from_secs(10);
        while !run_log.is_file() {
            assert!(
                Instant::now() < deadline,
                "the fake runtime never recorded its run argv"
            );
            thread::sleep(Duration::from_millis(20));
        }

        manager
            .cancel_build(&started.id)
            .expect("a running container build should be cancellable");
        let status = wait_for_terminal(&manager, &started.id, Duration::from_secs(10));
        assert_eq!(status.state, BuildState::Cancelled, "status: {status:?}");

        // `<runtime> kill <name>` is best effort and asynchronous.
        let deadline = Instant::now() + Duration::from_secs(10);
        while !kill_log.is_file() {
            assert!(
                Instant::now() < deadline,
                "cancellation did not run `<runtime> kill <name>`"
            );
            thread::sleep(Duration::from_millis(20));
        }

        let run_args: Vec<String> = fs::read_to_string(&run_log)
            .expect("run argv should be readable")
            .lines()
            .map(str::to_string)
            .collect();
        let name_index = run_args
            .iter()
            .position(|arg| arg == "--name")
            .expect("run argv should carry --name");
        let name = run_args[name_index + 1].clone();

        let kill_args: Vec<String> = fs::read_to_string(&kill_log)
            .expect("kill argv should be readable")
            .lines()
            .map(str::to_string)
            .collect();
        assert_eq!(kill_args, vec!["kill".to_string(), name]);
    }

    #[test]
    fn dry_run_build_exits_zero_and_logs_the_plan() {
        let manager = BuildManager::new();
        let temp = TempDir::new("dry-run");

        let started = manager
            .start_build(
                &as_str(&example("minimal-debian.yaml")),
                &as_str(&temp.path),
                "dry-run",
            )
            .expect("dry-run build should start");

        let began = Instant::now();
        let status = wait_for_terminal(&manager, &started.id, Duration::from_secs(30));
        let elapsed = began.elapsed();

        assert_eq!(status.state, BuildState::Exited, "status: {status:?}");
        assert_eq!(status.exit_code, Some(0), "status: {status:?}");
        assert!(status.finished_at.is_some());
        assert!(!status.started_at.is_empty());

        let plan_path = Path::new(&started.plan_path);
        assert!(plan_path.is_file(), "missing plan at {plan_path:?}");
        let plan_json = fs::read_to_string(plan_path).expect("plan should be readable");
        assert!(plan_json.contains("\"apiVersion\": \"sysemble/plan/v1\""));
        assert!(plan_json.contains("\"spec\": \"minimal-debian\""));

        let log = manager
            .get_build_log(&started.id, None)
            .expect("build log should be readable");
        assert!(log.contains("Dry run complete"), "log:\n{log}");
        assert!(log.contains("Stages (planned)"), "log:\n{log}");

        eprintln!("dry-run integration finished in {elapsed:?}");
        eprintln!(
            "BuildStarted={}",
            serde_json::to_string(&started).expect("started status should serialize")
        );
        eprintln!(
            "BuildStatus={}",
            serde_json::to_string(&status).expect("build status should serialize")
        );
    }

    #[test]
    fn invalid_mode_is_rejected() {
        let manager = BuildManager::new();
        let temp = TempDir::new("invalid-mode");

        let error = manager
            .start_build(
                &as_str(&example("minimal-debian.yaml")),
                &as_str(&temp.path),
                "fast",
            )
            .expect_err("invalid mode must not start a build");

        assert!(
            error.contains("fast"),
            "error should name the mode: {error}"
        );
        assert!(
            error.contains("dry-run"),
            "error should list dry-run: {error}"
        );
        assert!(
            error.contains("execute"),
            "error should list execute: {error}"
        );
    }

    #[test]
    fn missing_spec_is_rejected() {
        let manager = BuildManager::new();
        let temp = TempDir::new("missing-spec");
        let missing = temp.path.join("no-such-spec.yaml");

        let error = manager
            .start_build(&as_str(&missing), &as_str(&temp.path), "dry-run")
            .expect_err("a missing spec must not start a build");

        assert!(
            error.contains("no-such-spec.yaml"),
            "error should name the spec: {error}"
        );
    }

    #[test]
    fn unknown_build_ids_are_rejected() {
        let manager = BuildManager::new();

        let status_error = manager
            .get_build("build-missing")
            .expect_err("unknown build lookup must fail");
        assert!(status_error.contains("build-missing"));

        let log_error = manager
            .get_build_log("build-missing", None)
            .expect_err("unknown build log must fail");
        assert!(log_error.contains("build-missing"));
    }

    #[test]
    fn read_tail_returns_the_requested_suffix() {
        let temp = TempDir::new("read-tail");
        let path = temp.path.join("build.log");
        fs::write(&path, "one\ntwo\nthree\nfour\n").expect("log should be writable");

        assert_eq!(read_tail(&path, 2).unwrap(), "three\nfour\n");
        assert_eq!(read_tail(&path, 99).unwrap(), "one\ntwo\nthree\nfour\n");
        assert_eq!(read_tail(&path, 0).unwrap(), "");

        fs::write(&path, "a\nb\nc").expect("log should be writable");
        assert_eq!(read_tail(&path, 2).unwrap(), "b\nc");
    }

    #[test]
    fn timestamps_are_rfc3339_utc() {
        assert_eq!(format_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(format_utc(86_400), "1970-01-02T00:00:00Z");
        assert_eq!(format_utc(1_700_000_000), "2023-11-14T22:13:20Z");
    }
}
