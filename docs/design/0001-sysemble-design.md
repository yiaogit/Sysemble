# Sysemble 设计文档 v0.2

> Assemble your own Linux.
> 本地优先、跨 Windows/macOS/Linux 的 Linux 系统组装台：对话生成 spec → 可视化分层 → 沙箱构建 → 启动验证 → 可分享的团队产物。

- 状态：设计阶段（v0.0.1），构建引擎未实现
- 相关决策：[ADR-0001](../adr/0001-cross-platform-engine.md)、[ADR-0002](../adr/0002-base-spectrum.md)、[ADR-0003](../adr/0003-windows-app-modes.md)、[ADR-0004](../adr/0004-team-bundles.md)
- 路线图：[roadmap.md](../roadmap.md)

---

## 1. 产品定义

Sysemble 是一个**桌面软件**，不是网站、不是 CI 服务。用户在自己的 Windows / macOS / Linux 电脑上打开它，回答一组问题，得到一个可启动的 Linux 系统。

它解决的不是"如何编译内核"，而是三个更常见的痛点：

1. **装机脚本不可复现**：每个人的 `post-install.sh` 都不一样，半年后没人能重建同一台机器。
2. **Windows 软件绑死**：想用 Linux 桌面，但某个专业软件只有 Windows 版，只能双系统或忍受 Wine。
3. **团队镜像不可信**：发给同事的镜像没有 spec、没有 SBOM、没有验证记录，出了问题无法追溯。

**一句话**：把"我的系统"从一个手工过程，变成一个可审阅、可构建、可验证、可分享的 spec。

### 不是什么

- 不是 LFS 教学工具（L4 只是专家模式，不是默认路径）
- 不是发行版发行商（不做公开镜像站）
- 不是 Windows 模拟器（Windows 跑在 KVM 里，或走 Wine）
- 不是云服务（无账号、无遥测、可完全离线）

---

## 2. 目标用户与切入人群

| 用户 | 场景 | 核心诉求 |
|---|---|---|
| **被 Windows 软件绑住的开发者** | 想用 Linux 桌面，但离不开 Office/CAD/行业软件 | Windows 应用"像本地软件一样打开" |
| **换系统的开发者** | 从 Ubuntu 迁到自组桌面，保留工具链 | 一键带齐开发环境 |
| **小团队平台工程师** | 给团队发标准开发机 | 可复现、可分享、可验证 |
| **极客/学生** | 想理解一个系统是怎么搭起来的 | 分层可见、可学习 |

**Wedge**：第一类。痛感最强、现有方案（双系统/Wine/远程桌面）体验最差、且正好能展示"本地构建 + Windows 层"的差异化。

---

## 3. 五个关键决策

### 3.1 跨三端：一个 App，引擎永远在 Linux 里

**回答**："需要支持 Windows、macOS、Linux，封装在一个软件中。"

构建 Linux 镜像需要 loop device、mount、chroot、KVM——这些在 Windows/macOS 上不存在。所以架构是：

```
Tauri UI（三端原生）
   ↕ 本地 IPC
Engine（同一套 Linux daemon，跑在各自的 Linux 环境里）
   ├─ Windows → WSL2（App 托管的发行版）
   ├─ macOS   → Apple Virtualization.framework（arm64 Linux VM）
   └─ Linux   → 原生 KVM + podman
```

- **UI 原生**：Tauri 2，用系统 WebView，不用 Electron。
- **引擎统一**：一个签名的 Linux 引擎镜像（含 podman、qemu、mkosi、mmdebstrap、archiso 等），三端共用，版本一致。
- **Windows**：首次启动安装/启用 WSL2，导入引擎镜像；后续与 Docker Desktop 类似但更轻。
- **macOS**：用 Virtualization.framework 起一个 arm64 Linux VM；不需要用户装 Docker。
- **Linux**：直接跑，复用宿主 KVM 与 podman。

**构建目标架构矩阵**（宿主支持 ≠ 目标支持）：

| 宿主 | 引擎 | 原生目标 | x86_64 目标 |
|---|---|---|---|
| Windows x86_64 | WSL2 | x86_64 | 原生 |
| Windows arm64 | WSL2 arm64 | arm64 | qemu-user（慢） |
| macOS arm64 | Virtualization.framework | arm64 | Rosetta for Linux / qemu（实验） |
| Linux x86_64 | KVM | x86_64 | 原生 |
| Linux arm64 | KVM | arm64 | qemu-user（慢） |

**取舍**：macOS arm64 上构建 x86_64 镜像会慢 3–10 倍，P0 只保证"原生架构"；跨架构标为实验特性，并提示可用远程构建机（P3）。

### 3.2 基础谱系：L0 到 L4，由问询决定，不默认 LFS

**回答**："从最小 base 到字面 LFS，按照需求推荐，需要对设计者问询。"

定义五级：

| 级别 | 基础 | 典型体积 | 构建时长 | 适合 | 风险 |
|---|---|---|---|---|---|
| **L0 Minimal** | Alpine / Buildroot | < 300 MB | 5–15 min | 服务器、边缘、学习 | musl 兼容性差 |
| **L1 Minbase** | Debian/Ubuntu `minbase` | 300–600 MB | 10–25 min | 最小桌面、定制栈 | 需要自己配桌面 |
| **L2 Standard** | L1 + 桌面 + 常用软件 | 2–4 GB | 20–45 min | 日常工作站 | 体积/驱动 |
| **L3 Remaster** | 官方 ISO + 修改 | 3–6 GB | 15–30 min | 硬件兼容优先 | 改动受限 |
| **L4 LFS** | 字面 LFS（编译工具链） | 3–8 GB | 8–20 h | 教学、极端定制 | 极易坏、不可维护 |

**问询决定级别**（结构化问题，不是自由聊天）：

1. 用途：桌面 / 开发 / 服务器 / 边缘 / 学习
2. 必须运行的软件清单（含 Windows 软件）
3. 硬件：CPU 架构、GPU、WiFi、内存、磁盘
4. 维护意愿：愿意多久重装/滚动更新
5. 时间预算：今晚就要 / 可以等一天 / 可以等一周
6. 磁盘预算：< 5 GB / 20 GB / 50 GB+
7. 团队技能：会不会自己排障
8. 合规要求：个人 / 团队基线 / 受监管

**推荐逻辑**（简化）：

```
要 Windows 专业软件 + 桌面        → L2 或 L3（不要在 L0/L1 上折腾）
硬件很新（新 GPU/WiFi）           → L3（官方 ISO 驱动全）
< 1 GB / 无 glibc 需求            → L0
要"完全理解每一层" + 有时间        → L4（需二次确认）
其余默认                          → L2
```

**L4 的门槛**：必须显式确认"我知道要 8–20 小时、可能失败、不适合日常使用"，并在 UI 上显示红标。L4 是实验室模式，不是产品默认。

### 3.3 Windows 应用：四档，按客户要求与问询选择

**回答**："需要的是接近能直接当作软件打开方式，实际上以客户要求和问询为准。"

四档能力，从轻到重：

| 模式 | 体验 | 适用 | 前提 |
|---|---|---|---|
| **wine** | 原生窗口，无 VM | 微信、网银、老软件 | 兼容性参差 |
| **remoteapp** | 单个 Windows 窗口出现在 Linux 桌面 | Office、行业软件 | Windows Pro/Enterprise + RDP |
| **desktop** | 完整 Windows 桌面窗口 | 通用 | 4–8 GB 内存 |
| **looking-glass** | 低延迟 Windows 桌面 | CAD/游戏/视频 | 第二块 GPU + VFIO |

**"像本地软件一样打开"的实现**：
- `remoteapp` 用 FreeRDP 的 `/app:` 模式，为每个 Windows 应用生成一个 `.desktop` 条目；点击即启动 VM（若未运行）+ 拉起该应用窗口；剪贴板、磁盘、音频、打印机走 RDP 重定向。
- 需要 Windows Pro/Enterprise；Home 版没有 RDP 服务端。RemoteApp 在客户端 Windows 上并非微软官方支持场景，**必须实测**，失败则回退 `desktop`。
- `looking-glass` 需要双 GPU 与 VFIO 配置，只在检测到第二块 GPU 时提供。

**问询决定模式**：

```
应用清单里有 GPU 密集软件？ → 是 → looking-glass（有双 GPU）否则 desktop
只需要偶尔用某个 Windows 软件？ → 是 → wine 优先，失败再 remoteapp
有 Windows Pro/Enterprise license？ → 是 → remoteapp 可选
都没有 → desktop（最稳）
```

**法律边界**：不下载、不分发 Windows ISO；不提供激活绕过；virtio-win 可自动下载但必须钉版本+校验。

### 3.4 团队产物：可分享、合规、可复现、多设备

**回答**："产物由使用的团队配置，需要可以分享的合规版本 Linux，可复现可多设备使用。"

产出的不是一张 ISO，而是一个 **bundle**：

```
bundle/
  buildspec.yaml      # 团队配置，签名，可 review
  plan.json           # resolved：包、体积、digest
  sbom.cdx.json       # CycloneDX
  evidence.json       # 构建 + 启动断言
  signature.sig       # cosign / minisign
```

**可复现**：
- base 钉到快照（Debian 用 `snapshot.debian.org`，Ubuntu 用 `snapshot.ubuntu.com`）
- 模块钉版本 + 内容摘要
- 构建时间戳固定（`SOURCE_DATE_EPOCH`）
- 记录 `plan.json` 与包清单
- 同一 spec 在任意设备上产出相同 digest（逐步达成）

**合规版本**：
- 合规 profile：`cis-l1` / `stig` / `nist-800-53` / 自定义
- per-control 结果 + 缺失项 + 人工处置
- 不把"启用了某个 feature"说成"合规"

**多设备**：
- 一份 artifact 装到多台设备；设备身份（hostname、SSH key、机器密钥）在**首次启动**注入，不重新构建。
- 支持 USB 写入、PXE/网络启动、云镜像导入。
- 硬件 profile：GPU/WiFi/触摸板差异用模块开关表达。

**分享**：spec 放 Git，artifact 放任意 OCI registry，签名用 cosign。`sysemble verify` 在安装前校验签名、SBOM、证据。

### 3.5 技术栈：Rust + Tauri

```
crates/
  sysemble-core      # spec 类型、校验、resolver、状态机
  sysemble-engine    # 沙箱编排（podman）、构建、QEMU
  sysemble-mcp       # MCP server（rmcp）
  sysemble-cli       # 命令行
apps/
  desktop            # Tauri 2 + React/Svelte
```

- UI：Tauri 2 + 系统 WebView；前端 React + TypeScript。
- 核心：Rust（单二进制、无运行时、权限模型清晰）。
- 存储：SQLite（rusqlite）+ 内容寻址 blob。
- 虚拟化：QEMU/KVM，libvirt 可选；macOS 用 Virtualization.framework 跑引擎 VM。
- MCP：`rmcp`（Rust 官方 SDK），stdio + 本地 HTTP。

---

## 4. 架构

```
┌──────────────────────────────────────────────────────────────┐
│ Tauri UI                                                      │
│  conversation · layer canvas · diff · console · preview       │
└───────────────────────────┬──────────────────────────────────┘
                            │ JSON-RPC over unix socket / named pipe
┌───────────────────────────▼──────────────────────────────────┐
│ Engine (Linux)                                                │
│  SpecStore · Resolver · StateMachine · JobRunner              │
│  EvidenceStore (SQLite + CAS) · MCP Server                    │
└───────────────────────────┬──────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────┐
│ Build sandbox (podman, rootless)                              │
│  rootfs → configure → image → QEMU → assertions → export      │
└──────────────────────────────────────────────────────────────┘
```

**宿主零 root**：所有需要特权的操作都在引擎 VM 的容器里完成。宿主只装 App 与 WSL2/虚拟化框架。

---

## 5. Spec 模型

见 [spec/buildspec.schema.json](../../spec/buildspec.schema.json)。四层：

1. **meta**：名称、描述、标签
2. **target**：base（kind/release/pin）、arch、firmware、output
3. **system**：hostname、locale、users、packages、services、kernel
4. **能力层**：desktop、virtualization、dev、security、installer
5. **verify**：scenarios/assertions
6. **sharing**：team、compliance profile、publish

三态视图：`declared`（用户写）→ `resolved`（引擎补全）→ `planned`（体积/时长估算）。UI 必须能 diff。

**严格性**：顶层 `additionalProperties: false`；未知字段报错而不是静默忽略。版本通过 `apiVersion` 演进。

---

## 6. 构建策略

由 Resolver 选择，用户不选底层：

| 策略 | 实现 | 适用 |
|---|---|---|
| Bootstrap | `mmdebstrap` / `pacstrap` | L1–L2 |
| Remaster | xorriso + squashfs | L3 |
| Declarative | mkosi / `nix build` | Fedora/Nix |
| Minimal | Alpine `apk` / Buildroot | L0 |
| LFS | 分阶段脚本 + 缓存 | L4（实验） |

所有策略都输出统一的 `Artifact` + `Evidence`。

---

## 7. 模块系统

见 [spec/module.schema.json](../../spec/module.schema.json)。模块声明：

- `id` / `kind` / `version`
- `requires` / `provides` / `conflicts`
- `packages`（按发行版族）
- `hooks`（构建时/首次启动）
- `asserts`（验证）
- `size_mb` / `build_time_min`
- `boundary`（证明边界：保证什么、不保证什么）

模块必须带 `boundary`，UI 显示"未验证"而不是默认绿。

---

## 8. 对话与可视化

### 对话

- 一次 1–2 个结构化问题，答案直接落 spec。
- LLM 只做"需求 → 选项"的映射，不生成命令。
- 不确定时给推荐 + 理由 + 代价（时间/体积/兼容性）。

### 画布

层级块 + 体积/时长标注 + 冲突灰显 + hover 原因。构建前强制 diff。

### 预览

不必等完整构建：先起一个最小 QEMU 预览，确认桌面/分辨率/输入，再继续。

---

## 9. MCP

本地 MCP，stdio 优先：

| 组 | 工具 |
|---|---|
| host | `host_probe` |
| base | `list_bases`、`get_base` |
| catalog | `search_modules`、`get_module` |
| spec | `get_spec`、`draft_spec`、`patch_spec`、`validate_spec`、`diff_spec` |
| plan | `resolve_plan`、`estimate_plan` |
| build | `start_build`、`get_build_status`、`get_build_log`、`cancel_build` |
| vm | `boot_preview`、`vm_screenshot`、`vm_exec`、`stop_vm` |
| artifact | `export_artifact`、`verify_artifact` |
| evidence | `get_evidence` |
| interaction | `ask_user`、`request_decision` |

权限三态：read / write / destructive。Workspace jail、禁止改宿主、destructive 需确认、资源配额、审计日志。

---

## 10. "可用"的验收

| 检查 | 断言 |
|---|---|
| 启动 | 到登录管理器 |
| 登录 | 用户可登录 |
| 会话 | 实际 session 是 plasma/gnome |
| 网络 | DHCP + DNS |
| 音频 | PipeWire sink |
| GPU | 驱动加载 |
| 应用 | 浏览器可开 |
| Windows | 所选模式可用（remoteapp 能起单窗口） |
| 开发 | 运行时版本正确 |
| 安装器 | Calamares 可启动 |

未测项标 `untested`，不默认绿。

---

## 11. 路线图

见 [roadmap.md](../roadmap.md)。

- **P0**：CLI + Debian + 10 模块 + qcow2 + QEMU + 3 断言
- **P1**：Tauri UI + ISO + installer
- **P2**：Windows 四模式 + dev profiles + MCP
- **P3**：Arch/Nix + 团队 bundle + 签名 + 多设备

---

## 12. 风险

| 风险 | 缓解 |
|---|---|
| 三端引擎复杂度 | 引擎镜像统一，UI 只做壳 |
| macOS x86_64 构建慢 | 只保证原生架构，跨架构标实验 |
| Windows RemoteApp 不稳定 | 失败回退 desktop，并在 UI 明示 |
| 构建时间/磁盘 | 缓存、增量、预览 VM、配额 |
| LFS 期望管理 | 红标 + 二次确认 + 明确不推荐日常 |
| 团队产物信任 | 签名 + SBOM + 证据 + verify 门 |
| 范围爆炸 | P0 只做 Debian 桌面 |

---

## 13. 未决问题

1. 引擎镜像的分发方式（随 App 打包 / 首次下载 / OCI）
2. macOS 上是否值得支持 x86_64 目标（Rosetta 方案需实测）
3. RemoteApp 在 Windows 11 客户端的可用性（需真机验证）
4. 团队 bundle 的默认 registry（OCI / Git LFS / 本地）
5. L4 是否进入 P3 之前的产品
