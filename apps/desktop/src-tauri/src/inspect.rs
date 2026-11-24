//! Layer canvas and declared-to-resolved diff for the desktop shell (P1-c).
//!
//! [`inspect_spec`] loads a spec exactly like the `plan` command and then
//! derives a presentation model on top of [`sysemble_core::Plan`]:
//!
//! - six [`Layer`] cards that describe the *declared* spec;
//! - a compact [`PlanSummary`] with the resolved package count and estimates;
//! - a [`DiffItem`] list pairing each plan module with the feature that
//!   requested it, plus the warnings the planner carried forward.
//!
//! This module deliberately does not modify or reinterpret the plan: if the
//! planner cannot resolve a spec (for example Alpine is valid but outside the
//! P0 planner), inspection returns the planner's readable error instead of
//! inventing package numbers.

use serde::Serialize;
use sysemble_core::{
    load_spec, resolve_plan, BuildSpec, DesktopSession, DiskEncryption, Firewall, Hardening, Plan,
};

use crate::resolve_path;

/// Maximum number of real items rendered per layer before the remainder is
/// collapsed into a `+N more` line.
const MAX_LAYER_ITEMS: usize = 8;

/// One card in the left-hand layer canvas.
///
/// `items` are presentation strings, not normalized spec values: this is the
/// "declared view" the P1-c contract calls for. `estimated_mb` is reserved for
/// a future per-layer sizing model; core only provides aggregate estimates, so
/// every layer currently serializes `null`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Layer {
    pub id: String,
    pub title: String,
    pub items: Vec<String>,
    pub estimated_mb: Option<u64>,
}

/// The plan numbers the inspector shows next to the layer cards.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PlanSummary {
    /// Number of resolved packages (`plan.packages.len()`).
    pub packages: usize,
    pub image_mb: u64,
    pub build_minutes: u64,
    /// Resolved module ids in build order.
    pub modules: Vec<String>,
}

/// Severity of a diff row. Resolved rows are module mappings; warning rows are
/// planner warnings propagated from validation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum DiffKind {
    Resolved,
    Warning,
}

/// One line in the declared-to-resolved diff list.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DiffItem {
    pub kind: DiffKind,
    pub text: String,
}

/// Everything the P1-c UI needs for one spec.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Inspect {
    pub layers: Vec<Layer>,
    pub plan: PlanSummary,
    pub diff: Vec<DiffItem>,
}

/// Load `path`, resolve its plan, and derive the inspector payload.
///
/// # Errors
///
/// Returns a readable string when the spec cannot be read, parsed, validated,
/// or planned. In particular, a valid base outside the P0 planner (Alpine,
/// Arch, Fedora, ...) produces an error containing `not supported` so the UI
/// can show the same explanation as the CLI.
pub fn inspect_spec(path: &str) -> Result<Inspect, String> {
    let resolved = resolve_path(path);
    let spec = load_spec(&resolved).map_err(|error| format!("cannot inspect `{path}`: {error}"))?;
    let plan = resolve_plan(&spec).map_err(|error| format!("cannot inspect `{path}`: {error}"))?;
    Ok(inspect_value(&spec, &plan))
}

/// Pure derivation used by [`inspect_spec`] and the unit tests.
fn inspect_value(spec: &BuildSpec, plan: &Plan) -> Inspect {
    Inspect {
        layers: layers(spec),
        plan: plan_summary(plan),
        diff: diff(plan),
    }
}

/// Build the six declared-view layers in their fixed canvas order:
/// target -> system -> desktop -> virtualization -> dev -> security.
fn layers(spec: &BuildSpec) -> Vec<Layer> {
    vec![
        layer("target", "Target", target_items(spec)),
        layer("system", "System", system_items(spec)),
        layer("desktop", "Desktop", desktop_items(spec)),
        layer(
            "virtualization",
            "Virtualization",
            virtualization_items(spec),
        ),
        layer("dev", "Development", dev_items(spec)),
        layer("security", "Security", security_items(spec)),
    ]
}

fn layer(id: &str, title: &str, items: Vec<String>) -> Layer {
    Layer {
        id: id.to_string(),
        title: title.to_string(),
        items: limit_items(items),
        estimated_mb: None,
    }
}

/// Keep at most [`MAX_LAYER_ITEMS`] real items and append `+N more` when the
/// layer had to be truncated.
fn limit_items(mut items: Vec<String>) -> Vec<String> {
    if items.len() > MAX_LAYER_ITEMS {
        let hidden = items.len() - MAX_LAYER_ITEMS;
        items.truncate(MAX_LAYER_ITEMS);
        items.push(format!("+{hidden} more"));
    }
    items
}

fn target_items(spec: &BuildSpec) -> Vec<String> {
    let base = &spec.target.base;
    let base_text = match base
        .release
        .as_deref()
        .map(str::trim)
        .filter(|release| !release.is_empty())
    {
        Some(release) => format!("{} {release}", base.kind),
        None => format!("{} (no release)", base.kind),
    };

    let outputs = if spec.target.output.is_empty() {
        "no outputs".to_string()
    } else {
        spec.target
            .output
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(", ")
    };

    vec![base_text, spec.target.arch.to_string(), outputs]
}

fn system_items(spec: &BuildSpec) -> Vec<String> {
    let kernel = spec
        .system
        .kernel
        .as_ref()
        .and_then(|kernel| kernel.flavor)
        .map_or_else(
            || "kernel default".to_string(),
            |flavor| format!("kernel {flavor}"),
        );

    let declared_packages = spec
        .system
        .packages
        .as_ref()
        .map_or(0, |packages| packages.include.len());

    vec![
        kernel,
        count_label(spec.system.services.len(), "service", "services"),
        count_label(declared_packages, "package", "packages"),
    ]
}

fn desktop_items(spec: &BuildSpec) -> Vec<String> {
    let Some(desktop) = &spec.desktop else {
        return vec!["no desktop".to_string()];
    };
    let Some(session) = desktop.session else {
        return vec!["no desktop".to_string()];
    };
    if session == DesktopSession::None {
        return vec!["no desktop".to_string()];
    }

    vec![
        session.as_str().to_string(),
        desktop
            .display_manager
            .clone()
            .unwrap_or_else(|| "no display manager".to_string()),
        count_label(desktop.apps.len(), "app", "apps"),
    ]
}

fn virtualization_items(spec: &BuildSpec) -> Vec<String> {
    let mut items = Vec::new();

    let windows = spec
        .virtualization
        .as_ref()
        .and_then(|virtualization| virtualization.windows.as_ref());
    match windows {
        Some(windows) if windows.enabled => {
            let mut text = match windows.mode {
                Some(mode) => format!("Windows {}", mode.as_str()),
                None => "Windows (mode unset)".to_string(),
            };
            if let Some(edition) = windows.edition {
                text.push_str(&format!(" · {}", edition.as_str()));
            }
            if windows.gpu_passthrough {
                text.push_str(" · GPU passthrough");
            }
            items.push(text);
        }
        _ => items.push("no Windows VM".to_string()),
    }

    let containers = spec
        .virtualization
        .as_ref()
        .and_then(|virtualization| virtualization.containers.as_ref());
    // Mirrors core's container_packages(): `dev.containers` defaults to true
    // and therefore also pulls in Podman even without a virtualization block.
    let podman = containers.is_some_and(|containers| containers.podman)
        || spec.dev.as_ref().is_some_and(|dev| dev.containers);
    let distrobox = containers.is_some_and(|containers| containers.distrobox);

    let mut tools = Vec::new();
    if podman {
        tools.push("podman");
    }
    if distrobox {
        tools.push("distrobox");
    }
    if !tools.is_empty() {
        items.push(format!("containers: {}", tools.join(", ")));
    } else if containers.is_some() {
        items.push("containers: none".to_string());
    }

    items
}

fn dev_items(spec: &BuildSpec) -> Vec<String> {
    let Some(dev) = &spec.dev else {
        return vec!["no profiles".to_string()];
    };

    let mut items = Vec::new();
    if !dev.profiles.is_empty() {
        let profiles = dev
            .profiles
            .iter()
            .map(|profile| profile.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        items.push(format!("profiles: {profiles}"));
    }
    if !dev.editors.is_empty() {
        items.push(format!("editors: {}", dev.editors.join(", ")));
    }
    if items.is_empty() {
        items.push("no profiles".to_string());
    }
    items
}

fn security_items(spec: &BuildSpec) -> Vec<String> {
    let security = spec.security.as_ref();

    // Absent `security` uses the schema defaults: no encryption, nftables,
    // and standard hardening.
    let encryption = match security.map(|security| security.disk_encryption) {
        Some(DiskEncryption::Luks) => "luks encryption".to_string(),
        _ => "no encryption".to_string(),
    };
    let firewall = match security.map(|security| security.firewall) {
        Some(Firewall::None) => "no firewall".to_string(),
        _ => "nftables".to_string(),
    };
    let hardening = security.map_or(Hardening::Standard, |security| security.hardening);

    vec![encryption, firewall, format!("{hardening} hardening")]
}

fn count_label(count: usize, singular: &str, plural: &str) -> String {
    if count == 1 {
        format!("{count} {singular}")
    } else {
        format!("{count} {plural}")
    }
}

fn plan_summary(plan: &Plan) -> PlanSummary {
    PlanSummary {
        packages: plan.packages.len(),
        image_mb: plan.estimates.image_mb,
        build_minutes: plan.estimates.build_minutes,
        modules: plan
            .modules
            .iter()
            .map(|module| module.id.clone())
            .collect(),
    }
}

/// Resolved module mappings first, then planner warnings, matching the order
/// the UI renders.
fn diff(plan: &Plan) -> Vec<DiffItem> {
    let mut items: Vec<DiffItem> = plan
        .modules
        .iter()
        .map(|module| DiffItem {
            kind: DiffKind::Resolved,
            text: format!("{} -> module {}", feature_for(&module.id), module.id),
        })
        .collect();

    items.extend(plan.warnings.iter().map(|warning| DiffItem {
        kind: DiffKind::Warning,
        text: format!("{} ({}): {}", warning.code, warning.path, warning.message),
    }));

    items
}

/// Name the declared field (or layer) that produced a module id.
fn feature_for(module: &str) -> String {
    if let Some(kind) = module.strip_prefix("base-") {
        format!("target.base.kind={kind}")
    } else if let Some(session) = module.strip_prefix("desktop-") {
        format!("desktop.session={session}")
    } else if let Some(mode) = module.strip_prefix("windows-") {
        format!("virtualization.windows={mode}")
    } else if let Some(profile) = module.strip_prefix("dev-") {
        format!("dev.profiles={profile}")
    } else if module == "security" {
        "security".to_string()
    } else if module == "containers" {
        "containers".to_string()
    } else if module == "installer" {
        "installer.enabled=true".to_string()
    } else {
        "plan".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};
    use sysemble_core::PlanWarning;

    fn repo_root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../..")
            .canonicalize()
            .expect("repository root should exist")
    }

    fn example(name: &str) -> String {
        repo_root()
            .join("examples")
            .join(name)
            .to_string_lossy()
            .into_owned()
    }

    fn layer<'a>(inspect: &'a Inspect, id: &str) -> &'a Layer {
        inspect
            .layers
            .iter()
            .find(|layer| layer.id == id)
            .unwrap_or_else(|| panic!("missing layer `{id}`"))
    }

    #[test]
    fn debian_xfce_inspects_six_declared_layers_and_a_non_empty_plan() {
        let inspect =
            inspect_spec(&example("debian-xfce.yaml")).expect("xfce example should inspect");

        let ids: Vec<&str> = inspect
            .layers
            .iter()
            .map(|layer| layer.id.as_str())
            .collect();
        assert_eq!(
            ids,
            [
                "target",
                "system",
                "desktop",
                "virtualization",
                "dev",
                "security"
            ],
            "layers must stay in canvas order"
        );

        let target = layer(&inspect, "target");
        assert!(
            target.items.iter().any(|item| item.contains("trixie")),
            "target should name the release: {target:?}"
        );
        let desktop = layer(&inspect, "desktop");
        assert!(
            desktop.items.iter().any(|item| item.contains("xfce")),
            "desktop should name the session: {desktop:?}"
        );

        assert!(inspect.plan.packages > 0, "plan should have packages");
        assert!(inspect.plan.image_mb > 0, "plan should have an estimate");
        assert!(inspect.plan.build_minutes > 0);
        assert!(
            inspect.plan.modules.iter().any(|id| id == "desktop-xfce"),
            "plan modules: {:?}",
            inspect.plan.modules
        );

        assert!(
            inspect
                .diff
                .iter()
                .any(|item| item.kind == DiffKind::Resolved),
            "diff should contain a resolved module: {:?}",
            inspect.diff
        );
        let desktop_diff = inspect
            .diff
            .iter()
            .find(|item| item.text == "desktop.session=xfce -> module desktop-xfce")
            .expect("desktop module should map back to desktop.session");
        assert_eq!(desktop_diff.kind, DiffKind::Resolved);

        for layer in &inspect.layers {
            assert!(
                layer.items.len() <= MAX_LAYER_ITEMS + 1,
                "layer `{}` was not truncated: {:?}",
                layer.id,
                layer.items
            );
        }

        let json = serde_json::to_value(&inspect).expect("inspect should serialize");
        assert!(json["layers"].is_array());
        assert!(json["plan"]["packages"].is_number());
        assert!(json["diff"].is_array());

        eprintln!(
            "Inspect={}",
            serde_json::to_string_pretty(&inspect).expect("inspect should serialize")
        );
    }

    #[test]
    fn alpine_is_valid_but_inspection_reports_unsupported_planning() {
        let path = example("minimal-alpine.yaml");

        let diagnostics = crate::validate_spec_path(&path).expect("alpine example should load");
        assert!(
            diagnostics.iter().all(|diagnostic| !diagnostic.is_error()),
            "alpine example should validate without errors: {diagnostics:#?}"
        );

        let error = inspect_spec(&path).expect_err("alpine has no P0 plan");
        assert!(
            error.contains("not supported"),
            "error should explain the unsupported base: {error}"
        );
        assert!(
            error.contains("alpine") || error.contains("minimal-alpine.yaml"),
            "error should name the base or the path: {error}"
        );
        eprintln!("Inspect error={error}");

        // Layers are still derivable from the declared spec even though the
        // command as a whole refuses to invent a plan.
        let spec = load_spec(Path::new(&path)).expect("alpine example should load");
        let layers = layers(&spec);
        assert_eq!(layers.len(), 6);
        assert_eq!(layers[2].items, vec!["no desktop".to_string()]);
        assert_eq!(layers[3].items, vec!["no Windows VM".to_string()]);
        assert_eq!(layers[4].items, vec!["no profiles".to_string()]);
    }

    #[test]
    fn long_layers_collapse_into_a_remainder_line() {
        let items = (0..10).map(|index| format!("item {index}")).collect();
        let items = limit_items(items);

        assert_eq!(items.len(), MAX_LAYER_ITEMS + 1);
        assert_eq!(items[0], "item 0");
        assert_eq!(items[MAX_LAYER_ITEMS], "+2 more");

        let short = limit_items(vec!["one".to_string()]);
        assert_eq!(short, vec!["one".to_string()]);
    }

    #[test]
    fn plan_warnings_become_warning_diff_rows() {
        let path = example("debian-xfce.yaml");
        let spec = load_spec(Path::new(&path)).expect("xfce example should load");
        let mut plan = resolve_plan(&spec).expect("xfce example should plan");
        plan.warnings.push(PlanWarning {
            code: "spec.test.warning".to_string(),
            path: "/target/base/release".to_string(),
            message: "a synthetic warning".to_string(),
        });

        let items = diff(&plan);
        let warning = items
            .iter()
            .find(|item| item.kind == DiffKind::Warning)
            .expect("warning should be rendered");
        assert!(warning.text.contains("spec.test.warning"), "{warning:?}");
        assert!(warning.text.contains("a synthetic warning"), "{warning:?}");
        assert!(
            items.iter().any(|item| item.kind == DiffKind::Resolved),
            "resolved rows must still be present"
        );
    }

    #[test]
    fn missing_spec_is_a_readable_error() {
        let path = example("no-such-inspect-spec.yaml");
        let error = inspect_spec(&path).expect_err("missing spec must not inspect");
        assert!(error.contains(&path), "error should name the path: {error}");
    }
}
