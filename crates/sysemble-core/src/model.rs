//! Serde model for `buildspec.yaml`.
//!
//! The model mirrors `spec/buildspec.schema.json` field for field. Every
//! object uses `deny_unknown_fields`: an unknown key is a hard parse error, not
//! something that is silently dropped, because a dropped key means the built
//! system differs from what the author wrote.
//!
//! `apiVersion` is deliberately a `String` here. The version is checked by
//! [`crate::validate_spec`] so that an old or future spec produces a readable
//! diagnostic instead of an opaque deserialization error.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Root object of a build spec.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BuildSpec {
    #[serde(rename = "apiVersion")]
    pub api_version: String,
    pub meta: Meta,
    pub target: Target,
    pub system: System,
    pub desktop: Option<Desktop>,
    pub virtualization: Option<Virtualization>,
    pub dev: Option<Dev>,
    pub security: Option<Security>,
    pub installer: Option<Installer>,
    pub verify: Option<Verify>,
    pub sharing: Option<Sharing>,
}

/// Identity of the artifact: what to call it and how to find it again.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Meta {
    pub name: String,
    pub description: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
}

/// What to assemble and for which hardware.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Target {
    pub base: Base,
    pub arch: Arch,
    #[serde(default = "default_firmware")]
    pub firmware: Firmware,
    pub output: Vec<Output>,
}

/// Base distribution and the pin that makes it reproducible.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Base {
    pub kind: BaseKind,
    pub release: Option<String>,
    pub mirror: Option<String>,
    /// Snapshot date (`YYYY-MM-DD`) or content digest.
    pub pin: Option<String>,
}

/// Operating system settings.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct System {
    pub hostname: String,
    pub locale: Option<String>,
    pub timezone: Option<String>,
    pub keyboard: Option<String>,
    #[serde(default)]
    pub users: Vec<User>,
    pub kernel: Option<Kernel>,
    pub packages: Option<SystemPackages>,
    #[serde(default)]
    pub services: Vec<Service>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Kernel {
    pub flavor: Option<KernelFlavor>,
    #[serde(default)]
    pub cmdline: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SystemPackages {
    #[serde(default)]
    pub include: Vec<String>,
    #[serde(default)]
    pub exclude: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct User {
    pub name: String,
    #[serde(default)]
    pub groups: Vec<String>,
    pub shell: Option<String>,
    #[serde(default = "default_password")]
    pub password: UserPassword,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Service {
    pub name: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    pub config: Option<BTreeMap<String, serde_yaml::Value>>,
}

/// Desktop session and its applications.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Desktop {
    pub session: Option<DesktopSession>,
    pub display_manager: Option<String>,
    pub theme: Option<Theme>,
    #[serde(default)]
    pub apps: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Theme {
    pub mode: Option<ThemeMode>,
    pub accent: Option<String>,
}

/// How Windows applications are exposed inside the Linux desktop.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Virtualization {
    pub windows: Option<Windows>,
    pub containers: Option<Containers>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Windows {
    #[serde(default)]
    pub enabled: bool,
    pub mode: Option<WindowsMode>,
    pub edition: Option<WindowsEdition>,
    #[serde(default)]
    pub gpu_passthrough: bool,
    pub vm: Option<WindowsVm>,
    pub media: Option<WindowsMedia>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WindowsVm {
    pub cpus: Option<u32>,
    pub memory_gb: Option<u32>,
    pub disk_gb: Option<u32>,
}

/// Where the Windows installation media comes from.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WindowsMedia {
    pub windows_iso: Option<WindowsIsoSource>,
    pub virtio_iso: Option<VirtioIsoSource>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Containers {
    #[serde(default = "default_true")]
    pub podman: bool,
    #[serde(default)]
    pub distrobox: bool,
}

/// Development tooling profiles.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Dev {
    #[serde(default)]
    pub profiles: Vec<DevProfile>,
    #[serde(default)]
    pub editors: Vec<String>,
    #[serde(default = "default_true")]
    pub containers: bool,
}

/// Baseline security choices. Absent fields fall back to the schema defaults.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Security {
    #[serde(default = "default_disk_encryption")]
    pub disk_encryption: DiskEncryption,
    #[serde(default)]
    pub secure_boot: bool,
    #[serde(default = "default_firewall")]
    pub firewall: Firewall,
    #[serde(default = "default_hardening")]
    pub hardening: Hardening,
}

/// Installer baked into the image.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Installer {
    #[serde(default)]
    pub enabled: bool,
    #[serde(rename = "type")]
    pub type_: Option<InstallerType>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Verify {
    #[serde(default)]
    pub scenarios: Vec<Scenario>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scenario {
    pub id: String,
    pub tests: Vec<VerifyTest>,
}

/// Fields shared with a team: who owns it, what it must comply with, how it is
/// published.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sharing {
    pub team: Option<String>,
    #[serde(default = "default_compliance_profile")]
    pub compliance_profile: ComplianceProfile,
    #[serde(default)]
    pub publish: Vec<PublishTarget>,
}

macro_rules! string_enum {
    (
        $(#[$type_meta:meta])*
        pub enum $name:ident {
            $(
                $variant:ident => $text:literal
            ),+ $(,)?
        }
    ) => {
        $(#[$type_meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
        pub enum $name {
            $(
                #[serde(rename = $text)]
                $variant,
            )+
        }

        impl $name {
            /// Stable lowercase spelling used in specs, plans, and logs.
            pub fn as_str(self) -> &'static str {
                match self {
                    $(Self::$variant => $text),+
                }
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str(self.as_str())
            }
        }
    };
}

string_enum! {
    /// Distribution family used as the build base.
    pub enum BaseKind {
        Debian => "debian",
        Ubuntu => "ubuntu",
        Arch => "arch",
        Fedora => "fedora",
        Opensuse => "opensuse",
        Alpine => "alpine",
        Nixos => "nixos",
        Lfs => "lfs",
    }
}

string_enum! {
    /// CPU architecture this image is assembled for.
    pub enum Arch {
        X86_64 => "x86_64",
        Aarch64 => "aarch64",
    }
}

string_enum! {
    /// Firmware the image boots under.
    pub enum Firmware {
        Bios => "bios",
        Uefi => "uefi",
    }
}

string_enum! {
    /// Artifact kinds produced by a build.
    pub enum Output {
        Qcow2 => "qcow2",
        Iso => "iso",
        Raw => "raw",
        Uki => "uki",
        Pxe => "pxe",
    }
}

string_enum! {
    /// Desktop session shipped in the image.
    pub enum DesktopSession {
        None => "none",
        Plasma => "plasma",
        Gnome => "gnome",
        Xfce => "xfce",
        Hyprland => "hyprland",
        Sway => "sway",
    }
}

string_enum! {
    /// Light or dark desktop theme.
    pub enum ThemeMode {
        Light => "light",
        Dark => "dark",
    }
}

string_enum! {
    /// How Windows applications are provided.
    pub enum WindowsMode {
        Wine => "wine",
        RemoteApp => "remoteapp",
        Desktop => "desktop",
        LookingGlass => "looking-glass",
    }
}

string_enum! {
    /// Windows release used for the VM.
    pub enum WindowsEdition {
        Win10 => "win10",
        Win11 => "win11",
    }
}

string_enum! {
    /// Where the Windows installer ISO comes from. Sysemble never ships one.
    pub enum WindowsIsoSource {
        UserSupplied => "user-supplied",
    }
}

string_enum! {
    /// Virtio drivers are fetched automatically and pinned by the builder.
    pub enum VirtioIsoSource {
        Auto => "auto",
    }
}

string_enum! {
    /// Development toolchain profiles.
    pub enum DevProfile {
        Python => "python",
        Node => "node",
        Rust => "rust",
        Go => "go",
        Ml => "ml",
        Embedded => "embedded",
    }
}

string_enum! {
    /// Full-disk encryption choice.
    pub enum DiskEncryption {
        None => "none",
        Luks => "luks",
    }
}

string_enum! {
    /// Host firewall.
    pub enum Firewall {
        None => "none",
        Nftables => "nftables",
    }
}

string_enum! {
    /// Hardening level applied to the image.
    pub enum Hardening {
        Minimal => "minimal",
        Standard => "standard",
        Strict => "strict",
    }
}

string_enum! {
    /// Installer baked into the image.
    pub enum InstallerType {
        Calamares => "calamares",
        Unattended => "unattended",
    }
}

string_enum! {
    /// Compliance baseline shared with a team.
    pub enum ComplianceProfile {
        None => "none",
        CisL1 => "cis-l1",
        Stig => "stig",
        Nist80053 => "nist-800-53",
    }
}

string_enum! {
    /// Where a team bundle is published.
    pub enum PublishTarget {
        Git => "git",
        Oci => "oci",
    }
}

string_enum! {
    /// Initial password policy for a user account.
    pub enum UserPassword {
        Locked => "locked",
        Prompt => "prompt",
    }
}

string_enum! {
    /// Kernel flavor requested for the base.
    pub enum KernelFlavor {
        Lts => "lts",
        Stable => "stable",
        Mainline => "mainline",
        Hwe => "hwe",
    }
}

string_enum! {
    /// Assertions a scenario can run after boot.
    pub enum VerifyTest {
        Boot => "boot",
        Login => "login",
        Session => "session",
        Network => "network",
        Audio => "audio",
        Gpu => "gpu",
        Apps => "apps",
        Windows => "windows",
        Dev => "dev",
        Installer => "installer",
    }
}

fn default_firmware() -> Firmware {
    Firmware::Uefi
}

fn default_true() -> bool {
    true
}

fn default_password() -> UserPassword {
    UserPassword::Locked
}

fn default_disk_encryption() -> DiskEncryption {
    DiskEncryption::None
}

fn default_firewall() -> Firewall {
    Firewall::Nftables
}

fn default_hardening() -> Hardening {
    Hardening::Standard
}

fn default_compliance_profile() -> ComplianceProfile {
    ComplianceProfile::None
}
