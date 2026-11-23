//! Tests for the semantic rules in `validate_spec`.

mod common;

use sysemble_core::{
    codes, validate_spec, Arch, BaseKind, DevProfile, Diagnostic, Firmware, Severity, WindowsMode,
};

fn find<'a>(diagnostics: &'a [Diagnostic], code: &str) -> &'a Diagnostic {
    diagnostics
        .iter()
        .find(|d| d.code == code)
        .unwrap_or_else(|| {
            let found: Vec<&str> = diagnostics.iter().map(|d| d.code.as_str()).collect();
            panic!("expected diagnostic `{code}`, found {found:?}");
        })
}

#[test]
fn examples_have_no_errors() {
    for name in ["debian-kde-dev.yaml", "minimal-alpine.yaml"] {
        let spec = common::load_example(name);
        let errors: Vec<Diagnostic> = validate_spec(&spec)
            .into_iter()
            .filter(|diagnostic| diagnostic.is_error())
            .collect();
        assert!(
            errors.is_empty(),
            "`{name}` should validate cleanly, got errors: {errors:?}"
        );
    }
}

#[test]
fn rejects_unknown_api_version() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.api_version = "sysemble/v9".to_string();

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::API_VERSION_UNSUPPORTED);
    assert_eq!(diagnostic.severity, Severity::Error);
    assert_eq!(diagnostic.path, "/apiVersion");
    assert!(diagnostic.message.contains("sysemble/v1"));
}

#[test]
fn rejects_invalid_meta_name_and_hostname() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.meta.name = "Bad_Name".to_string();
    spec.system.hostname = "-bad-host".to_string();

    let diagnostics = validate_spec(&spec);
    let name = find(&diagnostics, codes::META_NAME_INVALID);
    assert_eq!(name.severity, Severity::Error);
    assert_eq!(name.path, "/meta/name");

    let hostname = find(&diagnostics, codes::HOSTNAME_INVALID);
    assert_eq!(hostname.severity, Severity::Error);
    assert_eq!(hostname.path, "/system/hostname");
}

#[test]
fn warns_about_missing_base_release() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.target.base.release = None;

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::BASE_RELEASE_MISSING);
    assert_eq!(diagnostic.severity, Severity::Warning);
    assert_eq!(diagnostic.path, "/target/base/release");
}

#[test]
fn warns_about_lfs_builds() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.target.base.kind = BaseKind::Lfs;

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::BASE_LFS);
    assert_eq!(diagnostic.severity, Severity::Warning);
    assert_eq!(diagnostic.path, "/target/base/kind");
    assert!(diagnostic.message.contains("8-20"));
}

#[test]
fn warns_when_an_iso_is_requested_without_an_installer() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.installer.as_mut().unwrap().enabled = false;

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::INSTALLER_ISO);
    assert_eq!(diagnostic.severity, Severity::Warning);
    assert_eq!(diagnostic.path, "/target/output");
}

#[test]
fn warns_when_a_desktop_session_has_no_display_manager() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.desktop.as_mut().unwrap().display_manager = None;

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::DESKTOP_DISPLAY_MANAGER_MISSING);
    assert_eq!(diagnostic.severity, Severity::Warning);
    assert_eq!(diagnostic.path, "/desktop/display_manager");
}

#[test]
fn errors_when_windows_is_enabled_without_a_mode() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.virtualization
        .as_mut()
        .unwrap()
        .windows
        .as_mut()
        .unwrap()
        .mode = None;

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::WINDOWS_MODE_MISSING);
    assert_eq!(diagnostic.severity, Severity::Error);
    assert_eq!(diagnostic.path, "/virtualization/windows/mode");
}

#[test]
fn warns_about_remoteapp_without_a_windows_edition() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.virtualization
        .as_mut()
        .unwrap()
        .windows
        .as_mut()
        .unwrap()
        .edition = None;

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::WINDOWS_EDITION_REMOTEAPP);
    assert_eq!(diagnostic.severity, Severity::Warning);
    assert_eq!(diagnostic.path, "/virtualization/windows/edition");
    assert!(diagnostic.message.contains("Home"));
}

#[test]
fn warns_about_looking_glass_without_gpu_passthrough() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    let windows = spec
        .virtualization
        .as_mut()
        .unwrap()
        .windows
        .as_mut()
        .unwrap();
    windows.mode = Some(WindowsMode::LookingGlass);
    windows.gpu_passthrough = false;

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::WINDOWS_LOOKING_GLASS_GPU);
    assert_eq!(diagnostic.severity, Severity::Warning);
    assert_eq!(diagnostic.path, "/virtualization/windows/gpu_passthrough");
}

#[test]
fn warns_about_windows_on_aarch64() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.target.arch = Arch::Aarch64;

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::WINDOWS_ARCH_UNSUPPORTED);
    assert_eq!(diagnostic.severity, Severity::Warning);
    assert_eq!(diagnostic.path, "/virtualization/windows/enabled");
}

#[test]
fn warns_about_duplicate_dev_profiles() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.dev.as_mut().unwrap().profiles.push(DevProfile::Python);

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::DEV_PROFILES_DUPLICATE);
    assert_eq!(diagnostic.severity, Severity::Warning);
    assert_eq!(diagnostic.path, "/dev/profiles/3");
}

#[test]
fn errors_when_secure_boot_is_combined_with_bios() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.target.firmware = Firmware::Bios;

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::SECURE_BOOT_BIOS);
    assert_eq!(diagnostic.severity, Severity::Error);
    assert_eq!(diagnostic.path, "/security/secure_boot");
}

#[test]
fn errors_on_duplicate_user_names() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    let duplicate = spec.system.users[0].clone();
    spec.system.users.push(duplicate);

    let diagnostics = validate_spec(&spec);
    let diagnostic = find(&diagnostics, codes::USER_NAME_DUPLICATE);
    assert_eq!(diagnostic.severity, Severity::Error);
    assert_eq!(diagnostic.path, "/system/users/1/name");
}
