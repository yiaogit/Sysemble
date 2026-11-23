//! Tests for plan resolution and the frozen plan JSON shape.

mod common;

use sysemble_core::{codes, resolve_plan, Arch, BaseKind, PlanError, PLAN_API_VERSION};

#[test]
fn debian_plan_contains_required_packages() {
    let spec = common::load_example("debian-kde-dev.yaml");
    let plan = resolve_plan(&spec).expect("the Debian example must plan");

    for package in [
        "plasma-desktop",
        "plasma-workspace",
        "sddm",
        "kde-config-screenlocker",
        "firefox-esr",
        "libreoffice",
        "vlc",
        "python3",
        "nodejs",
        "cargo",
        "qemu-system-x86",
        "freerdp2-x11",
        "cryptsetup",
        "nftables",
        "unattended-upgrades",
        "calamares",
    ] {
        assert!(
            plan.packages.iter().any(|candidate| candidate == package),
            "missing `{package}` from plan: {:?}",
            plan.packages
        );
    }

    assert!(
        !plan.packages.iter().any(|candidate| candidate == "firefox"),
        "Debian must use firefox-esr, not Ubuntu's firefox package"
    );
}

#[test]
fn debian_base_layer_is_bootable() {
    let plan = resolve_plan(&common::load_example("debian-kde-dev.yaml")).unwrap();

    for package in [
        "linux-image-amd64",
        "initramfs-tools",
        "systemd-sysv",
        "udev",
        "dbus",
        "console-setup",
        "locales",
        "tzdata",
        "kmod",
        "e2fsprogs",
    ] {
        assert!(
            plan.packages.iter().any(|candidate| candidate == package),
            "missing `{package}` from the bootable base layer: {:?}",
            plan.packages
        );
    }
}

#[test]
fn debian_aarch64_uses_the_arm64_kernel() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.target.arch = Arch::Aarch64;

    let plan = resolve_plan(&spec).unwrap();
    assert!(
        plan.packages
            .iter()
            .any(|package| package == "linux-image-arm64"),
        "aarch64 must use linux-image-arm64: {:?}",
        plan.packages
    );
    assert!(!plan
        .packages
        .iter()
        .any(|package| package == "linux-image-amd64"));
}

#[test]
fn plan_is_sorted_layered_and_carries_metadata() {
    let spec = common::load_example("debian-kde-dev.yaml");
    let plan = resolve_plan(&spec).expect("the Debian example must plan");

    assert_eq!(plan.api_version, PLAN_API_VERSION);
    assert_eq!(plan.spec, "debian-kde-dev");
    assert_eq!(plan.base.kind, BaseKind::Debian);
    assert_eq!(plan.base.release.as_deref(), Some("trixie"));
    assert_eq!(plan.base.pin.as_deref(), Some("2026-11-01"));
    assert_eq!(plan.target.arch.as_str(), "x86_64");
    assert_eq!(plan.target.outputs.len(), 2);

    let mut sorted = plan.packages.clone();
    sorted.sort();
    sorted.dedup();
    assert_eq!(plan.packages, sorted, "packages must be sorted and unique");

    assert!(plan.estimates.image_mb > 0);
    assert!(plan.estimates.build_minutes > 0);
    assert!(plan.estimates.disk_mb > plan.estimates.image_mb);

    let ids: Vec<&str> = plan
        .modules
        .iter()
        .map(|module| module.id.as_str())
        .collect();
    for expected in [
        "base-debian",
        "desktop-plasma",
        "windows-remoteapp",
        "dev-python",
        "dev-node",
        "dev-rust",
        "security",
        "containers",
        "installer",
    ] {
        assert!(
            ids.contains(&expected),
            "missing module `{expected}` in {ids:?}"
        );
    }
    assert!(
        plan.modules.iter().all(|module| module.version == "0.1.0"),
        "P0 module catalog is versioned 0.1.0"
    );

    assert!(
        plan.warnings.is_empty(),
        "the Debian example should have no warnings: {:?}",
        plan.warnings
    );
}

#[test]
fn plan_serializes_with_the_contract_shape() {
    let plan = resolve_plan(&common::load_example("debian-kde-dev.yaml")).unwrap();
    let value = serde_json::to_value(&plan).expect("plan must serialize");

    assert_eq!(value["apiVersion"], "sysemble/plan/v1");
    assert_eq!(value["spec"], "debian-kde-dev");
    assert_eq!(value["base"]["kind"], "debian");
    assert_eq!(value["base"]["release"], "trixie");
    assert_eq!(value["base"]["pin"], "2026-11-01");
    assert_eq!(value["target"]["arch"], "x86_64");
    assert_eq!(
        value["target"]["outputs"],
        serde_json::json!(["qcow2", "iso"])
    );
    assert!(value["packages"]
        .as_array()
        .unwrap()
        .iter()
        .any(|package| package == "plasma-desktop"));
    assert_eq!(value["modules"][0]["id"], "base-debian");
    assert_eq!(value["modules"][0]["version"], "0.1.0");
    assert!(value["estimates"]["image_mb"].is_u64());
    assert!(value["estimates"]["build_minutes"].is_u64());
    assert!(value["estimates"]["disk_mb"].is_u64());
    assert_eq!(value["warnings"], serde_json::json!([]));
}

#[test]
fn plan_carries_validation_warnings_but_not_errors() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.desktop.as_mut().unwrap().display_manager = None;

    let plan = resolve_plan(&spec).expect("warnings alone must not block a plan");

    assert_eq!(plan.warnings.len(), 1);
    assert_eq!(
        plan.warnings[0].code,
        codes::DESKTOP_DISPLAY_MANAGER_MISSING
    );
    assert_eq!(plan.warnings[0].path, "/desktop/display_manager");
    assert!(!plan
        .warnings
        .iter()
        .any(|warning| warning.code == codes::API_VERSION_UNSUPPORTED));

    let value = serde_json::to_value(&plan).unwrap();
    assert!(value["warnings"][0].get("severity").is_none());
}

#[test]
fn plan_rejects_invalid_specs_with_their_diagnostics() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.api_version = "sysemble/v9".to_string();

    let error = resolve_plan(&spec).expect_err("an invalid spec must not plan");
    assert!(matches!(error, PlanError::InvalidSpec { .. }));

    let found: Vec<&str> = error
        .validation_errors()
        .iter()
        .map(|diagnostic| diagnostic.code.as_str())
        .collect();
    assert!(
        found.contains(&codes::API_VERSION_UNSUPPORTED),
        "diagnostics should be carried on the error: {found:?}"
    );
    assert!(error.to_string().contains("validation error"));
}

#[test]
fn plan_names_unsupported_bases_explicitly() {
    let spec = common::load_example("minimal-alpine.yaml");
    let error = resolve_plan(&spec).expect_err("Alpine is outside the P0 planner");

    match &error {
        PlanError::UnsupportedBase { kind } => assert_eq!(*kind, BaseKind::Alpine),
        other => panic!("expected UnsupportedBase, got {other}"),
    }
    assert!(error.validation_errors().is_empty());
}

#[test]
fn ubuntu_uses_ubuntu_package_names() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    spec.target.base.kind = BaseKind::Ubuntu;
    spec.target.base.release = Some("noble".to_string());
    spec.desktop.as_mut().unwrap().apps = vec!["firefox".to_string()];

    let plan = resolve_plan(&spec).unwrap();
    assert!(plan.packages.iter().any(|package| package == "firefox"));
    assert!(!plan.packages.iter().any(|package| package == "firefox-esr"));
    assert!(
        plan.packages
            .iter()
            .any(|package| package == "linux-image-generic"),
        "Ubuntu must use linux-image-generic: {:?}",
        plan.packages
    );
    assert!(!plan
        .packages
        .iter()
        .any(|package| package == "linux-image-amd64"));
    assert_eq!(plan.base.kind, BaseKind::Ubuntu);
}

#[test]
fn system_package_excludes_are_applied() {
    let mut spec = common::load_example("debian-kde-dev.yaml");
    let excluded = ["vlc", "linux-image-amd64", "initramfs-tools"];
    spec.system.packages.as_mut().unwrap().exclude =
        excluded.iter().map(|package| package.to_string()).collect();

    let plan = resolve_plan(&spec).unwrap();
    for package in excluded {
        assert!(
            !plan.packages.iter().any(|candidate| candidate == package),
            "excluded package `{package}` must not reach the builder"
        );
    }
}
