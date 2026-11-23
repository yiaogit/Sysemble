//! Package mapping tables for the P0 planner.
//!
//! This is the only place where spec features become distribution package
//! names. P0 supports the Debian family only (Debian and Ubuntu); other bases
//! are rejected by [`crate::resolve_plan`] instead of being guessed at.
//!
//! The base layer is a minimum *bootable* set: kernel image, initramfs, udev,
//! dbus, console setup, locales/timezone, filesystem tools, and systemd as the
//! init process. Without these the rootfs cannot boot, so they are part of every
//! Debian-family plan; `system.packages.exclude` is the only way to remove them.
//!
//! P0 still does not map `system.kernel.flavor` (beyond the family/arch default
//! kernel), `system.services`, `dev.editors`, or locale/timezone/keyboard values
//! to further packages. Those are configuration inputs for the builder.

use crate::model::{
    Arch, BaseKind, DesktopSession, Dev, DevProfile, DiskEncryption, Firewall, Hardening,
    Installer, InstallerType, Security, Virtualization, WindowsMode,
};

/// Debian-family flavour. Ubuntu differs only where package names diverge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Family {
    Debian,
    Ubuntu,
}

impl Family {
    /// Map a schema base kind to a supported package family.
    pub(crate) fn from_base(kind: BaseKind) -> Option<Self> {
        match kind {
            BaseKind::Debian => Some(Family::Debian),
            BaseKind::Ubuntu => Some(Family::Ubuntu),
            BaseKind::Arch
            | BaseKind::Fedora
            | BaseKind::Opensuse
            | BaseKind::Alpine
            | BaseKind::Nixos
            | BaseKind::Lfs => None,
        }
    }

    /// Debian ships the ESR build; Ubuntu ships regular Firefox.
    fn firefox(self) -> &'static str {
        match self {
            Family::Debian => "firefox-esr",
            Family::Ubuntu => "firefox",
        }
    }
}

/// Kernel meta-package for a Debian-family base and target architecture.
///
/// Debian uses architecture-specific meta-packages; Ubuntu's generic kernel
/// meta-package covers its supported architectures.
fn kernel_package(family: Family, arch: Arch) -> &'static str {
    match (family, arch) {
        (Family::Debian, Arch::X86_64) => "linux-image-amd64",
        (Family::Debian, Arch::Aarch64) => "linux-image-arm64",
        (Family::Ubuntu, _) => "linux-image-generic",
    }
}

/// Minimum bootable package set every Debian-family image starts from.
///
/// The list is deduplicated and sorted later by [`crate::resolve_plan`], and an
/// explicit `system.packages.exclude` entry can still remove any of these
/// packages.
pub(crate) fn base_packages(family: Family, arch: Arch) -> Vec<&'static str> {
    let mut packages = vec![
        "apt",
        "ca-certificates",
        "console-setup",
        "dbus",
        "e2fsprogs",
        "initramfs-tools",
        "kmod",
        "locales",
        "sudo",
        "systemd",
        "systemd-sysv",
        "tzdata",
        "udev",
    ];
    packages.push(kernel_package(family, arch));
    packages
}

/// Session packages, including the canonical display manager for the session.
///
/// `desktop.display_manager` is advisory metadata in P0: the plan records it in
/// the spec but always installs the session's canonical manager (SDDM for
/// Plasma, GDM for GNOME, LightDM for Xfce). A spec that asks for a different
/// manager still plans cleanly; the builder decides whether to honour it.
pub(crate) fn desktop_packages(session: DesktopSession) -> &'static [&'static str] {
    match session {
        DesktopSession::None => &[],
        DesktopSession::Plasma => &[
            "plasma-desktop",
            "plasma-workspace",
            "kde-config-screenlocker",
            "sddm",
            "dolphin",
            "konsole",
        ],
        DesktopSession::Gnome => &[
            "gnome-shell",
            "gnome-session",
            "gdm3",
            "gnome-terminal",
            "nautilus",
        ],
        DesktopSession::Xfce => &["xfce4", "lightdm", "xfce4-terminal", "thunar"],
        DesktopSession::Hyprland => &["hyprland", "waybar", "xdg-desktop-portal-hyprland"],
        DesktopSession::Sway => &["sway", "swaybg", "waybar"],
    }
}

/// Map a `desktop.apps` entry to a package.
///
/// Known applications get an explicit package; anything else is assumed to
/// already be a package name and is passed through. That is a deliberate
/// escape hatch for P0 and should become a curated catalog later.
pub(crate) fn app_package(family: Family, app: &str) -> &str {
    if app.eq_ignore_ascii_case("firefox") {
        family.firefox()
    } else if app.eq_ignore_ascii_case("libreoffice") {
        "libreoffice"
    } else if app.eq_ignore_ascii_case("vlc") {
        "vlc"
    } else {
        app
    }
}

/// Packages for one `dev.profiles` entry.
pub(crate) fn dev_packages(family: Family, profile: DevProfile) -> &'static [&'static str] {
    match profile {
        DevProfile::Python => &["python3", "python3-venv", "python3-pip"],
        DevProfile::Node => &["nodejs", "npm"],
        // `cargo` comes from the distribution and pulls `rustc` with it. Using
        // the distro package keeps the toolchain inside the base snapshot pin;
        // `rustup` would download an unpinned toolchain on first use.
        DevProfile::Rust => &["cargo"],
        DevProfile::Go => match family {
            Family::Debian => &["golang"],
            Family::Ubuntu => &["golang-go"],
        },
        DevProfile::Ml => &[
            "python3",
            "python3-venv",
            "python3-pip",
            "python3-numpy",
            "python3-scipy",
        ],
        DevProfile::Embedded => &["build-essential", "gcc-arm-none-eabi", "openocd"],
    }
}

/// KVM/QEMU stack shared by the VM-based Windows modes.
const WINDOWS_VM_PACKAGES: [&str; 4] =
    ["qemu-system-x86", "libvirt-daemon-system", "ovmf", "swtpm"];

/// Packages for the selected Windows application mode.
pub(crate) fn windows_packages(mode: WindowsMode) -> Vec<&'static str> {
    match mode {
        WindowsMode::Wine => vec!["wine"],
        WindowsMode::RemoteApp => {
            let mut packages = WINDOWS_VM_PACKAGES.to_vec();
            packages.push("freerdp2-x11");
            packages
        }
        // A full Windows desktop window still needs the VM stack, but not
        // FreeRDP: the user interacts with the VM console directly.
        WindowsMode::Desktop => WINDOWS_VM_PACKAGES.to_vec(),
        WindowsMode::LookingGlass => {
            let mut packages = WINDOWS_VM_PACKAGES.to_vec();
            packages.push("looking-glass-client");
            packages
        }
    }
}

/// Packages implied by the security baseline.
pub(crate) fn security_packages(security: &Security) -> Vec<&'static str> {
    let mut packages = Vec::new();

    if security.disk_encryption == DiskEncryption::Luks {
        packages.push("cryptsetup");
    }
    if security.firewall == Firewall::Nftables {
        packages.push("nftables");
    }
    match security.hardening {
        Hardening::Minimal => {}
        Hardening::Standard => packages.push("unattended-upgrades"),
        Hardening::Strict => {
            packages.extend(["unattended-upgrades", "auditd", "apparmor"]);
        }
    }

    packages
}

/// Packages implied by the installer.
pub(crate) fn installer_packages(installer: &Installer) -> &'static [&'static str] {
    if !installer.enabled {
        return &[];
    }
    match installer.type_ {
        Some(InstallerType::Calamares) => &["calamares"],
        // The unattended installer is a first-boot service, not a package.
        Some(InstallerType::Unattended) | None => &[],
    }
}

/// Container tooling requested through either `virtualization.containers` or
/// `dev.containers`.
pub(crate) fn container_packages(
    virtualization: Option<&Virtualization>,
    dev: Option<&Dev>,
) -> Vec<&'static str> {
    let containers = virtualization.and_then(|virtualization| virtualization.containers.as_ref());

    let podman = containers.is_some_and(|containers| containers.podman)
        || dev.is_some_and(|dev| dev.containers);
    let distrobox = containers.is_some_and(|containers| containers.distrobox);

    let mut packages = Vec::new();
    if podman {
        packages.push("podman");
    }
    if distrobox {
        packages.push("distrobox");
    }
    packages
}
