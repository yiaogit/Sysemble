//! Engine availability probe for the desktop shell (P1-e1).
//!
//! P1-e's full shape is a Linux engine VM on macOS/Windows. This module only
//! answers the smaller question the Build button needs: can this *host* run a
//! real build right now? On macOS/Windows the answer is no until P1-e2 lands,
//! and the UI must say so instead of letting `--execute` fail with exit 3.
//!
//! On Linux the existing Debian builder requires root plus a handful of tools
//! on `PATH`; the probe reports all missing requirements so the status bar can
//! explain exactly what is absent.

use std::env;

use serde::Serialize;

/// Tools the current Debian builder invokes and that must be on `PATH`.
#[cfg(target_os = "linux")]
const LOCAL_ENGINE_TOOLS: [&str; 4] = ["mmdebstrap", "sgdisk", "mkfs.ext4", "qemu-img"];

/// Why real builds are unavailable outside Linux until P1-e2 lands.
const ENGINE_VM_REASON: &str =
    "real builds need the engine VM, which is not implemented yet (P1-e2)";

/// Whether this host has a usable build engine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EngineInfo {
    /// `local` for the Linux host builder, `none` when no engine is implemented.
    pub kind: String,
    /// True only when a real (execute) build can run on this host.
    pub available: bool,
    /// `std::env::consts::OS`, for example `macos`, `linux`, or `windows`.
    pub platform: String,
    /// Human-readable explanation shown by the UI when `available` is false.
    pub reason: String,
}

/// Probe the current host for a usable build engine.
///
/// # Errors
///
/// Reserved for the docker/ssh backends P1-e2 will add. The local probe itself
/// cannot fail, so this currently always returns `Ok`.
pub fn engine_info() -> Result<EngineInfo, String> {
    Ok(probe(env::consts::OS))
}

/// Pure platform dispatch, kept separate so the platform string is explicit.
fn probe(platform: &str) -> EngineInfo {
    if platform == "linux" {
        linux_info(platform)
    } else {
        unavailable(platform)
    }
}

/// macOS and Windows (and any future host OS) need the P1-e2 engine VM.
fn unavailable(platform: &str) -> EngineInfo {
    EngineInfo {
        kind: "none".to_string(),
        available: false,
        platform: platform.to_string(),
        reason: ENGINE_VM_REASON.to_string(),
    }
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
    }
}

/// Non-Linux hosts never take the local branch; this stub keeps the dispatch
/// total and can be replaced when P1-e2 adds VM/docker/ssh backends.
#[cfg(not(target_os = "linux"))]
fn linux_info(platform: &str) -> EngineInfo {
    unavailable(platform)
}

/// True when `tool` names an existing file in one of the `PATH` directories.
#[cfg(target_os = "linux")]
fn tool_in_path(tool: &str) -> bool {
    env::var_os("PATH").is_some_and(|path| {
        env::split_paths(&path).any(|dir| !dir.as_os_str().is_empty() && dir.join(tool).is_file())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_info_reports_the_host_capability() {
        let info = engine_info().expect("the local engine probe cannot fail");

        assert!(!info.platform.is_empty(), "platform must not be empty");

        let json = serde_json::to_value(&info).expect("engine info should serialize");
        for field in ["kind", "available", "platform", "reason"] {
            assert!(
                !json[field].is_null(),
                "serialized engine info is missing `{field}`: {json}"
            );
        }

        #[cfg(any(target_os = "macos", target_os = "windows"))]
        {
            assert_eq!(info.kind, "none");
            assert!(!info.available);
            assert!(
                info.reason.contains("engine VM"),
                "reason should explain the missing engine VM: {}",
                info.reason
            );
            assert!(
                info.reason.contains("P1-e2"),
                "reason should point at P1-e2: {}",
                info.reason
            );
        }

        eprintln!(
            "EngineInfo={}",
            serde_json::to_string_pretty(&info).expect("engine info should serialize")
        );
    }
}
