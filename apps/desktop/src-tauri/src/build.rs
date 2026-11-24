//! Build execution for the Sysemble desktop shell (P1-b).
//!
//! A [`BuildManager`] owns every build started by this process. A build is a
//! `bash <repo>/builders/debian/build.sh ...` child process whose combined
//! stdout/stderr is redirected to `<out>/build.log`. A supervisor thread blocks
//! in [`std::process::Child::wait`] and publishes the terminal state, while
//! cancellation signals the builder's process group. The supervisor therefore
//! never holds the registry lock while waiting, and cancellation never blocks
//! on a running build.
//!
//! The command layer lives in `lib.rs`; this module is plain Rust so the
//! lifecycle can be tested without a WebView.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use sysemble_core::{load_spec, resolve_plan};

use crate::{repo_root, resolve_path};

/// Log lines returned by [`BuildManager::get_build_log`] when the caller does
/// not request a specific count.
pub const DEFAULT_LOG_TAIL_LINES: u32 = 200;

/// Registry shared by the command layer and the supervisor threads.
type Registry = Arc<Mutex<HashMap<String, BuildRecord>>>;

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

/// One entry in the build registry.
struct BuildRecord {
    state: BuildState,
    exit_code: Option<i32>,
    started_at: String,
    finished_at: Option<String>,
    log_path: PathBuf,
    /// Builder process id, kept for cancellation.
    pid: u32,
    /// The child is claimed by the supervisor thread for `wait()`. It is put
    /// back once the process has been reaped so the record keeps its handle.
    child: Option<Child>,
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
}

impl Default for BuildManager {
    fn default() -> Self {
        Self {
            registry: Arc::new(Mutex::new(HashMap::new())),
            cancel_gate: Arc::new(Mutex::new(())),
        }
    }
}

impl BuildManager {
    pub fn new() -> Self {
        Self::default()
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

        let mut command = Command::new("bash");
        command
            .arg(&builder)
            .arg("--plan")
            .arg(&plan_path)
            .arg("--out")
            .arg(&out_abs)
            .arg(mode.flag())
            .stdin(Stdio::null())
            .stdout(Stdio::from(log))
            .stderr(Stdio::from(stderr_log));
        configure_process_group(&mut command);

        let child = command.spawn().map_err(|error| {
            format!(
                "cannot start builder `{}` with bash: {error}",
                builder.display()
            )
        })?;
        let pid = child.id();
        let id = next_build_id();
        let started_at = now_iso8601();

        let record = BuildRecord {
            state: BuildState::Running,
            exit_code: None,
            started_at,
            finished_at: None,
            log_path: log_path.clone(),
            pid,
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

        let pid = {
            let registry = self.lock()?;
            let record = registry.get(id).ok_or_else(|| unknown_build(id))?;
            if record.state != BuildState::Running {
                return Err(format!(
                    "build `{id}` is not running (state: {})",
                    record.state.as_str()
                ));
            }
            record.pid
        };

        terminate_process_group(pid)
            .map_err(|error| format!("cannot cancel build `{id}`: {error}"))?;

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

/// Resolve the builder script. `SYMBLE_BUILDER` wins so tests (and future
/// engines) can substitute a fake builder; otherwise the script lives at the
/// repository root next to the desktop app.
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
    // A negative pid signals the process group led by the builder.
    let result = unsafe { libc::kill(-(pid as i32), libc::SIGKILL) };
    if result == 0 {
        return Ok(());
    }

    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        return Err("the builder process has already exited".to_string());
    }
    Err(error.to_string())
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
