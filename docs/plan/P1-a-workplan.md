# P1-a 工作分解：Tauri 桌面壳（validate / plan）

> P0 已闭环：CLI/引擎能从 spec 构建、启动、生成 ISO、安装到磁盘。
> P1 目标是把引擎包成三端桌面 app。本切片只做**第一个可运行窗口**：打开 spec、validate、plan。

- 日期：2026-11-23
- 基线提交：`bd0167c`
- 技术栈：Tauri 2 + 原生 WebView；前端先用**无构建步骤的 HTML/CSS/JS**（P1-b 再迁 React）。

---

## 1. 范围

| 做 | 不做 |
|---|---|
| `apps/desktop` Tauri 2 窗口 | 构建/安装按钮（P1-b） |
| 命令：`read_spec`、`validate`、`plan` | 层级画布 / diff（P1-c） |
| 前端：路径输入、诊断列表、plan 摘要 | 对话式问询（P1-d） |
| 本地 `cargo check` + Linux CI check | Windows/macOS 打包（P1-e） |

## 2. 目录与契约（冻结）

```
apps/desktop/
  src-tauri/
    Cargo.toml          # package sysemble-desktop
    build.rs
    tauri.conf.json
    capabilities/default.json
    icons/icon.png
    src/main.rs
    src/lib.rs
  ui/
    index.html
    app.js
    style.css
```

### 命令（IPC）

```rust
#[tauri::command] fn read_spec(path: String) -> Result<String, String>
#[tauri::command] fn validate(path: String) -> Result<Vec<Diagnostic>, String>
#[tauri::command] fn plan(path: String) -> Result<Plan, String>
```

- 前端通过 `window.__TAURI__.core.invoke("validate", { path })` 调用（`withGlobalTauri: true`）。
- 错误一律返回可读字符串（含文件路径）。
- `Diagnostic` / `Plan` 已有 `Serialize`，直接返回。

### 窗口

- 标题 `Sysemble`，1100×760，最小 900×600。
- `bundle.active=false`（P1-a 只做 dev 运行；打包留 P1-e）。

### UI

- 顶部：spec 路径输入（默认 `examples/debian-xfce.yaml`）+ `Load` / `Validate` / `Plan`。
- 左栏：spec 原文（只读）。
- 右栏：诊断列表（error/warning 颜色）+ plan 摘要（包数、体积、时长、模块）。
- 无框架、无 npm、无构建步骤。

## 3. CI

新增 `desktop-check`（ubuntu-latest）：

```
apt: libwebkit2gtk-4.1-dev libgtk-3-dev librsvg2-dev libssl-dev patchelf（无 tray，不需要 appindicator）
cargo check --manifest-path apps/desktop/src-tauri/Cargo.toml
```

## 4. 验收

| # | 检查 | 通过条件 |
|---|---|---|
| G1 | 本地 `cargo check --manifest-path apps/desktop/src-tauri/Cargo.toml` | macOS 通过 |
| G2 | CI `desktop-check` | job 绿 |
| G3 | 命令行为 | 用 `cargo test -p sysemble-desktop`（可选）或单测验证 read/validate/plan 逻辑 |
| G4 | 配置合法 | `tauri.conf.json` 可被 `tauri-build` 接受 |
| G5 | 回归 | 现有 61 rust + builder/boot/install 测试不受影响 |
| G6 | 边界 | 只新增 `apps/desktop/**`、根 Cargo.toml、CI |

## 5. 风险

1. Tauri 2 在 macOS 编译需要系统框架，首次拉依赖较慢（可接受）。
2. Linux CI 需要 webkit2gtk-4.1 等包；Ubuntu 24.04 提供。
3. `generate_context!` 需要图标与 capability；缺失会编译失败。
4. 无 GUI 自动化验证：本切片以编译 + 命令单测为准，窗口截图留 P1-b。
5. 路径为相对 app 启动目录；暂不做文件选择器（避免额外插件）。

> 2026-11-23 修订：桌面 crate 用独立 workspace，命令改为 `--manifest-path`；CI 同时跑 `cargo test --manifest-path`。
