# Roadmap

> 原则：每个阶段只交付一条能跑通的闭环，不做"半成品矩阵"。

## P0 · CLI 闭环（3–4 周）

> **P0 已完成（2026-11-23）**：validate/plan、真实 Debian rootfs、GPT 分区 + GRUB EFI + OVMF 启动（控制台 5 条、XFCE 桌面 8 条断言）、278 MB live ISO（6 条断言）、无头安装器（安装到空白磁盘并从磁盘启动，5 条断言）。CI `boot-smoke` / `desktop-smoke` / `live-smoke` / `install-smoke` 全过。Calamares UI 与 Arch/Nix 后端进入 P0-e/P1。

**目标**：一条命令从 spec 到可登录的 Debian KDE 桌面。

- `buildspec.yaml` + JSON Schema + `sysemble validate`
- Debian 13 base（`mmdebstrap`）
- 10 个模块：kernel-lts、plasma、sddm、firefox、pipewire、network-manager、nvidia（可选）、ssh、firewall、dev-python
- 输出 qcow2
- QEMU 无头启动 + 3 条断言（boot、login、session）
- `sysemble plan`：体积/时长粗估
- 验收：CI 在干净容器里复现一次构建

**不做**：UI、ISO、Windows、MCP、签名。

## P1 · 可视化（6–8 周）

> **P1-a / P1-b / P1-c / P1-e1 / P1-e2 / P1-e3 / P1-e4 已完成（2026-11-23/26）**：Tauri 2 壳（`read_spec` / `validate` / `plan` / `inspect`；构建控制 `start_build` / `get_build` / `get_build_log` / `cancel_build`）、六层视图与 declared→resolved diff、引擎探测与显式门控；P1-e2 增加版本化 Debian 引擎镜像（`engine/image`）与 docker/podman 容器后端，CI `engine-check` 在容器内完成 build + boot-check；P1-e3 增加 Apple Silicon 的 Virtualization.framework VM（`engine/vm`：arm64 Debian guest + virtiofs + guest 内最小构建）；P1-e4 把 VM 接进桌面：`engine_info` 返回 `kind=vm`，execute 通过已签名 helper 运行 VM，dry-run/local/container 保留兜底。封装设计见 [ADR 0002](design/0002-vm-packaging.md)：单 `.app` 内置 helper + 压缩镜像，首启安装器与 x86_64 in-VM 路径（Rosetta/podman）是下一阶段；P1-e6a Rosetta for Linux spike 通过（guest 内运行 x86_64，同实现开销 1.44×）；P1-e6b 进一步验证 engine-in-VM：guest 内 podman + 现有 amd64 镜像真实构建 x86_64 qcow2，rc=0、qcow2 sha 与 artifact 一致。L2 封装路线确定为 VM 内 podman + 预装镜像（12 GiB 盘）；WSL2 待后续。


- Tauri 2 壳 + React 画布
- 层级块、体积/时长、冲突灰显
- declared → resolved diff
- 构建控制台 + 日志流
- 预览 VM（QEMU 窗口 + 截图）
- ISO 输出 + Calamares
- 模块扩到 25 个（NVIDIA、WiFi 固件、Steam、OBS）
- 验收：非命令行用户完成一次构建

## P2 · Windows + Dev + MCP（8–10 周）

- `windows` 模块四模式：wine / remoteapp / desktop / looking-glass
- 首次启动向导（挂载用户 ISO、virtio-win、vTPM）
- dev profiles：python / node / rust / go
- 本地 MCP server（20 工具）+ `ask_user`
- 结构化问询引擎（问题图 + 推荐逻辑）
- 验收：Claude Code 通过 MCP 完成"带 Windows 单窗口的开发机"

## P3 · 团队与扩展（持续）

- Arch / Nix 后端
- 团队 bundle：签名、SBOM、evidence、verify
- OCI 发布 + USB/PXE 多设备
- 可复现构建（snapshot 源、SOURCE_DATE_EPOCH）
- L4 LFS 实验室模式
- 插件 SDK + 模块仓库
- 远程构建机（跨架构）

## 明确不做

- 公开镜像分发站
- Windows ISO 分发/激活
- 多租户 SaaS
- ARM 目标的完整支持（P3 之后评估）
