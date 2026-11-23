//! Resolution of a validated spec into a concrete build plan.
//!
//! A plan is the contract between `sysemble-core` and the builders: package
//! names, module layers, rough estimates, and the warnings that survived
//! validation. It is deterministic for a given spec.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::error::PlanError;
use crate::model::{
    Arch, BaseKind, BuildSpec, DesktopSession, DevProfile, DiskEncryption, Firewall, Hardening,
    InstallerType, Output, WindowsMode,
};
use crate::packages::{
    app_package, base_packages, container_packages, desktop_packages, dev_packages,
    installer_packages, security_packages, windows_packages, Family,
};
use crate::validate::validate_spec;

/// Version of the resolved-plan JSON document.
pub const PLAN_API_VERSION: &str = "sysemble/plan/v1";

/// Version attached to every module entry in a P0 plan.
///
/// This is the module-catalog version, not the crate version. The P0 catalog is
/// frozen at `0.1.0`; once a module registry exists, each module gets its own
/// version and digest.
pub const MODULE_VERSION: &str = "0.1.0";

/// A resolved, reproducible build plan.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    #[serde(rename = "apiVersion")]
    pub api_version: String,
    /// `meta.name` of the spec this plan came from.
    pub spec: String,
    pub base: PlanBase,
    pub target: PlanTarget,
    /// Deduplicated and lexicographically sorted package names.
    pub packages: Vec<String>,
    pub modules: Vec<PlanModule>,
    pub estimates: Estimates,
    /// Warnings from [`validate_spec`]; errors are never copied here because a
    /// spec with errors cannot produce a plan.
    pub warnings: Vec<PlanWarning>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanBase {
    pub kind: BaseKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pin: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanTarget {
    pub arch: Arch,
    pub outputs: Vec<Output>,
}

/// One layer in the resolved plan.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanModule {
    pub id: String,
    pub version: String,
}

impl PlanModule {
    fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            version: MODULE_VERSION.to_string(),
        }
    }
}

/// Rough sizing for the UI. These are sanity checks, not build budgets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Estimates {
    pub image_mb: u64,
    pub build_minutes: u64,
    pub disk_mb: u64,
}

/// A warning carried from validation into the plan.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlanWarning {
    pub code: String,
    pub path: String,
    pub message: String,
}

/// Resolve a spec into a plan.
///
/// # Errors
///
/// - [`PlanError::InvalidSpec`] when [`validate_spec`] reports any error. The
///   diagnostics are attached so the caller can print them.
/// - [`PlanError::UnsupportedBase`] for valid bases outside the P0 planner's
///   Debian/Ubuntu support. Guessing package names for another distribution
///   would produce a plausible-looking but wrong plan.
///
/// `system.packages.exclude` is applied to the resolved package list, so the
/// builder only ever sees the final set. Excluding a package that a layer
/// requires is allowed, but the resulting image may not provide that feature.
pub fn resolve_plan(spec: &BuildSpec) -> Result<Plan, PlanError> {
    let diagnostics = validate_spec(spec);

    let errors: Vec<_> = diagnostics
        .iter()
        .filter(|diagnostic| diagnostic.is_error())
        .cloned()
        .collect();
    if !errors.is_empty() {
        return Err(PlanError::InvalidSpec { errors });
    }

    let family = Family::from_base(spec.target.base.kind).ok_or(PlanError::UnsupportedBase {
        kind: spec.target.base.kind,
    })?;

    let mut packages: Vec<&str> = Vec::new();
    packages.extend(base_packages(family, spec.target.arch));

    if let Some(system_packages) = &spec.system.packages {
        packages.extend(system_packages.include.iter().map(String::as_str));
    }

    if let Some(desktop) = &spec.desktop {
        if let Some(session) = desktop.session {
            packages.extend(desktop_packages(session).iter().copied());
        }
        packages.extend(desktop.apps.iter().map(|app| app_package(family, app)));
    }

    if let Some(dev) = &spec.dev {
        for profile in &dev.profiles {
            packages.extend(dev_packages(family, *profile).iter().copied());
        }
    }

    if let Some(windows) = spec
        .virtualization
        .as_ref()
        .and_then(|virtualization| virtualization.windows.as_ref())
    {
        if windows.enabled {
            if let Some(mode) = windows.mode {
                packages.extend(windows_packages(mode));
            }
        }
    }

    if let Some(security) = &spec.security {
        packages.extend(security_packages(security));
    }

    if let Some(installer) = &spec.installer {
        packages.extend(installer_packages(installer).iter().copied());
    }

    packages.extend(container_packages(
        spec.virtualization.as_ref(),
        spec.dev.as_ref(),
    ));

    let mut packages: Vec<String> = packages.into_iter().map(str::to_string).collect();
    if let Some(system_packages) = &spec.system.packages {
        packages.retain(|package| !system_packages.exclude.contains(package));
    }
    packages.sort_unstable();
    packages.dedup();

    let warnings = diagnostics
        .iter()
        .filter(|diagnostic| diagnostic.is_warning())
        .map(|diagnostic| PlanWarning {
            code: diagnostic.code.clone(),
            path: diagnostic.path.clone(),
            message: diagnostic.message.clone(),
        })
        .collect();

    Ok(Plan {
        api_version: PLAN_API_VERSION.to_string(),
        spec: spec.meta.name.clone(),
        base: PlanBase {
            kind: spec.target.base.kind,
            release: spec.target.base.release.clone(),
            pin: spec.target.base.pin.clone(),
        },
        target: PlanTarget {
            arch: spec.target.arch,
            outputs: spec.target.output.clone(),
        },
        estimates: estimate(spec, packages.len()),
        packages,
        modules: plan_modules(spec),
        warnings,
    })
}

/// Layers are listed in build order: base, desktop, Windows, dev, then the
/// cross-cutting security/container/installer layers. Duplicate dev profiles
/// are already warned about by validation and are listed once here.
fn plan_modules(spec: &BuildSpec) -> Vec<PlanModule> {
    let mut modules = vec![PlanModule::new(format!("base-{}", spec.target.base.kind))];

    if let Some(desktop) = &spec.desktop {
        if let Some(session) = desktop.session {
            if session != DesktopSession::None {
                modules.push(PlanModule::new(format!("desktop-{session}")));
            }
        }
    }

    if let Some(windows) = spec
        .virtualization
        .as_ref()
        .and_then(|virtualization| virtualization.windows.as_ref())
    {
        if windows.enabled {
            if let Some(mode) = windows.mode {
                modules.push(PlanModule::new(format!("windows-{mode}")));
            }
        }
    }

    if let Some(dev) = &spec.dev {
        let mut seen = HashSet::new();
        for profile in &dev.profiles {
            if seen.insert(*profile) {
                modules.push(PlanModule::new(format!("dev-{profile}")));
            }
        }
    }

    if let Some(security) = &spec.security {
        if !security_packages(security).is_empty() {
            modules.push(PlanModule::new("security"));
        }
    }

    if !container_packages(spec.virtualization.as_ref(), spec.dev.as_ref()).is_empty() {
        modules.push(PlanModule::new("containers"));
    }

    if spec
        .installer
        .as_ref()
        .is_some_and(|installer| installer.enabled)
    {
        modules.push(PlanModule::new("installer"));
    }

    modules
}

// ---------------------------------------------------------------------------
// Rough sizing model.
//
// The numbers are simple and additive on purpose: they give the UI an order of
// magnitude to display, and are not a build budget or a promise. Weights are
// eyeballed from P0 Debian images.
//
//   image_mb      = base rootfs
//                 + desktop session (Plasma/GNOME are the heavy ones)
//                 + applications
//                 + Windows virtualization stack
//                 + dev profiles
//                 + security, containers, and installer extras
//                 + 6 MiB per resolved package (configuration and docs)
//   build_minutes = base download/unpack
//                 + per-layer install time
//                 + 1 minute per 20 packages
//   disk_mb       = 2 x image_mb (image plus build cache) + 1 GiB headroom
//
// `windows.vm.disk_gb` is deliberately not included: the Windows disk is
// allocated on the target machine at first boot, not inside the built image.
// ---------------------------------------------------------------------------

const BASE_IMAGE_MB: u64 = 420;
const BASE_BUILD_MINUTES: u64 = 6;
const PACKAGE_IMAGE_MB: u64 = 6;
const PACKAGES_PER_MINUTE: u64 = 20;

fn estimate(spec: &BuildSpec, package_count: usize) -> Estimates {
    let mut image_mb = BASE_IMAGE_MB;
    let mut build_minutes = BASE_BUILD_MINUTES;

    if let Some(desktop) = &spec.desktop {
        if let Some(session) = desktop.session {
            let (image, minutes) = match session {
                DesktopSession::None => (0, 0),
                DesktopSession::Plasma => (1900, 14),
                DesktopSession::Gnome => (1600, 12),
                DesktopSession::Xfce => (750, 7),
                DesktopSession::Hyprland => (1000, 9),
                DesktopSession::Sway => (800, 8),
            };
            image_mb += image;
            build_minutes += minutes;
        }
        for app in &desktop.apps {
            image_mb += app_image_mb(app);
        }
    }

    if let Some(windows) = spec
        .virtualization
        .as_ref()
        .and_then(|virtualization| virtualization.windows.as_ref())
    {
        if windows.enabled {
            if let Some(mode) = windows.mode {
                let (image, minutes) = match mode {
                    WindowsMode::Wine => (400, 2),
                    WindowsMode::RemoteApp => (280, 8),
                    WindowsMode::Desktop => (250, 8),
                    WindowsMode::LookingGlass => (180, 12),
                };
                image_mb += image;
                build_minutes += minutes;
            }
        }
    }

    if let Some(dev) = &spec.dev {
        for profile in &dev.profiles {
            let (image, minutes) = match profile {
                DevProfile::Python => (280, 2),
                DevProfile::Node => (240, 2),
                DevProfile::Rust => (650, 5),
                DevProfile::Go => (450, 3),
                DevProfile::Ml => (1800, 8),
                DevProfile::Embedded => (300, 3),
            };
            image_mb += image;
            build_minutes += minutes;
        }
    }

    if let Some(security) = &spec.security {
        if security.disk_encryption == DiskEncryption::Luks {
            image_mb += 15;
            build_minutes += 2;
        }
        if security.firewall == Firewall::Nftables {
            image_mb += 15;
            build_minutes += 1;
        }
        match security.hardening {
            Hardening::Minimal => {}
            Hardening::Standard => {
                image_mb += 30;
                build_minutes += 1;
            }
            Hardening::Strict => {
                image_mb += 60;
                build_minutes += 2;
            }
        }
    }

    let containers = container_packages(spec.virtualization.as_ref(), spec.dev.as_ref());
    if containers.contains(&"podman") {
        image_mb += 250;
        build_minutes += 3;
    }
    if containers.contains(&"distrobox") {
        image_mb += 20;
        build_minutes += 1;
    }

    if let Some(installer) = &spec.installer {
        if installer.enabled {
            match installer.type_ {
                Some(InstallerType::Calamares) => {
                    image_mb += 120;
                    build_minutes += 3;
                }
                Some(InstallerType::Unattended) => build_minutes += 1,
                None => {}
            }
        }
    }

    image_mb += PACKAGE_IMAGE_MB * package_count as u64;
    build_minutes += (package_count as u64) / PACKAGES_PER_MINUTE;

    let image_mb = round_to_10(image_mb);
    let disk_mb = image_mb * 2 + 1024;
    Estimates {
        image_mb,
        build_minutes: build_minutes.max(1),
        disk_mb,
    }
}

fn app_image_mb(app: &str) -> u64 {
    if app.eq_ignore_ascii_case("firefox") || app.eq_ignore_ascii_case("firefox-esr") {
        260
    } else if app.eq_ignore_ascii_case("libreoffice") {
        450
    } else if app.eq_ignore_ascii_case("vlc") {
        90
    } else {
        60
    }
}

fn round_to_10(value: u64) -> u64 {
    ((value + 5) / 10) * 10
}
