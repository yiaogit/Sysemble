(() => {
  "use strict";

  const tauri = window.__TAURI__;
  const invoke =
    tauri && tauri.core && typeof tauri.core.invoke === "function"
      ? tauri.core.invoke.bind(tauri.core)
      : null;

  const els = {
    path: document.getElementById("spec-path"),
    status: document.getElementById("status"),
    bridgeWarning: document.getElementById("bridge-warning"),
    source: document.getElementById("spec-source"),
    specMeta: document.getElementById("spec-meta"),
    diagnostics: document.getElementById("diagnostics"),
    diagnosticsMeta: document.getElementById("diagnostics-meta"),
    plan: document.getElementById("plan"),
    planMeta: document.getElementById("plan-meta"),
    load: document.getElementById("load-btn"),
    validate: document.getElementById("validate-btn"),
    planButton: document.getElementById("plan-btn"),
  };

  const buttons = [els.load, els.validate, els.planButton];
  let busy = false;

  function setStatus(message, kind = "idle") {
    els.status.textContent = message;
    els.status.title = message;
    els.status.className = `status ${kind}`;
  }

  function setBusy(value) {
    busy = value;
    for (const button of buttons) {
      button.disabled = !invoke || busy;
    }
    els.path.disabled = !invoke || busy;
  }

  function formatError(error) {
    if (typeof error === "string") return error;
    if (error && typeof error.message === "string") return error.message;
    try {
      return JSON.stringify(error);
    } catch {
      return String(error);
    }
  }

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = text;
    return node;
  }

  function appendFact(list, term, value) {
    const row = document.createElement("div");
    row.append(el("dt", null, term), el("dd", null, value));
    list.append(row);
  }

  function setMeta(node, text) {
    node.textContent = text;
    node.title = text;
  }

  function renderSource(text, path) {
    els.source.textContent = text;
    const lines = text.split("\n").length;
    const bytes = new TextEncoder().encode(text).length;
    setMeta(els.specMeta, `${lines} lines · ${bytes} B · ${path}`);
  }

  function stat(value, label) {
    const node = el("div", "stat");
    node.append(el("span", "stat-value", String(value)), el("span", "stat-label", label));
    return node;
  }

  function renderDiagnostics(diagnostics, path) {
    const container = els.diagnostics;
    container.replaceChildren();

    const errors = diagnostics.filter((item) => item.severity === "error").length;
    const warnings = diagnostics.length - errors;

    if (diagnostics.length === 0) {
      container.append(
        el("p", "empty", "No diagnostics. The spec is valid and ready to plan."),
      );
      setMeta(els.diagnosticsMeta, "0 findings");
      setStatus(`Valid · ${path}`, "ok");
      return;
    }

    for (const diagnostic of diagnostics) {
      const severity = diagnostic.severity === "warning" ? "warning" : "error";
      const item = el("article", `diagnostic ${severity}`);

      const head = el("div", "diagnostic-head");
      head.append(
        el("span", "badge", severity),
        el("code", "code", diagnostic.code || "spec"),
      );
      if (diagnostic.path) head.append(el("span", "pointer", diagnostic.path));

      item.append(head, el("p", null, diagnostic.message || ""));
      container.append(item);
    }

    setMeta(els.diagnosticsMeta, `${errors} error(s) · ${warnings} warning(s)`);
    const summary = `${errors} error(s), ${warnings} warning(s)`;
    setStatus(summary, errors > 0 ? "error" : "warn");
  }

  function renderPlan(plan) {
    const packages = Array.isArray(plan.packages) ? plan.packages : [];
    const modules = Array.isArray(plan.modules) ? plan.modules : [];
    const warnings = Array.isArray(plan.warnings) ? plan.warnings : [];
    const estimates = plan.estimates || {};

    const card = el("div", "plan-card");

    const grid = el("div", "stat-grid");
    grid.append(
      stat(packages.length, "packages"),
      stat(`${estimates.image_mb ?? "?"} MB`, "image"),
      stat(`${estimates.build_minutes ?? "?"} min`, "build"),
      stat(modules.length, "modules"),
    );
    card.append(grid);

    const facts = el("dl", "plan-facts");
    appendFact(facts, "spec", plan.spec || "—");
    const base = [plan.base && plan.base.kind, plan.base && plan.base.release]
      .filter(Boolean)
      .join(" ");
    appendFact(facts, "base", base || "—");
    const target = plan.target
      ? [plan.target.arch, ...(plan.target.outputs || [])].filter(Boolean).join(" · ")
      : "";
    appendFact(facts, "target", target || "—");
    if (estimates.disk_mb !== undefined) {
      appendFact(facts, "disk", `${estimates.disk_mb} MB`);
    }
    card.append(facts);

    card.append(el("h3", null, "Modules"));
    const moduleList = el("div", "chips");
    if (modules.length === 0) {
      moduleList.append(el("span", "empty-inline", "none"));
    }
    for (const module of modules) {
      moduleList.append(el("span", "chip", `${module.id}@${module.version}`));
    }
    card.append(moduleList);

    const shown = packages.slice(0, 20);
    card.append(el("h3", null, shown.length === 0 ? "Packages" : `First ${shown.length} packages`));
    const packageList = el("div", "packages");
    if (shown.length === 0) {
      packageList.append(el("span", "empty-inline", "none"));
    }
    for (const name of shown) {
      packageList.append(el("code", "package", name));
    }
    card.append(packageList);
    if (packages.length > shown.length) {
      card.append(el("p", "more", `+${packages.length - shown.length} more packages`));
    }

    if (warnings.length > 0) {
      card.append(el("h3", null, "Plan warnings"));
      const warningList = el("div", "plan-warnings");
      for (const warning of warnings) {
        warningList.append(
          el("p", "plan-warning", `${warning.code}: ${warning.message}`),
        );
      }
      card.append(warningList);
    }

    els.plan.replaceChildren(card);
    setMeta(
      els.planMeta,
      `${packages.length} packages · ${estimates.image_mb ?? "?"} MB · ${estimates.build_minutes ?? "?"} min`,
    );
    setStatus(
      `Planned ${plan.spec || ""} · ${packages.length} packages, ${estimates.image_mb ?? "?"} MB, ${estimates.build_minutes ?? "?"} min`,
      "ok",
    );
  }

  async function action(run) {
    if (!invoke) return;

    const path = els.path.value.trim();
    if (!path) {
      setStatus("Enter a spec path first.", "error");
      els.path.focus();
      return;
    }

    setBusy(true);
    try {
      await run(path);
    } catch (error) {
      setStatus(formatError(error), "error");
    } finally {
      setBusy(false);
    }
  }

  async function loadSpec(path) {
    setStatus(`Loading ${path}…`, "busy");
    const text = await invoke("read_spec", { path });
    renderSource(text, path);
    setStatus(`Loaded ${path}`, "ok");
  }

  async function validateSpec(path) {
    setStatus(`Validating ${path}…`, "busy");
    const diagnostics = await invoke("validate", { path });
    renderDiagnostics(diagnostics, path);
  }

  async function planSpec(path) {
    setStatus(`Planning ${path}…`, "busy");
    const plan = await invoke("plan", { path });
    renderPlan(plan);
  }

  els.load.addEventListener("click", () => action(loadSpec));
  els.validate.addEventListener("click", () => action(validateSpec));
  els.planButton.addEventListener("click", () => action(planSpec));

  els.path.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      action(validateSpec);
    }
  });

  if (!invoke) {
    els.bridgeWarning.hidden = false;
    setBusy(false);
    setStatus("Browser preview — Tauri IPC unavailable", "warn");
  } else {
    setBusy(false);
    setStatus("Ready", "idle");
  }
})();
