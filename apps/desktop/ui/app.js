(() => {
  "use strict";

  const tauri = window.__TAURI__;
  const invoke =
    tauri && tauri.core && typeof tauri.core.invoke === "function"
      ? tauri.core.invoke.bind(tauri.core)
      : null;

  const els = {
    path: document.getElementById("spec-path"),
    outDir: document.getElementById("out-dir"),
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
    dryRun: document.getElementById("dry-run-btn"),
    build: document.getElementById("build-btn"),
    cancel: document.getElementById("cancel-btn"),
    buildBadge: document.getElementById("build-badge"),
    buildExit: document.getElementById("build-exit"),
    buildMeta: document.getElementById("build-meta"),
    buildLog: document.getElementById("build-log"),
  };

  const BUILD_LOG_TAIL_LINES = 400;
  const BUILD_POLL_INTERVAL_MS = 1000;

  let busy = false;
  let buildRunning = false;
  let activeBuild = null;
  let pollTimer = null;
  let pollGeneration = 0;

  function setStatus(message, kind = "idle") {
    els.status.textContent = message;
    els.status.title = message;
    els.status.className = `status ${kind}`;
  }

  function refreshControls() {
    const locked = !invoke || busy || buildRunning;
    for (const button of [els.load, els.validate, els.planButton]) {
      button.disabled = locked;
    }
    els.dryRun.disabled = locked;
    els.build.disabled = locked;
    els.path.disabled = locked;
    els.outDir.disabled = locked;
    els.cancel.disabled = !invoke || busy || !buildRunning;
  }

  function setBusy(value) {
    busy = value;
    refreshControls();
  }

  function setBuildRunning(value) {
    buildRunning = value;
    refreshControls();
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

  /* ---------------------------------------------------------------- build UI */

  function setBuildBadge(state, exitCode) {
    const labels = {
      idle: "idle",
      starting: "starting",
      running: "running",
      exited: "exited",
      failed: "failed",
      cancelled: "cancelled",
      error: "error",
    };
    const label = labels[state] || state;
    if (els.buildBadge.textContent !== label) {
      els.buildBadge.textContent = label;
    }
    els.buildBadge.className = `build-badge ${state}`;
    const exitText =
      state === "idle" || state === "starting" || state === "running"
        ? ""
        : exitCode === null || exitCode === undefined
          ? "exit —"
          : `exit ${exitCode}`;
    if (els.buildExit.textContent !== exitText) {
      els.buildExit.textContent = exitText;
      els.buildExit.title = exitText;
    }
  }

  function renderBuildLog(text) {
    const content = text && text.length > 0 ? text : "(no output yet)";
    if (els.buildLog.textContent === content) return;
    els.buildLog.textContent = content;
    // The log panel follows the builder output until the user starts another
    // build or scrolls away.
    els.buildLog.scrollTop = els.buildLog.scrollHeight;
  }

  function lastMeaningfulLine(text) {
    const lines = String(text || "")
      .split("\n")
      .map((line) => line.trim())
      .filter(Boolean);
    return lines.length > 0 ? lines[lines.length - 1] : "";
  }

  function setBuildMeta(status) {
    const parts = [];
    if (activeBuild) parts.push(`id ${activeBuild.id}`);
    if (status && status.started_at) parts.push(`started ${status.started_at}`);
    if (status && status.finished_at) parts.push(`finished ${status.finished_at}`);
    setMeta(els.buildMeta, parts.length > 0 ? parts.join(" · ") : "no build yet");
  }

  function announceBuildResult(status, log) {
    const exit =
      status.exit_code === null || status.exit_code === undefined
        ? "no exit code"
        : `exit ${status.exit_code}`;

    if (status.state === "exited" && status.exit_code === 0) {
      setStatus(`Build exited 0 · ${activeBuild ? activeBuild.log_path : ""}`, "ok");
      return;
    }
    if (status.state === "cancelled") {
      setStatus("Build cancelled", "warn");
      return;
    }
    if (status.state === "failed") {
      const tail = lastMeaningfulLine(log) || "(build log is empty)";
      setStatus(`Build failed · ${exit} · ${tail}`, "error");
      return;
    }
    setStatus(`Build ${status.state} · ${exit}`, status.state === "exited" ? "ok" : "warn");
  }

  function stopPolling() {
    // Invalidates an in-flight poll so a slow response from a cancelled or
    // replaced build cannot overwrite the current badge.
    pollGeneration += 1;
    if (pollTimer !== null) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  }

  async function pollBuild() {
    if (!invoke || !activeBuild) return;
    const build = activeBuild;
    const generation = pollGeneration;

    try {
      const status = await invoke("get_build", { id: build.id });
      const log = await invoke("get_build_log", {
        id: build.id,
        tail_lines: BUILD_LOG_TAIL_LINES,
      });

      if (
        generation !== pollGeneration ||
        !activeBuild ||
        activeBuild.id !== build.id
      ) {
        return;
      }

      renderBuildLog(log);
      setBuildMeta(status);

      if (status.state === "running") {
        setBuildBadge("running", null);
        return;
      }

      stopPolling();
      setBuildRunning(false);
      setBuildBadge(status.state, status.exit_code);
      announceBuildResult(status, log);
    } catch (error) {
      if (generation !== pollGeneration) return;
      // A lost backend must stop the timer and stay visible, not spin forever.
      stopPolling();
      setBuildRunning(false);
      setBuildBadge("error", null);
      setMeta(els.buildMeta, "status unavailable");
      els.buildLog.textContent += `\n[sysemble] polling failed: ${formatError(error)}`;
      els.buildLog.scrollTop = els.buildLog.scrollHeight;
      setStatus(`Build status failed: ${formatError(error)}`, "error");
    }
  }

  async function startBuild(mode) {
    if (!invoke) return;

    const specPath = els.path.value.trim();
    const outDir = els.outDir.value.trim();
    if (!specPath) {
      setStatus("Enter a spec path first.", "error");
      els.path.focus();
      return;
    }
    if (!outDir) {
      setStatus("Enter an output directory first.", "error");
      els.outDir.focus();
      return;
    }

    stopPolling();
    activeBuild = null;
    setBuildRunning(true);
    setBuildBadge("starting", null);
    setMeta(els.buildMeta, "starting…");
    els.buildLog.textContent = `Starting ${mode} build…`;
    setStatus(`${mode === "execute" ? "Build" : "Dry run"} starting…`, "busy");

    try {
      const started = await invoke("start_build", {
        spec_path: specPath,
        out_dir: outDir,
        mode,
      });
      activeBuild = started;
      setBuildBadge("running", null);
      setBuildMeta(null);
      setStatus(`Build running · ${mode} · ${outDir}`, "busy");

      await pollBuild();
      if (buildRunning) {
        pollTimer = setInterval(pollBuild, BUILD_POLL_INTERVAL_MS);
      }
    } catch (error) {
      const message = formatError(error);
      setBuildRunning(false);
      setBuildBadge("error", null);
      setMeta(els.buildMeta, "start failed");
      els.buildLog.textContent = `Could not start the build.\n\n${message}`;
      els.buildLog.scrollTop = 0;
      setStatus(`Build failed to start: ${message}`, "error");
    }
  }

  async function cancelBuild() {
    if (!invoke || !activeBuild || !buildRunning) return;

    els.cancel.disabled = true;
    setStatus("Cancelling build…", "busy");
    try {
      await invoke("cancel_build", { id: activeBuild.id });
      setBuildBadge("cancelled", null);
      setStatus("Build cancelled", "warn");
      stopPolling();
      await pollBuild();
    } catch (error) {
      setStatus(`Cancel failed: ${formatError(error)}`, "error");
      refreshControls();
    }
  }

  /* ----------------------------------------------------------------- actions */

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
  els.dryRun.addEventListener("click", () => startBuild("dry-run"));
  els.build.addEventListener("click", () => startBuild("execute"));
  els.cancel.addEventListener("click", cancelBuild);

  els.path.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      action(validateSpec);
    }
  });

  window.addEventListener("beforeunload", stopPolling);

  if (!invoke) {
    els.bridgeWarning.hidden = false;
    setBusy(false);
    setStatus("Browser preview — Tauri IPC unavailable", "warn");
  } else {
    setBusy(false);
    setStatus("Ready", "idle");
  }

  setBuildBadge("idle", null);
  setBuildMeta(null);
})();
