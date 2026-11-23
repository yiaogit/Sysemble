//! Semantic validation for [`BuildSpec`].
//!
//! Every diagnostic has a stable `code` (safe to match in tests and in the
//! CLI) and a JSON Pointer style `path` into the spec document. Codes are
//! listed in [`codes`]; changing one is a breaking change for consumers.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};

use crate::model::{
    Arch, BaseKind, BuildSpec, DesktopSession, DevProfile, Firmware, Output, WindowsMode,
};
use crate::API_VERSION;

/// Stable diagnostic codes emitted by [`validate_spec`].
pub mod codes {
    /// `/apiVersion` is not [`crate::API_VERSION`].
    pub const API_VERSION_UNSUPPORTED: &str = "spec.api_version.unsupported";
    /// `/meta/name` does not match the schema pattern.
    pub const META_NAME_INVALID: &str = "spec.meta.name.invalid";
    /// `/meta/description` is longer than 500 characters.
    pub const META_DESCRIPTION_TOO_LONG: &str = "spec.meta.description.too_long";
    /// A tag appears more than once in `/meta/tags`.
    pub const META_TAGS_DUPLICATE: &str = "spec.meta.tags.duplicate";
    /// A non-LFS base has no `release`.
    pub const BASE_RELEASE_MISSING: &str = "spec.target.base.release.missing";
    /// `base.kind` is `lfs`.
    pub const BASE_LFS: &str = "spec.target.base.lfs";
    /// `target.output` is empty.
    pub const OUTPUT_EMPTY: &str = "spec.target.output.empty";
    /// An output kind appears more than once.
    pub const OUTPUT_DUPLICATE: &str = "spec.target.output.duplicate";
    /// `/system/hostname` does not match the schema pattern.
    pub const HOSTNAME_INVALID: &str = "spec.system.hostname.invalid";
    /// A user name does not match the schema pattern.
    pub const USER_NAME_INVALID: &str = "spec.system.users.name.invalid";
    /// Two users share a name.
    pub const USER_NAME_DUPLICATE: &str = "spec.system.users.duplicate";
    /// A desktop session other than `none` has no display manager.
    pub const DESKTOP_DISPLAY_MANAGER_MISSING: &str = "spec.desktop.display_manager.missing";
    /// `/desktop/theme/accent` is not a `#rrggbb` color.
    pub const DESKTOP_ACCENT_INVALID: &str = "spec.desktop.theme.accent.invalid";
    /// Windows virtualization is enabled but has no mode.
    pub const WINDOWS_MODE_MISSING: &str = "spec.virtualization.windows.mode.missing";
    /// `remoteapp` is used without declaring a Windows edition.
    pub const WINDOWS_EDITION_REMOTEAPP: &str = "spec.virtualization.windows.edition.remoteapp";
    /// `looking-glass` is used without GPU passthrough.
    pub const WINDOWS_LOOKING_GLASS_GPU: &str = "spec.virtualization.windows.looking_glass.gpu";
    /// Windows guests are requested on aarch64, which P0 does not plan.
    pub const WINDOWS_ARCH_UNSUPPORTED: &str = "spec.virtualization.windows.arch_unsupported";
    /// `windows.vm.cpus` is outside 1..=32.
    pub const WINDOWS_VM_CPUS: &str = "spec.virtualization.windows.vm.cpus";
    /// `windows.vm.memory_gb` is outside 2..=128.
    pub const WINDOWS_VM_MEMORY_GB: &str = "spec.virtualization.windows.vm.memory_gb";
    /// `windows.vm.disk_gb` is outside 32..=1024.
    pub const WINDOWS_VM_DISK_GB: &str = "spec.virtualization.windows.vm.disk_gb";
    /// A dev profile is listed more than once.
    pub const DEV_PROFILES_DUPLICATE: &str = "spec.dev.profiles.duplicate";
    /// Secure Boot is requested together with BIOS firmware.
    pub const SECURE_BOOT_BIOS: &str = "spec.security.secure_boot.bios";
    /// `output` contains `iso` while the installer is disabled.
    pub const INSTALLER_ISO: &str = "spec.installer.iso_without_installer";
    /// The installer is enabled without a type.
    pub const INSTALLER_TYPE_MISSING: &str = "spec.installer.type.missing";
    /// A verify scenario id does not match the schema pattern.
    pub const VERIFY_SCENARIO_ID_INVALID: &str = "spec.verify.scenario.id.invalid";
    /// A verify scenario has no tests.
    pub const VERIFY_SCENARIO_TESTS_EMPTY: &str = "spec.verify.scenario.tests.empty";
}

/// How serious a [`Diagnostic`] is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Error,
    Warning,
}

impl Severity {
    /// Stable lowercase spelling used in JSON output.
    pub fn as_str(self) -> &'static str {
        match self {
            Severity::Error => "error",
            Severity::Warning => "warning",
        }
    }
}

impl std::fmt::Display for Severity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One validation finding.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Diagnostic {
    pub severity: Severity,
    /// Stable short code, e.g. `spec.system.hostname.invalid`.
    pub code: String,
    /// JSON Pointer into the spec, e.g. `/system/hostname`.
    pub path: String,
    pub message: String,
}

impl Diagnostic {
    /// Build an error diagnostic.
    pub fn error(
        code: impl Into<String>,
        path: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            severity: Severity::Error,
            code: code.into(),
            path: path.into(),
            message: message.into(),
        }
    }

    /// Build a warning diagnostic.
    pub fn warning(
        code: impl Into<String>,
        path: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            severity: Severity::Warning,
            code: code.into(),
            path: path.into(),
            message: message.into(),
        }
    }

    /// True when this diagnostic blocks planning.
    pub fn is_error(&self) -> bool {
        self.severity == Severity::Error
    }

    /// True when this diagnostic is advisory only.
    pub fn is_warning(&self) -> bool {
        self.severity == Severity::Warning
    }
}

/// Validate a parsed spec and return every finding.
///
/// Errors block a plan; warnings are carried into [`crate::Plan::warnings`].
/// The order of the returned diagnostics is stable for a given spec.
pub fn validate_spec(spec: &BuildSpec) -> Vec<Diagnostic> {
    let mut diagnostics = Vec::new();

    if spec.api_version != API_VERSION {
        diagnostics.push(Diagnostic::error(
            codes::API_VERSION_UNSUPPORTED,
            "/apiVersion",
            format!(
                "unsupported apiVersion `{}`; this build understands `{API_VERSION}`",
                spec.api_version
            ),
        ));
    }

    if !is_meta_name(&spec.meta.name) {
        diagnostics.push(Diagnostic::error(
            codes::META_NAME_INVALID,
            "/meta/name",
            "meta.name must be 2-63 characters of lowercase letters, digits, or hyphens, \
             starting with a letter or digit",
        ));
    }

    if let Some(description) = &spec.meta.description {
        if description.chars().count() > 500 {
            diagnostics.push(Diagnostic::error(
                codes::META_DESCRIPTION_TOO_LONG,
                "/meta/description",
                "meta.description must be at most 500 characters",
            ));
        }
    }

    let mut seen_tags = HashSet::new();
    for (index, tag) in spec.meta.tags.iter().enumerate() {
        if !seen_tags.insert(tag.as_str()) {
            diagnostics.push(Diagnostic::error(
                codes::META_TAGS_DUPLICATE,
                format!("/meta/tags/{index}"),
                format!("tag `{tag}` is listed more than once"),
            ));
        }
    }

    if spec.target.base.kind != BaseKind::Lfs
        && spec
            .target
            .base
            .release
            .as_deref()
            .is_none_or(|release| release.trim().is_empty())
    {
        diagnostics.push(Diagnostic::warning(
            codes::BASE_RELEASE_MISSING,
            "/target/base/release",
            format!(
                "base `{}` has no release; the build will not be reproducible until one is pinned",
                spec.target.base.kind
            ),
        ));
    }

    if spec.target.base.kind == BaseKind::Lfs {
        diagnostics.push(Diagnostic::warning(
            codes::BASE_LFS,
            "/target/base/kind",
            "LFS builds take roughly 8-20 hours, are easy to break, and are not suitable \
             as a daily-use system; treat this as a laboratory build",
        ));
    }

    if spec.target.output.is_empty() {
        diagnostics.push(Diagnostic::error(
            codes::OUTPUT_EMPTY,
            "/target/output",
            "target.output needs at least one artifact kind",
        ));
    }

    let mut seen_outputs = HashSet::new();
    for (index, output) in spec.target.output.iter().enumerate() {
        if !seen_outputs.insert(*output) {
            diagnostics.push(Diagnostic::error(
                codes::OUTPUT_DUPLICATE,
                format!("/target/output/{index}"),
                format!("output `{output}` is listed more than once"),
            ));
        }
    }

    if !is_hostname(&spec.system.hostname) {
        diagnostics.push(Diagnostic::error(
            codes::HOSTNAME_INVALID,
            "/system/hostname",
            "system.hostname must be 1-63 characters of lowercase letters, digits, or hyphens, \
             starting with a letter or digit",
        ));
    }

    let mut seen_users = HashSet::new();
    for (index, user) in spec.system.users.iter().enumerate() {
        if !is_user_name(&user.name) {
            diagnostics.push(Diagnostic::error(
                codes::USER_NAME_INVALID,
                format!("/system/users/{index}/name"),
                format!(
                    "user name `{}` must be 1-32 characters of lowercase letters, digits, \
                     underscores, or hyphens, starting with a letter or underscore",
                    user.name
                ),
            ));
        }
        if !seen_users.insert(user.name.as_str()) {
            diagnostics.push(Diagnostic::error(
                codes::USER_NAME_DUPLICATE,
                format!("/system/users/{index}/name"),
                format!("user name `{}` is defined more than once", user.name),
            ));
        }
    }

    if let Some(desktop) = &spec.desktop {
        if let Some(session) = desktop.session {
            let display_manager_missing = desktop
                .display_manager
                .as_deref()
                .is_none_or(|manager| manager.trim().is_empty());
            if session != DesktopSession::None && display_manager_missing {
                diagnostics.push(Diagnostic::warning(
                    codes::DESKTOP_DISPLAY_MANAGER_MISSING,
                    "/desktop/display_manager",
                    format!(
                        "desktop session `{session}` has no display_manager; the image will \
                         boot to a text console unless one is added"
                    ),
                ));
            }
        }

        if let Some(accent) = desktop
            .theme
            .as_ref()
            .and_then(|theme| theme.accent.as_deref())
        {
            if !is_hex_color(accent) {
                diagnostics.push(Diagnostic::error(
                    codes::DESKTOP_ACCENT_INVALID,
                    "/desktop/theme/accent",
                    format!("theme accent `{accent}` must be a #rrggbb color"),
                ));
            }
        }
    }

    if let Some(windows) = spec
        .virtualization
        .as_ref()
        .and_then(|virtualization| virtualization.windows.as_ref())
    {
        if windows.enabled && windows.mode.is_none() {
            diagnostics.push(Diagnostic::error(
                codes::WINDOWS_MODE_MISSING,
                "/virtualization/windows/mode",
                "virtualization.windows.enabled is true but mode is missing; choose wine, \
                 remoteapp, desktop, or looking-glass",
            ));
        }

        if windows.enabled && spec.target.arch == Arch::Aarch64 {
            diagnostics.push(Diagnostic::warning(
                codes::WINDOWS_ARCH_UNSUPPORTED,
                "/virtualization/windows/enabled",
                "Windows guests are only planned for x86_64 in P0; aarch64 Windows is out of scope",
            ));
        }

        match windows.mode {
            Some(WindowsMode::RemoteApp) if windows.edition.is_none() => {
                diagnostics.push(Diagnostic::warning(
                    codes::WINDOWS_EDITION_REMOTEAPP,
                    "/virtualization/windows/edition",
                    "remoteapp needs a Windows Pro/Enterprise guest with the RDP server; \
                     declare edition win10 or win11 and confirm the license (Home has no RDP server)",
                ));
            }
            Some(WindowsMode::LookingGlass) if !windows.gpu_passthrough => {
                diagnostics.push(Diagnostic::warning(
                    codes::WINDOWS_LOOKING_GLASS_GPU,
                    "/virtualization/windows/gpu_passthrough",
                    "looking-glass needs a second GPU bound to VFIO; set gpu_passthrough: true \
                     only when the host has a spare GPU",
                ));
            }
            _ => {}
        }

        if let Some(vm) = &windows.vm {
            if let Some(cpus) = vm.cpus {
                if !(1..=32).contains(&cpus) {
                    diagnostics.push(Diagnostic::error(
                        codes::WINDOWS_VM_CPUS,
                        "/virtualization/windows/vm/cpus",
                        "windows.vm.cpus must be between 1 and 32",
                    ));
                }
            }
            if let Some(memory_gb) = vm.memory_gb {
                if !(2..=128).contains(&memory_gb) {
                    diagnostics.push(Diagnostic::error(
                        codes::WINDOWS_VM_MEMORY_GB,
                        "/virtualization/windows/vm/memory_gb",
                        "windows.vm.memory_gb must be between 2 and 128",
                    ));
                }
            }
            if let Some(disk_gb) = vm.disk_gb {
                if !(32..=1024).contains(&disk_gb) {
                    diagnostics.push(Diagnostic::error(
                        codes::WINDOWS_VM_DISK_GB,
                        "/virtualization/windows/vm/disk_gb",
                        "windows.vm.disk_gb must be between 32 and 1024",
                    ));
                }
            }
        }
    }

    if let Some(dev) = &spec.dev {
        let mut first_seen: HashMap<DevProfile, usize> = HashMap::new();
        for (index, profile) in dev.profiles.iter().enumerate() {
            let first = *first_seen.entry(*profile).or_insert(index);
            if first != index {
                diagnostics.push(Diagnostic::warning(
                    codes::DEV_PROFILES_DUPLICATE,
                    format!("/dev/profiles/{index}"),
                    format!(
                        "dev profile `{profile}` is listed more than once (first at index \
                         {first}); the planner installs it once"
                    ),
                ));
            }
        }
    }

    if let Some(security) = &spec.security {
        if security.secure_boot && spec.target.firmware == Firmware::Bios {
            diagnostics.push(Diagnostic::error(
                codes::SECURE_BOOT_BIOS,
                "/security/secure_boot",
                "security.secure_boot is true but target.firmware is bios; Secure Boot requires UEFI",
            ));
        }
    }

    let installer_enabled = spec
        .installer
        .as_ref()
        .is_some_and(|installer| installer.enabled);

    if spec.target.output.contains(&Output::Iso) && !installer_enabled {
        diagnostics.push(Diagnostic::warning(
            codes::INSTALLER_ISO,
            "/target/output",
            "target.output includes `iso` but installer.enabled is false; an installable ISO \
             needs an installer",
        ));
    }

    if let Some(installer) = &spec.installer {
        if installer.enabled && installer.type_.is_none() {
            diagnostics.push(Diagnostic::warning(
                codes::INSTALLER_TYPE_MISSING,
                "/installer/type",
                "installer.enabled is true but installer.type is missing; choose calamares or \
                 unattended",
            ));
        }
    }

    if let Some(verify) = &spec.verify {
        for (index, scenario) in verify.scenarios.iter().enumerate() {
            if !is_scenario_id(&scenario.id) {
                diagnostics.push(Diagnostic::error(
                    codes::VERIFY_SCENARIO_ID_INVALID,
                    format!("/verify/scenarios/{index}/id"),
                    format!(
                        "scenario id `{}` must be 2-41 characters of lowercase letters, digits, \
                         or hyphens, starting with a letter or digit",
                        scenario.id
                    ),
                ));
            }
            if scenario.tests.is_empty() {
                diagnostics.push(Diagnostic::error(
                    codes::VERIFY_SCENARIO_TESTS_EMPTY,
                    format!("/verify/scenarios/{index}/tests"),
                    "a verify scenario needs at least one test",
                ));
            }
        }
    }

    diagnostics
}

/// `^[a-z0-9][a-z0-9-]{min-1,max-1}$`
fn is_alphanumeric_name(value: &str, min_len: usize, max_len: usize) -> bool {
    let len = value.chars().count();
    if !(min_len..=max_len).contains(&len) {
        return false;
    }
    let mut chars = value.chars();
    match chars.next() {
        Some(first) if first.is_ascii_lowercase() || first.is_ascii_digit() => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// `^[a-z0-9][a-z0-9-]{1,62}$`
fn is_meta_name(value: &str) -> bool {
    is_alphanumeric_name(value, 2, 63)
}

/// `^[a-z0-9][a-z0-9-]{0,62}$`
fn is_hostname(value: &str) -> bool {
    is_alphanumeric_name(value, 1, 63)
}

/// `^[a-z_][a-z0-9_-]{0,31}$`
fn is_user_name(value: &str) -> bool {
    let len = value.chars().count();
    if !(1..=32).contains(&len) {
        return false;
    }
    let mut chars = value.chars();
    match chars.next() {
        Some(first) if first.is_ascii_lowercase() || first == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// `^[a-z0-9][a-z0-9-]{1,40}$`
fn is_scenario_id(value: &str) -> bool {
    is_alphanumeric_name(value, 2, 41)
}

/// `^#[0-9a-fA-F]{6}$`
fn is_hex_color(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 7 && bytes[0] == b'#' && bytes[1..].iter().all(u8::is_ascii_hexdigit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_schema_shaped_names() {
        assert!(is_meta_name("debian-kde-dev"));
        assert!(is_meta_name("ab"));
        assert!(!is_meta_name("a"));
        assert!(!is_meta_name("-leading-hyphen"));
        assert!(!is_meta_name("Uppercase"));

        assert!(is_hostname("ws"));
        assert!(is_hostname("edge-01"));
        assert!(!is_hostname("edge_01"));
        assert!(!is_hostname(""));
    }

    #[test]
    fn accepts_unix_user_names() {
        assert!(is_user_name("me"));
        assert!(is_user_name("_svc"));
        assert!(is_user_name("dev-user"));
        assert!(!is_user_name("Dev"));
        assert!(!is_user_name("1user"));
        assert!(!is_user_name(""));
    }

    #[test]
    fn requires_hex_colors() {
        assert!(is_hex_color("#4a90d9"));
        assert!(!is_hex_color("4a90d9"));
        assert!(!is_hex_color("#4a90d"));
        assert!(!is_hex_color("#gggggg"));
    }

    #[test]
    fn scenario_ids_need_two_characters() {
        assert!(is_scenario_id("boot"));
        assert!(is_scenario_id("desktop"));
        assert!(!is_scenario_id("a"));
        assert!(!is_scenario_id("Boot"));
    }

    #[test]
    fn severity_serializes_lowercase() {
        assert_eq!(
            serde_yaml::to_string(&Severity::Warning).unwrap().trim(),
            "warning"
        );
        assert_eq!(
            Diagnostic::error("x", "/x", "boom").severity.as_str(),
            "error"
        );
    }
}
