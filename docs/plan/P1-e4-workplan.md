# P1-e4 工作分解：桌面端 VM 后端 + 一体化封装设计

> 目标顺序（用户指令）：**先在本机把完整链路跑通**（App 后端 → VZ helper → guest 构建 → 产物），再保证兼容性/稳定性，最后给出“所有环境与内容封装进一个软件”的封装设计。P1-e3 的 CLI 原型已验证 VM 能启动、共享、构建；本切片把它接进 Tauri 壳，并冻结打包方案。

- 日期：2026-11-25
- 基线提交：`f998cfd`（P1-e3 验收）
- 前置：P1-e3 的 `engine/vm/**` 已合入；本机已有 VM 镜像与已签名 helper

## 0. 范围与判定

1. **E4a 桌面 VM 后端（实现）**：`engine_info` 增加 `kind=vm`；`start_build(execute)` 通过 helper 跑 VM；日志/状态/取消/错误复用 P1-b 机制；本机用真实镜像跑一次 App 级 E2E。
2. **E4b 兼容性与稳定性（实现 + 文档）**：macOS 13+ 保护、Intel/无镜像/缺 entitlement 的降级、重复构建、取消、残留清理、磁盘空间与超时错误可读。
3. **E4c 一体化封装设计（文档）**：单 `.app` 内含 helper + 压缩 VM 镜像 + 首次安装/校验/签名/升级/兼容矩阵；不在本切片实现完整安装器（下一轮 E5）。
4. **E4d 独立验收**：本机真实 App 后端 E2E + CI 回归 + 封装设计审查。

本切片**不**要求：Docker 依赖移除实现（设计即可）、Windows/WSL2、x86_64 guest、Tauri GUI 自动截图。

## 1. 架构

```
Tauri desktop (macOS arm64)
  engine_info ──► local → vm → container → none
                    │            └─ docker/podman (P1-e2)
                    └─ helper probe + VM image manifest
  start_build(execute)
        ├─ kind=vm:  <helper> run --image-dir <dir> --repo <repo>
        │              --out <out> --plan <out>/plan.json --timeout 1800 --json
        │              stdout/stderr → <out>/build.log
        └─ kind=local/container: P1-b/P1-e2 原路径
  cancel: 进程组 SIGTERM → helper 捕获 → stop VM → exit 143（已实测）
```

宿主与 guest 的边界不变：repo → `/work`（ro）、out → `/export`、guest 在 `/out` 构建、只导出顶层产物。

## 2. 冻结接口

### 2.1 `EngineInfo`（只增字段，保持 P1-e1/e2 兼容）

```json
{
  "kind": "local|container|vm|none",
  "available": true,
  "platform": "macos",
  "reason": "vm engine: sysemble-vm 0.1.0 · helper signed · image arm64",
  "runtime": null,
  "image": "sysemble-vm:0.1.0",
  "image_present": true
}
```

- 探测顺序：`local`（Linux root）→ `vm`（macOS arm64，helper `probe --json` 的 `supported && entitled` 且镜像清单有效）→ `container`（docker→podman）→ `none`。
- VM 不可用但容器可用：返回 `container/available=true`，reason 可保留一句 VM 缺失原因（不阻塞）。
- VM helper 存在但镜像缺失：不误报 `available`；若容器也不可用，`kind=vm, available=false`，reason 指向 `engine/vm/image/build-image.sh`（开发）或“app 包内镜像缺失”。
- 探测命令 4s 超时；`engine_info` 永不因探测失败返回 Err。

### 2.2 路径发现（开发/打包共用）

helper（按顺序，第一个可执行且 `probe` 通过者）：
1. `SYSEMBLE_VM_HELPER`（测试/高级用户）
2. `<repo>/engine/vm/macos/.build/release/sysemble-vm`
3. `<exe_dir>/../Helpers/sysemble-vm`（`.app/Contents/Helpers/`，E4c 布局）

镜像目录（含 `sysemble-vm.json` + `disk.img`/`vmlinuz`/`initrd.img`）：
1. `SYSEMBLE_VM_IMAGE_DIR`
2. `<repo>/engine/vm/image/build`
3. `~/Library/Application Support/Sysemble/engine-vm/<version>/`（扫描版本目录，取最高有效版本）

### 2.3 VM 构建命令（冻结）

```
<helper> run --image-dir <abs> --repo <abs> --out <abs>
             --plan <out>/plan.json --timeout 1800 --json
```

- 仅 `execute` 使用；`dry-run` 仍走宿主 bash（P1-b），不探测引擎。
- `--plan` 与 BuildManager 已写的 `<out>/plan.json` 相同：helper 必须幂等（同路径不重复拷贝），E4a 负责确认/修正。
- stdout/stderr 合并写 `<out>/build.log`；退出码 = helper 退出码；JSON 结果只用于日志尾（可选打印）。
- 取消：沿用进程组终止；helper 已实现 SIGTERM→stop VM（P1-e3 实测 143），不得遗留 `sysemble-vm` 进程。
- 超时/失败：helper exit 4（启动/超时）或 guest rc；UI 显示失败日志，不静默。

### 2.4 UI

- 可用时状态栏：`Engine: vm · arm64`；local/container 保持 P1-e2 文案。
- Build tooltip：`Run the builder with --execute using the Virtualization.framework engine`。
- 无引擎时沿用 P1-e1 门控；dry-run 始终可用。

## 3. 切片

| 切片 | 内容 | 边界 | 状态 |
|---|---|---|---|
| **E4a** 桌面 VM 后端 | probe/classification、路径发现、VM argv、execute 接管、取消、UI、单测、`#[ignore]` 真实 E2E | `apps/desktop/**` | 已交付（62 测试 + 本机 E2E 两次） |
| **E4b** 兼容/稳定 | 降级矩阵、错误路径、重复/取消/残留、文档 | `apps/desktop/**` + 主线程 docs | E4a 内完成 |
| **E4c** 封装设计 | 单 `.app` 布局、镜像压缩/稀疏解压、首启安装、签名/公证、升级/回滚、体积与磁盘预算 | `docs/design/**` | 已交付（ADR 0002） |
| **E4d** 独立验收 | 真实 App 后端 E2E、日志/产物哈希、CI 回归、设计审查 | `docs/acceptance/**` | 待 |

## 4. 验收矩阵

| # | 检查 | 通过条件 | 证据 |
|---|---|---|---|
| W1 | probe | 本机 `kind=vm, available=true`；停用 helper/镜像后降级为 container 或 none，reason 可读 | 单测 + 本机 |
| W2 | argv | 逐 token 断言 §2.3；repo/out 含空格或中文路径不破坏 argv | 单测 |
| W3 | App E2E | `BuildManager` 真实 execute：exit 0、`rootfs.tar.gz`、`artifact-vm.json`、`build.log` 非空、sha256 一致 | 本机 `--ignored` 测试 |
| W4 | 取消 | 构建中 cancel → 状态 cancelled、无残留 VM/helper、out 保留已写日志 | 本机 + 单测 |
| W5 | 重复 | 同一 out 连续两次 execute 均成功；第二次清理旧 `.sysemble-vm` 状态 | 本机 |
| W6 | 降级 | 无 VM 镜像/无 entitlement/Intel → 不误报 vm；容器可用则用容器；否则可读错误 | 单测 |
| W7 | 回归 | 根 61、桌面 39+新增、clippy、acceptance 17/17、11 个 CI job | 本机 + CI |
| W8 | 封装设计 | 文档覆盖布局/首启/解压/签名/公证/升级/兼容/磁盘预算/失败模式 | 设计评审 |
| W9 | 独立验收 | 验收代理独立重跑 W3/W7 并写报告 | `docs/acceptance/P1-e4.md` |

## 5. 兼容性与稳定性清单（E4b）

- macOS 13+：helper deployment target 13；`isSupported` 仅在 14+ 查询；13/14 未实测需在文档标注。
- Intel Mac：helper 不适用（VZ arm64 guest）；probe 返回不可用，容器后端兜底；不得把 Intel 报成 `vm`。
- 无 entitlement / MDM 拒绝：`probe` 的 `entitled=false` → vm 不可用，reason 含签名指引。
- 缺镜像 / 缺 helper / 镜像架构不是 arm64 / 文件被截断：逐项可读错误；不启动 VM。
- 重复构建：每次 helper 克隆基础盘、清理 `.sysemble-vm/{ready,done,job.sh,log}`；out 内旧产物覆盖。
- 取消/崩溃：SIGTERM 停 VM；崩溃后残留的 `vm-disk.img` 可删除（文档写明）；不残留 helper 进程。
- 路径：repo/out 可含空格、中文；宿主路径不进 guest。
- 磁盘：镜像 6 GiB 稀疏（实际 ~0.5 GiB）；每次构建需要 ~2 GiB 写空间；首次安装前预检（E4c）。
- 日志：`build.log` 保留 helper stdout/stderr + JSON 结果尾；失败时 UI 可读。

## 6. 封装设计要点（E4c 文档必须回答）

1. `.app` 目录布局：`Contents/MacOS/sysemble`、`Contents/Helpers/sysemble-vm`（带 entitlement）、`Contents/Resources/engine-vm/{disk.img.zst,vmlinuz,initrd.img,sysemble-vm.json}`。
2. 体积预算：镜像压缩后目标 ≤ 450 MB；kernel+initrd ~70 MB；app ~30 MB；总体 < 600 MB。
3. 首启安装：校验 sha256 → 稀疏解压到 `~/Library/Application Support/Sysemble/engine-vm/<version>/`（零块用 seek 保持 6 GiB 逻辑/0.5 GiB 实际）→ 原子 rename → 写安装标记；失败可重试、不破坏旧版本。
4. 签名/公证：Developer ID Application + hardened runtime；先签 helper（含 `com.apple.security.virtualization`）再签 app；notarize + staple；开发模式 ad-hoc 降级。
5. 升级/回滚：镜像版本与应用版本绑定；新版目录并存，旧版构建完成后 GC；清单 schema 版本化。
6. 兼容矩阵：macOS 13/14/15/26（arm64）、Intel（容器兜底或不支持）、Windows/WSL2（后续）、Linux（native/容器）。
7. 失败模式：磁盘不足、SIP/MDM 拒绝、镜像损坏、helper 不兼容、压缩包截断、首启中断；每项给出用户可读提示与恢复动作。
8. 安全：不运行时下载镜像（默认全内置）；sha256 固定；guest 只读仓库 + 固定 job 协议；无宿主路径注入。

## 7. 非目标

- 本切片不做完整首启安装器/公证流水线（E5 实现）；不做 Windows；不改 `builders/**`；不做 GUI 自动化截图。
