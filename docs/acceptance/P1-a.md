# P1-a 独立验收报告（Tauri 桌面壳：read_spec / validate / plan）

- 验收角色：**SA-verify7**（独立验收子代理；只读源码/CI/证据，只写 `docs/acceptance/**`）
- 日期：**2026-11-23**（Europe/Madrid，19:23 起；CI 时间线为 UTC）
- 仓库：`sysemble/`，分支 `main`
- HEAD：**`7f7a2b0faa57be1160b11de3f8093594641c6544`**（父提交 `bd0167c12ddebaa56cca1a28bed99f15e33cc3f9`，与 workplan 基线 `bd0167c` 一致）
- 权威 CI run：**[45236886873](https://github.com/yiaogit/Sysemble/actions/runs/45236886873)**（push，`success`，2026-11-23T18:17:59Z 创建，18:23:25Z 完成；`headSha` 与本地 HEAD 一致）
- 权威 job：**[Desktop app (check) #137910850111](https://github.com/yiaogit/Sysemble/actions/runs/45236886873/job/137910850111)**（`success`，18:18:02–18:19:42Z，**1m40s**）
- 验收范围：`docs/plan/P1-a-workplan.md` 的 **G1–G6**，以及任务书要求核实的 8 个点
- 判定原则：编译 + 测试 + 契约一致 + CI 绿 → PASS；任何不一致写清证据

**判定摘要：G1–G5 PASS，G6 PASS（附 1 项非阻塞边界偏差）；FAIL 0，BLOCKED 0。结论：`P1-a 通过`。**

未只信绿灯：本地重跑根 workspace 61 个测试与桌面 crate 4 个单测；逐行核对 Rust 命令签名、`generate_handler!` 注册、JS `invoke` 名称/参数、错误提示路径、Tauri 配置与 capability；把 `tauri-codegen-assets` 中的资源用 brotli 解压后与 `ui/` 三个源文件逐字 `cmp` 一致；CI 侧从 job 日志核对 apt 安装、`cargo check --manifest-path` 与 `Finished` 行，并从同 run 的 Rust workspace 日志复核 61 个测试。

---

## 1. 环境与证据获取

### 1.1 本地环境

| 项 | 实际值 |
|---|---|
| OS / 架构 | macOS **26.6.2**（Build 25G83），Darwin 25.6.0，**arm64** |
| Rust / Cargo | rustc **1.100.0**（0ef1bc386）/ cargo **1.100.0**（3acc79c0c） |
| 工具链位置 | `CARGO_HOME=<repo>/../.tools/cargo`，`RUSTUP_HOME=<repo>/../.tools/rustup` |
| 其它工具 | gh 2.92.0、jq 1.7.1、node 25.2.1、brotli 1.2.0 |
| 验收开始时工作区 | `HEAD=7f7a2b0`；`git status --porcelain` 为空 |
| 本报告写入 | 唯一新增 `docs/acceptance/P1-a.md` |

### 1.2 CI 环境

| 项 | 实际值 |
|---|---|
| Workflow | `.github/workflows/ci.yml` |
| Runner | `ubuntu-26.04`，镜像 `20261116.202` |
| run | **45236886873**，push → `main`，**7/7 job `success`** |
| Desktop job | `desktop-check` / `Desktop app (check)`，#137910850111，`timeout-minutes: 30`，实际 **1m40s** |

### 1.3 本地命令与结果

```bash
export CARGO_HOME=/Users/.../.tools/cargo
export RUSTUP_HOME=/Users/.../.tools/rustup

$CARGO_HOME/bin/cargo test --workspace
# 6 个测试 target + doc-test：9+12+8+10+8+14 = 61 passed；0 failed

$CARGO_HOME/bin/cargo test --manifest-path apps/desktop/src-tauri/Cargo.toml
# 4 passed；0 failed（lib）；main target 与 doc-test 各 0

$CARGO_HOME/bin/cargo check --manifest-path apps/desktop/src-tauri/Cargo.toml
# Finished `dev` profile ... in 0.17s（增量）

$CARGO_HOME/bin/cargo build --locked --manifest-path apps/desktop/src-tauri/Cargo.toml
# Finished `dev` profile ... in 1.42s；Mach-O 64-bit executable arm64，29,518,640 B

$CARGO_HOME/bin/cargo fmt --check --manifest-path apps/desktop/src-tauri/Cargo.toml
# exit 0

node --check apps/desktop/ui/app.js     # OK
jq empty apps/desktop/src-tauri/tauri.conf.json \
         apps/desktop/src-tauri/capabilities/default.json  # OK
```

说明：workplan G1/§3 写的是 `cargo check -p sysemble-desktop`，但该 crate 是**独立 workspace**（`apps/desktop/src-tauri/Cargo.toml` 内 `[workspace]`），从仓库根用 `-p` 找不到；实现、CI 与任务书都用 `--manifest-path`，这是正确且必要的调用方式，不构成功能失败（见 §7.1 第 9 条）。

---

## 2. G1–G6 结果

| # | 检查 | 通过条件 | 结果 | 关键证据 |
|---|---|---|---|---|
| **G1** | 本地 `cargo check` | macOS 通过 | **PASS** | `cargo check` 与 `cargo build --locked` 均 exit 0；构建出 Mach-O arm64 可执行文件（29.5 MB）；`cargo fmt --check` exit 0 |
| **G2** | CI `desktop-check` | job 绿 | **PASS** | run 7/7 success；Desktop app (check) success，1m40s；日志 `Finished \`dev\` profile ... in 1m 16s` |
| **G3** | 命令行为 | 单测验证 read/validate/plan | **PASS** | 桌面 crate **4/4**：`debian_xfce_validates_without_errors`、`debian_xfce_plans_a_non_empty_package_set`、`read_spec_returns_the_file_contents`、`missing_paths_are_errors_for_every_command`；错误串含路径 |
| **G4** | 配置合法 | `tauri.conf.json` 可被 `tauri-build` 接受 | **PASS** | `build.rs` 成功；生成 3 个 `tauri-codegen-assets`；生成的 capability 为 `windows:["main"]`、`core:default`；`cargo check`/`build` 通过 |
| **G5** | 回归 | 61 rust + builder/boot/install 不受影响 | **PASS** | 本地 61/61；CI Rust workspace 61/61；同 run 的 Boot/Desktop/Live/Install 四个 smoke 全 `success` |
| **G6** | 边界 | 只新增 `apps/desktop` + CI + `docs/plan`；根 `Cargo.toml` 未改 | **PASS\*** | 15 个文件：`apps/desktop` 12、`docs/plan` 1、CI 1、`tests/acceptance/run.sh` +1 行；根 `Cargo.toml` 与根 `Cargo.lock` 均未改；见 §6 |

\* **G6 非阻塞偏差**：`tests/acceptance/run.sh` 增加 1 行，把 `apps/desktop/*` 加入 P0 acceptance 的 A10 允许路径。该文件不在 workplan G6 的字面清单内，属于测试夹具改动，不涉及产品源码或 CI 行为；G6 的**意图**（不越界改 `crates/`、`builders/`、`spec/`、`examples/`）满足。建议后续把该 1 行补进 workplan 的边界说明，或单独提交，避免文档与实现不一致。

### 2.1 任务书 1–8 对照

| # | 要求 | 结果 | 证据 |
|---|---|---|---|
| 1 | 命令契约与注册 | **PASS** | §3.1 |
| 2 | 前后端命令名/参数一致、错误有 UI 提示 | **PASS** | §3.2、§3.3 |
| 3 | `tauri.conf.json` 与 capabilities | **PASS** | §4.1、§4.2 |
| 4 | 资源嵌入含 ui 三文件 | **PASS** | §4.3 |
| 5 | CI `Desktop app (check)` 与 apt 依赖 | **PASS** | §5 |
| 6 | 回归：61 tests + P0 四个 smoke | **PASS** | §6 |
| 7 | 边界 | **PASS\***（1 处非阻塞偏差） | §6.3 |
| 8 | 风险记录 | **已记录** | §7 |

---

## 3. 命令契约与前后端一致性

### 3.1 Rust 侧签名与注册（与 workplan 逐字一致）

[`apps/desktop/src-tauri/src/lib.rs:59-82`](../../apps/desktop/src-tauri/src/lib.rs#L59-L82)：

```rust
/// IPC: raw spec source.
#[tauri::command]
fn read_spec(path: String) -> Result<String, String> {
    read_spec_file(&path)
}

/// IPC: validation diagnostics.
#[tauri::command]
fn validate(path: String) -> Result<Vec<Diagnostic>, String> {
    validate_spec_path(&path)
}

/// IPC: resolved build plan.
#[tauri::command]
fn plan(path: String) -> Result<Plan, String> {
    plan_spec_path(&path)
}

pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![read_spec, validate, plan])
        .run(tauri::generate_context!())
        .expect("failed to run the Sysemble desktop window");
}
```

| 命令 | workplan 契约 | 实际 Rust 签名 | 一致 |
|---|---|---|---|
| `read_spec` | `fn read_spec(path: String) -> Result<String, String>` | `fn read_spec(path: String) -> Result<String, String>` | ✅ |
| `validate` | `fn validate(path: String) -> Result<Vec<Diagnostic>, String>` | `fn validate(path: String) -> Result<Vec<Diagnostic>, String>` | ✅ |
| `plan` | `fn plan(path: String) -> Result<Plan, String>` | `fn plan(path: String) -> Result<Plan, String>` | ✅ |

- `generate_handler![read_spec, validate, plan]` 三个命令**全部注册**，无遗漏。
- 三个命令都是薄包装，实际逻辑在 `pub fn read_spec_file` / `validate_spec_path` / `plan_spec_path`，因此 4 个单测可以在不起 WebView 的情况下覆盖行为。
- 错误映射（[`lib.rs:37-56`](../../apps/desktop/src-tauri/src/lib.rs#L37-L56)）均为 `cannot read spec \`{path}\`: ...` / `cannot validate \`{path}\`: ...` / `cannot plan \`{path}\`: ...`，含调用方路径；单测 `missing_paths_are_errors_for_every_command` 对三条命令逐一断言错误串包含路径。

### 3.2 前端命令名与参数

[`apps/desktop/ui/app.js:217-234`](../../apps/desktop/ui/app.js#L217-L234)：

```js
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
```

| JS `invoke` | Rust 命令 | 参数 | 一致 |
|---|---|---|---|
| `"read_spec", { path }` | `read_spec(path: String)` | `path` | ✅ |
| `"validate", { path }` | `validate(path: String)` | `path` | ✅ |
| `"plan", { path }` | `plan(path: String)` | `path` | ✅ |

- 三个 `invoke` 名称与 Rust 函数名逐一对应；参数键都是 `path`（单词参数，不存在 Tauri 的 camelCase/snake_case 歧义）。
- `invoke` 从 `window.__TAURI__.core.invoke` 获取（[`app.js:4-8`](../../apps/desktop/ui/app.js#L4-L8)），依赖 `withGlobalTauri: true`；该配置已开（§4.1）。
- 三个按钮分别绑定 `loadSpec` / `validateSpec` / `planSpec`（[`app.js:236-238`](../../apps/desktop/ui/app.js#L236-L238)），与 UI 的 Load / Validate / Plan 对应（[`index.html:35-37`](../../apps/desktop/ui/index.html#L35-L37)）。

### 3.3 错误路径的 UI 提示

[`apps/desktop/ui/app.js:197-215`](../../apps/desktop/ui/app.js#L197-L215)：

```js
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
```

- Rust `Result<_, String>` 的拒绝值是字符串；`formatError`（[`app.js:42-50`](../../apps/desktop/ui/app.js#L42-L50)）对字符串直接返回，因此文件不存在等错误会原样显示在状态栏。
- 状态元素 `#status` 是 `role="status" aria-live="polite"`（[`index.html:19`](../../apps/desktop/ui/index.html#L19)），错误样式为 `.status.error`（[`style.css:154`](../../apps/desktop/ui/style.css#L154)）。
- 非 Tauri 环境（浏览器直接打开 `ui/index.html`）会显示 `#bridge-warning` 并禁用按钮（[`app.js:247-250`](../../apps/desktop/ui/app.js#L247-L250)、[`index.html:42-48`](../../apps/desktop/ui/index.html#L42-L48)），不会静默调用失败。
- 空路径在发 IPC 前拦截并提示（`Enter a spec path first.`）。
- 校验失败（`validate` 返回 error 诊断）也会在诊断列表以 `.diagnostic.error` 渲染，并在状态栏汇总 error/warning 数量（[`app.js:83-117`](../../apps/desktop/ui/app.js#L83-L117)）；IPC 本身失败（如文件不存在）则走上面的状态栏错误串路径。

### 3.4 返回数据形状与 UI 字段

`Diagnostic` 与 `Plan` 都由 `sysemble-core` 派生 `Serialize`（[`crates/sysemble-core/src/validate.rs:98`](../../crates/sysemble-core/src/validate.rs#L98)、[`crates/sysemble-core/src/plan.rs:34`](../../crates/sysemble-core/src/plan.rs#L34)）。实际序列化（用同一 `sysemble-core` 的 CLI 验证）：

```text
// plan（examples/debian-xfce.yaml）
{
  "apiVersion": "sysemble/plan/v1",
  "spec": "debian-xfce",
  "base":       { "kind": "debian", "release": "trixie", "pin": "2026-11-01" },
  "target":     { "arch": "x86_64", "outputs": ["qcow2"] },
  "packages":   ["..."],
  "modules":    [ { "id": "base-debian", "version": "0.1.0" }, ... ],
  "estimates":  { "image_mb": 1280, "build_minutes": 13, "disk_mb": 3584 },
  "warnings":   []
}

// diagnostic（warning-only 临时 spec）
{
  "severity": "warning",
  "code": "spec.target.base.release.missing",
  "path": "/target/base/release",
  "message": "base `debian` has no release; ..."
}
```

| UI 使用字段 | 序列化来源 | 一致 |
|---|---|---|
| `diagnostic.severity`（`"warning"`/其它按 error） | `Severity` 枚举 `#[serde(rename_all = "lowercase")]`（[`validate.rs:75-79`](../../crates/sysemble-core/src/validate.rs#L75-L79)） | ✅ |
| `diagnostic.code` / `.path` / `.message` | `Diagnostic` 同名字段 | ✅ |
| `plan.spec`、`plan.packages`、`plan.modules[].id/version` | `Plan` 同名字段 | ✅ |
| `plan.base.kind` / `.release` | `PlanBase`；`BaseKind` 序列化为 `"debian"` 等字符串 | ✅ |
| `plan.target.arch` / `.outputs` | `PlanTarget`；`Arch`/`Output` 序列化为字符串 | ✅ |
| `plan.estimates.image_mb` / `.build_minutes` / `.disk_mb` | `Estimates` 同名字段 | ✅ |
| `plan.warnings[].code` / `.message` | `PlanWarning` 同名字段 | ✅ |

`renderDiagnostics` / `renderPlan`（[`app.js:83-195`](../../apps/desktop/ui/app.js#L83-L195)）使用的字段与上表一致；未发现命令名、参数名或数据字段的前后端不一致。

---

## 4. 配置与资源嵌入

### 4.1 `tauri.conf.json`

[`apps/desktop/src-tauri/tauri.conf.json`](../../apps/desktop/src-tauri/tauri.conf.json)：

| 检查项 | 要求 | 实际值 | 结果 |
|---|---|---|---|
| identifier | 合法反向域名 | `tech.sysemble.desktop` | ✅ |
| frontendDist | 指向 `ui/` | `"../ui"`（相对 `src-tauri/` → `apps/desktop/ui`） | ✅ |
| withGlobalTauri | `true` | `true` | ✅ |
| 窗口 label | `main` | `"main"` | ✅ |
| 窗口尺寸 | 1100×760 | `width: 1100`、`height: 760` | ✅ |
| 最小尺寸 | 900×600 | `minWidth: 900`、`minHeight: 600` | ✅ |
| 标题 | `Sysemble` | `title: "Sysemble"` | ✅ |
| bundle.active | `false` | `false` | ✅ |

关键字段（节选）：

```json
{
  "identifier": "tech.sysemble.desktop",
  "build": { "frontendDist": "../ui" },
  "app": {
    "withGlobalTauri": true,
    "windows": [ { "label": "main", "title": "Sysemble",
                   "width": 1100, "height": 760,
                   "minWidth": 900, "minHeight": 600 } ]
  },
  "bundle": { "active": false, "icon": ["icons/icon.png"] }
}
```

`bundle.icon` 指向 [`icons/icon.png`](../../apps/desktop/src-tauri/icons/icon.png)（PNG，512×512，RGBA，29,856 B）；虽然 bundle 未激活，`tauri-build` 仍能解析该图标，构建成功。

### 4.2 capabilities

[`apps/desktop/src-tauri/capabilities/default.json`](../../apps/desktop/src-tauri/capabilities/default.json)（关键字段节选）：

```json
{
  "identifier": "default",
  "windows": ["main"],
  "permissions": ["core:default"]
}
```

`tauri-build` 生成的实际 capability 输出（`target/debug/build/sysemble-desktop/6cdde30.../out/capabilities.json`）为：

```json
{"default":{"identifier":"default","description":"Permissions for the main Sysemble window: core defaults only.","local":true,"windows":["main"],"permissions":["core:default"]}}
```

窗口 label `main` 与 capability 的 `windows:["main"]` 一致；`core:default` 存在。

### 4.3 资源嵌入（ui 三个文件）

`tauri-build`/`tauri-codegen` 在构建脚本输出目录生成了三个资源：

```
target/debug/build/sysemble-desktop/6cdde30cad58b608/out/tauri-codegen-assets/
  37c144f5...html   (1,108 B)
  ee1cf5ee...js     (2,579 B)
  984ee19f...css    (3,107 B)
```

这些是 brotli 压缩后的内容；用 `brotli -d` 解压后与源文件逐字比较：

| 生成资源 | 解压后与源文件 `cmp` | 源文件大小 |
|---|---|---|
| `37c144f5...html` | **IDENTICAL** | `index.html` 2,847 B |
| `ee1cf5ee...js` | **IDENTICAL** | `app.js` 8,015 B |
| `984ee19f...css` | **IDENTICAL** | `style.css` 10,804 B |

补充证据：

- `sysemble_desktop_lib-...d` 的 dep-info 明确列出 `../ui/app.js`、`../ui/index.html`、`../ui/style.css`，说明 `generate_context!` 在编译期读取了三个文件。
- 构建脚本输出目录同时包含 `__global-api-script.js`（`withGlobalTauri` 的全局 API 注入脚本）和 `capabilities.json`。
- `cargo check`/`cargo test`/`cargo build --locked` 全部成功，证明 `generate_context!` 没有因缺图标、缺 capability 或资源路径错误而失败。

> 注意：这里验证的是“构建产物中嵌入的字节与源文件一致”，不是“窗口已渲染”。窗口截图/GUI 自动化仍未做（见 §7）。

---

## 5. CI job 结果

**run [45236886873](https://github.com/yiaogit/Sysemble/actions/runs/45236886873)**，`headSha=7f7a2b0faa57be1160b11de3f8093594641c6544`，7/7 job `success`：

| job | 结果 | 时间（UTC） | 耗时 |
|---|---|---|---|
| Validate specs | success | 18:18:02–18:18:08 | 6s |
| Rust workspace | success | 18:18:02–18:18:18 | 16s |
| Boot smoke (Debian) | success | 18:18:02–18:23:25 | 5m23s |
| Desktop smoke (XFCE) | success | 18:18:02–18:20:14 | 2m12s |
| Live ISO smoke | success | 18:18:02–18:20:05 | 2m03s |
| Install smoke (headless) | success | 18:18:02–18:21:09 | 3m07s |
| **Desktop app (check)** | **success** | **18:18:02–18:19:42** | **1m40s** |

`Desktop app (check)` 的 4 个实际工作 step（checkout / rust toolchain / apt / `cargo check --manifest-path`）全部 success，job 整体 `success`：

- 日志中的实际命令：`cargo check --manifest-path apps/desktop/src-tauri/Cargo.toml`（18:18:24Z）。
- 依赖安装（日志实际版本）：
  - `libwebkit2gtk-4.1-dev` **2.52.6-0ubuntu0.26.04.2**
  - `libgtk-3-dev` **3.24.52-0ubuntu1**
  - `librsvg2-dev` **2.61.3+dfsg-3ubuntu0.1**
  - `libssl-dev` **3.5.5-1ubuntu3.7**（已最新）
  - `patchelf` **0.18.0-1.4build1**（已最新）
- 编译结果：`Finished \`dev\` profile [unoptimized] target(s) in 1m 16s`，step 成功，job 总耗时 1m40s。
- 同 run 的 `Rust workspace` 日志包含 9+12+8+10+8+14 = **61 passed**，与本地一致。
- 工作流中 `continue-on-error` 出现次数为 **0**。

**CI 覆盖边界（非失败，但需知悉）**：`desktop-check` 只执行 `cargo check`，**不执行** `cargo test`、不链接最终二进制、不启动 WebView；4 个桌面单测与 Linux 链接/运行时验证目前只在本地（macOS）完成。

---

## 6. 回归、workspace 隔离与边界

### 6.1 回归

| 项 | 结果 |
|---|---|
| 根 workspace `cargo test --workspace` | **61 passed / 0 failed**（9+12+8+10+8+14；doc-test 0） |
| CI `Rust workspace`（同 run） | **61 passed / 0 failed**（日志逐 target 计数一致） |
| 桌面 crate `cargo test --manifest-path ...` | **4 passed / 0 failed** |
| P0 四个 smoke（同 run） | Boot / Desktop / Live ISO / Install **全部 success**（§5） |

### 6.2 workspace 隔离

- 根 `cargo metadata --no-deps` 的 `workspace_members` 只有 `sysemble-core`、`sysemble-cli`，**不含 `sysemble-desktop`**。
- `cargo metadata --manifest-path apps/desktop/src-tauri/Cargo.toml --no-deps` 的 `workspace_root` 是 `apps/desktop/src-tauri`，成员只有 `sysemble-desktop`。
- 根 `Cargo.toml` / 根 `Cargo.lock` 在 `bd0167c..HEAD` 区间**无 diff**；根 `Cargo.lock` 中 `tauri` 包数量为 **0**。
- 桌面 crate 的 `Cargo.lock` 已提交，锁定 `tauri 2.12.7`、`tauri-build 2.7.6`；`cargo build --locked` 成功，说明 lock 与 manifest 一致。

### 6.3 变更边界

`git diff --name-status bd0167c..HEAD`（15 个文件，+5,905 行）：

| 变更 | 文件 |
|---|---|
| M | `.github/workflows/ci.yml`（+18，新增 `desktop-check` job） |
| A | `apps/desktop/src-tauri/{.gitignore,Cargo.lock,Cargo.toml,build.rs,capabilities/default.json,icons/icon.png,src/lib.rs,src/main.rs,tauri.conf.json}`（9） |
| A | `apps/desktop/ui/{index.html,app.js,style.css}`（3） |
| A | `docs/plan/P1-a-workplan.md`（+89） |
| M | `tests/acceptance/run.sh`（+1，A10 允许路径加入 `apps/desktop/*`） |

- 根 `Cargo.toml`、根 `Cargo.lock` **未改**。
- 未触碰 `crates/`、`builders/`、`spec/`、`examples/`、`tools/`（workplan G6 的核心边界意图满足）。
- **偏差**：`tests/acceptance/run.sh` 的 1 行不属于 workplan G6 的字面清单。它是 P0 acceptance 夹具的允许路径扩充，不影响产品源码或 CI；作为非阻塞发现记录（建议同步 workplan 或单独提交）。
- `git ls-files apps/desktop | wc -l` = **12**，列表只含源码/配置/图标/锁文件，**不含** `target/`、`gen/` 生成物。
- `git check-ignore` 确认 `apps/desktop/src-tauri/target/` 与 `gen/schemas/` 均由 [`apps/desktop/src-tauri/.gitignore`](../../apps/desktop/src-tauri/.gitignore) 忽略。
- 验收开始时 `git status --porcelain` 为空；本报告写入后 `git status --porcelain` 仅有 `?? docs/acceptance/P1-a.md`。

---

## 7. 风险与发现

### 7.1 风险（均为已知范围/后续切片，非 P1-a 失败）

1. **无窗口截图 / 无 GUI 自动化**：本切片只证明编译、单测、配置合法和资源嵌入；窗口实际渲染、WebView 加载、真实 IPC 往返未自动化验证（workplan 风险 #4，截图留 P1-b）。
2. **无文件选择器**：spec 路径是文本输入（[`index.html:23-33`](../../apps/desktop/ui/index.html#L23-L33)），默认 `examples/debian-xfce.yaml` 是相对路径，依赖启动目录。
3. **debug 路径回退只在 debug 生效**：`resolve_path` 在 debug 下回退到 `CARGO_MANIFEST_DIR/../../..`（[`lib.rs:18-34`](../../apps/desktop/src-tauri/src/lib.rs#L18-L34)）；release 只使用调用方路径。若将来打包后从 app bundle 启动，默认相对路径会失败，需要用户输入绝对路径；P1-e 需处理（workplan 风险 #5）。
4. **无 build / install 按钮**：本切片只有 Load / Validate / Plan（P1-b）；无层级画布/diff（P1-c）、无对话式问询（P1-d）。
5. **bundle 未激活**：`bundle.active=false`，没有 `.app`/安装包；Windows/macOS 打包未做（P1-e）。本机构建产物是裸 Mach-O 可执行文件，不是可分发的 app bundle。
6. **未用 React**：前端是无构建步骤的 HTML/CSS/JS（[`index.html`](../../apps/desktop/ui/index.html)、[`app.js`](../../apps/desktop/ui/app.js)、[`style.css`](../../apps/desktop/ui/style.css)），React 迁移留 P1-b。
7. **CI 只 check 不 test/build**：`desktop-check` 不跑 4 个单测、不链接、不启动 WebView；Linux 链接与运行时行为未在 CI 覆盖。
8. **单测不直接调用 `#[tauri::command]` 包装或 JS**：4 个单测覆盖的是 `read_spec_file`/`validate_spec_path`/`plan_spec_path`；命令名与参数一致性靠静态检查 + `generate_handler!` 编译期注册保证，不是端到端 IPC 测试。
9. **workplan/CI 文档漂移**：workplan §3 的 apt 清单写 `libappindicator3-dev`，实际 CI 用 `libssl-dev`（本切片无 tray 功能，job 绿）；workplan 的 `cargo check -p sysemble-desktop` 与独立 workspace 不兼容，实际/任务书均用 `--manifest-path`；workplan 风险提到 Ubuntu 24.04，实际 runner 是 26.04。均不影响功能，但建议回写文档。
10. **CI 未用 `--locked`**：`cargo check` 默认允许更新 lock；若未来 manifest 变动导致 lock 漂移，CI 可能自动更新而不显式失败。当前提交的 lock 与 manifest 一致（本地 `--locked` 构建通过），风险低。
11. **边界偏差**：`tests/acceptance/run.sh` 的 1 行 A10 允许路径放宽了 P0 acceptance 对 `apps/desktop` 的路径约束（仅测试夹具，非产品行为）。

### 7.2 结论相关发现

- **无 FAIL 项**；G1–G5 全部满足，G6 的边界意图满足但有 1 行测试夹具偏差。
- 未发现命令签名、注册、JS 调用、参数名、错误提示或资源嵌入方面的不一致。
- 未发现根 workspace 被 Tauri 依赖污染；根 `Cargo.toml`/`Cargo.lock` 未改。
- 建议（非阻塞）：
  1. 把 `tests/acceptance/run.sh` 的 1 行补进 workplan 边界说明，或拆成独立测试夹具提交；
  2. 在 `desktop-check` 中追加 `cargo test --manifest-path ...`（成本很低，能让 4 个单测进入 CI 门禁）；
  3. 同步 workplan 的 apt 清单与 `--manifest-path` 调用方式。

---

## 8. 结论

| 判定项 | 结果 |
|---|---|
| 编译（macOS `cargo check` / `build --locked`） | **PASS** |
| 测试（根 61 + 桌面 4） | **PASS** |
| 契约一致（Rust 签名 / 注册 / JS 名称与参数 / 数据字段） | **PASS** |
| CI 绿（run 7/7，desktop job 1m40s） | **PASS** |
| 配置与资源嵌入 | **PASS** |
| 边界 | **PASS\***（1 处非阻塞偏差：`tests/acceptance/run.sh` +1 行） |

**PASS / FAIL 摘要：PASS 6，FAIL 0，BLOCKED 0（G6 附非阻塞偏差）。**

**结论：`P1-a 通过`。**
