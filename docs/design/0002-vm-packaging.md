# ADR 0002：macOS 一体化封装设计（引擎 VM + 应用）

- 状态：**设计（P1-e4c）**，实现拆到 P1-e5/P1-e6
- 日期：2026-11-25
- 关联：`docs/plan/P1-e3-workplan.md`（VM 原型）、`docs/plan/P1-e4-workplan.md`（桌面接入）、`docs/design/0001-sysemble-design.md`
- 目标：用户只安装一个 Sysemble `.app`，**不要求预装 Docker/命令行工具/手工下载镜像**，即可在 Apple Silicon Mac 上完成构建。

> **修订 2026-11-26（P1-e4 验收 §6.2）**：修正安装目录原子性/末尾 `set_len`、10 GiB 预检、app↔镜像版本绑定语义、嵌套代码逐个签名、Windows/Linux 兼容行、helper ABI/首启中断/MDM 失败模式；并明确“构建后删除克隆盘”是 E5 目标，P1-e3/e4 现状是保留在 out。

## 1. 现状与差距

| 能力 | 现状 | 一体化要求 |
|---|---|---|
| VZ helper | 已用 SwiftPM 构建、ad-hoc 签名、带 `com.apple.security.virtualization` | 随 app 分发、Developer ID 签名、公证 |
| 引擎 VM 镜像 | 在仓库本地用 Docker 构建（`engine/vm/image/build`） | 构建期预生成、压缩后放进 app、首启安装 |
| 构建入口 | CLI `sysemble-vm run`；E4a 接入桌面后端 | Build 按钮直接使用，无终端操作 |
| 依赖 | 构建镜像需要 Docker Desktop | 运行时零外部依赖 |
| 构建目标 | arm64 guest：arm64 rootfs（原型） | x86_64 磁盘/ISO（产品主目标）→ 见 §8 |

结论：**L1 封装**（本 ADR 主体）让 macOS 用户零 Docker 完成 arm64 VM 构建；**L2 封装**（§8）再把 x86_64 目标搬进同一个 VM，彻底去掉 Docker 依赖。L2 需要先验证 Rosetta for Linux。

## 2. 决策摘要

1. **单 `.app`**：`Sysemble.app` 内含 Tauri 主程序、VM helper、压缩 VM 镜像与清单；运行时不再下载引擎镜像（默认全内置）。
2. **helper 与 app 分开签名**：helper 先签（带 virtualization entitlement），app 后签；最后 notarize + staple。开发构建允许 ad-hoc 降级，但发布构建必须 Developer ID。
3. **首启安装到 Application Support**：`~/Library/Application Support/Sysemble/engine-vm/<version>/`，sha256 校验 + 稀疏解压 + 原子落盘；app 包内文件保持只读。
4. **每次构建克隆基础盘**：APFS clone（`cp -c`），构建结束默认删除克隆；基础镜像永不被 VM 写入。
5. **压缩用 zstd**：实测 `disk.img` 6 GiB 逻辑 / 528 MiB 实际 → **193 MiB**（zstd -19，28.5 s，arm64 容器 10 核）；包体预算见 §4。
6. **升级按版本目录并存**：app 包内固定**一个**镜像版本（app 版本 ↔ 镜像版本绑定），安装目录以镜像版本命名；`min_app_version` 由 probe 读取校验。新版本安装成功后保留 1 个旧版本用于回滚，其余 GC。
7. **兼容性先保 macOS 13+ arm64**，Intel 不支持 VZ VM（容器后端兜底）；13/14 未实测，发布前补测。
8. **安装目录是一个自包含单元**：`<version>/{sysemble-vm.json,vmlinuz,initrd.img,disk.img,installed.json}` 先写 `.tmp/` 再整目录 rename，避免半安装状态。

## 3. `.app` 目录布局

```
Sysemble.app/
  Contents/
    Info.plist
    MacOS/
      sysemble                     # Tauri 主程序
    Helpers/
      sysemble-vm                  # Swift VZ helper（签名 + entitlement）
    Resources/
      engine-vm/
        sysemble-vm.json           # 清单（含 sha256/版本/架构/体积）
        disk.img.zst               # 压缩根盘（实测 193 MiB）
        vmlinuz                    # 37.8 MB（可选再压 ~12 MB）
        initrd.img                 # 36.0 MB（已压缩）
      ...                          # Tauri 前端资源
```

- helper 放 `Contents/Helpers/`（E4a 已探测 `<exe_dir>/../Helpers/sysemble-vm`）。Tauri 默认把 sidecar 放 `MacOS/`，因此用**打包后脚本**把 helper 复制到 `Helpers/`、签名，再重签 app；不依赖 `--deep`。
- VM 镜像放 `Resources/engine-vm/`，用 Tauri `bundle.resources` 或打包脚本复制；资源只读。
- 清单字段沿用 `engine/vm/image` 的 `sysemble-vm.json`（schema 1），增加 `bundle` 段：`disk_zst_sha256`、`installed_size_bytes`、`min_app_version`。

## 4. 体积与磁盘预算（实测/估算）

| 项 | 压缩/实际 |
|---|---|
| `disk.img` | 6,442,450,944 B 逻辑 / 553,435,136 B 实际 → zstd **202,579,256 B（193 MiB）** |
| `vmlinuz` | 37,797,824 B（可选 zstd → ~12 MiB） |
| `initrd.img` | 36,024,136 B（已压缩） |
| helper + app + 前端 | ~30–40 MiB |
| **app 包（L1）** | **约 294–304 MiB**（上限按实测修正） |
| 首启安装后 | **598 MiB**（553,435,136 B 盘 + kernel/initrd + 清单，实测） |
| 单次构建临时 | 克隆盘实际 **~1.48 GiB** + 产物 tar 235 MiB → 峰值 **~1.71 GiB** |
| 建议最小空闲 | **10 GiB**（安装 0.6 GiB + 构建 1.7 GiB + 非 APFS 退化的 6.44 GiB + 余量） |

结论：L1 包体可接受（约 300 MiB，低于原 450 MiB 预算）。

## 5. 首启安装（E5 实现）

状态机：`absent → verifying → installing → verifying_image → ready`（失败可重试，不破坏已安装版本）。

目标目录（自包含单元）：

```
~/Library/Application Support/Sysemble/engine-vm/<version>/
  sysemble-vm.json    # 从 app 包复制（只读）
  vmlinuz
  initrd.img
  disk.img            # 稀疏，逻辑 6,442,450,944 B
  installed.json      # version/disk_sha256/installed_at/app_version
```

1. **预检**：`statfs` 可用空间 ≥ **10 GiB**；目标目录可写；macOS arm64；helper 可执行且 entitlement 有效（`probe --json`）；app 包内清单 `min_app_version` ≤ 当前 app 版本。
2. **校验包内文件**：按 `sysemble-vm.json` 重算 `disk.img.zst` + `vmlinuz` + `initrd.img` 的 sha256；不匹配即失败（安装包损坏）。
3. **整目录临时安装**：在 `engine-vm/.tmp-<version>-<pid>/` 内复制清单/kernel/initrd，稀疏解压 `disk.img`，写 `installed.json`；全部成功后 `rename` 为 `<version>/`（同卷原子）；失败只删本临时目录。
4. **稀疏解压**：流式 zstd 解码，1 MiB 块；整块为 0 时 `seek`，否则 `write`；**结束时 `set_len(6,442,450,944)`**（末块可能落在空洞里，不调用会截断）。`fsync` 后重算解压后 sha256（读 6 GiB 逻辑，稀疏读取约数秒）并与清单比对，再写 `installed.json`。
5. **恢复**：app 启动时扫描并删除超过 1 小时的 `.tmp-*` 残留；`installed.json` 存在但 `disk.img` 缺失/尺寸不符时把该版本标记为损坏并重新安装。
6. **IPC/UI**：新增 `engine_install` 命令 + 进度事件（`verifying/installing/ready/error`）；安装完成前 Build 按钮禁用并显示进度；失败给可读原因（空间、校验、MDM、I/O）。
7. **probe 读取安装态**：`engine_info` 只接受含有效 `sysemble-vm.json` + 四个文件的版本目录；`installed.json` 缺失/不匹配时视为未安装（E5 实现）。

**解压实现**：Rust `zstd` crate（流式 Decoder），不依赖系统二进制；稀疏写入用 `std::io::Seek` + 末尾 `set_len`。若目标卷不是 APFS（极少），退化为普通写入，安装空间需求变为 6.44 GiB，预检要求提高到 **10 GiB** 仍成立。

## 6. 签名、公证与分发

1. **构建期（inside-out 签名）**
   - `engine/vm/image/build-image.sh` 产出版本化镜像；`engine/vm/bundle/build-bundle.sh` 压缩、写清单、做 sha256。
   - helper 用 `swift build -c release` 构建；`codesign --force --options runtime --timestamp --entitlements sysemble-vm.entitlements --sign "Developer ID Application: …"`。
   - 打包脚本先枚举并逐个签 app 内的**所有嵌套可执行代码**：Tauri 的 `Contents/Frameworks/*.framework`（框架二进制与版本目录）、`.dylib`、sidecar/plugin 可执行文件、`Contents/Helpers/sysemble-vm`；每个都带 `--options runtime --timestamp` 与 Developer ID，helper 额外带 virtualization entitlement。
   - 最后签 `Sysemble.app` 本身（同样 hardened runtime + timestamp）；**不把 `--deep` 当签名手段**（只用于校验），避免漏签嵌套代码。
2. **校验**：`codesign --verify --deep --strict --verbose=2`、逐个 `codesign -d --entitlements -`（helper 必须有 `com.apple.security.virtualization`）、`spctl -a -vv`。
3. **公证**：`xcrun notarytool submit --wait` → `xcrun stapler staple`；`stapler validate`。
4. **开发模式**：无证书时 ad-hoc 签名（`--sign -`），不公证；文档说明“从源码构建/本机运行”可用，分发给他人会被 Gatekeeper 拦截。E3 已验证 ad-hoc entitlement 可用。
5. **CI 约束**：公证需要 Apple Developer 证书与 App Store Connect API key（GitHub Secrets）；无 secrets 时 CI 只做 ad-hoc 构建 + 静态检查，发布流水线单独跑。
6. **完整性**：app 内清单固定镜像 sha256；不默认运行时下载；将来若做在线更新，必须签名清单 + TLS + 版本回滚。

## 7. 兼容性与稳定性

| 场景 | 行为 |
|---|---|
| macOS 13/14/15/26 arm64 | 目标支持；13/14 未实测（helper 部署目标 13，`isSupported` 仅 14+ 查询），发布前补测 |
| Intel Mac | 不启动 arm64 VM；`kind` 回落 `container`（有 Docker 时）或 `none` + 原因 |
| Windows / WSL2 | 不在本 ADR 的 L1 范围；后续复用同一引擎镜像，WSL2 作为 Linux 宿主，不打包 VZ |
| Linux | native（root）或容器后端；不打包 VM 镜像 |
| MDM/SIP 拒绝 entitlement | `probe.entitled=false`；**安装前与每次启动构建前**都重新 probe，给出签名/策略说明，不崩溃 |
| 无 Docker | L1 不再需要；x86_64 目标见 §8 |
| 磁盘不足 | 安装前预检 **10 GiB**；构建前由 helper 报可读错误（克隆盘 1.5 GiB + 产物 0.25 GiB） |
| 重复构建 | 每次 APFS clone 基础盘并清理 `.sysemble-vm/*`；**现状（P1-e3/e4）克隆盘保留在 out**；E5 改为构建后默认删除、`--keep-disk` 仅供调试 |
| 取消/崩溃 | SIGTERM → helper stop VM；崩溃后克隆盘遗留在 out，可删除或由 UI“清理构建产物”回收；不残留 helper 进程 |
| helper ABI 不兼容 | probe 的 `arch/supported` 不匹配时 vm 不可用并提示重装 app；不尝试启动 |
| 首启中断 | `.tmp-*` 目录在下次启动回收；已安装版本不受影响；可重试 |
| 路径 | repo/out 支持空格/中文；宿主路径不进 guest |
| 升级 | app 包内镜像版本固定；新版本安装成功后保留 1 个旧版本回滚，其余 GC；`min_app_version` 不满足时拒绝安装 |
| 单实例 | app 内串行化 VM 构建（VZ 每 VM 4 GiB；避免并行爆内存） |

## 8. L2：把 x86_64 目标也封装进来（关键差距）

当前 arm64 guest 只构建 arm64 rootfs；产品主目标是 x86_64 的 qcow2/ISO（P0–P1 的 GRUB/OVMF 管线）。要真正做到“一个软件包含全部环境”，需要下列之一：

### 方案 A（已通过 spike，选定）：引擎镜像跑在 VM 内（engine-in-VM）
- arm64 guest 内装 podman（rootless/rootful）+ binfmt；把 **现有 amd64 `sysemble-engine:0.1.0` 镜像**预装进 VM 盘。
- 用 Rosetta for Linux（VZ `VZLinuxRosettaDirectoryShare`，macOS 13+）翻译 x86_64 进程；guest 内 `podman run --platform linux/amd64` 跑同一套 builder，**不改 `builders/**`**。
- 优点：复用 P1-e2 已验证的完整 x86_64 管线与镜像清单；宿主零 Docker；boot-check 可在 guest 内用 arm64 的 qemu-system-x86（TCG）跑。
- 风险：Rosetta 是宿主组件（不可随 app 分发），需在 notInstalled/MDM 时降级；VM 盘 + 镜像使包体增加约 300–500 MiB（压缩后）。
- 包体修正：L2 app ~600–700 MiB；安装后 VM 盘 ~8–9 GiB；构建临时 2–3 GiB。

**Spike 结果（2026-11-26，macOS 26.6.2 arm64）**：
- 宿主 `VZLinuxRosettaDirectoryShare.availability = installed`；guest 挂载 tag `rosetta` 后 `update-binfmts` 注册成功，`/proc/sys/fs/binfmt_misc/rosetta` 为 enabled。
- 静态 amd64 busybox 在 guest 内执行 `uname -m` → `x86_64`；同一 busybox 的 arm64/amd64 实现对照开销 **1.44×**（184 ms vs 265 ms），远低于 10×。
- 与 arm64 coreutils 的“跨实现”对照为 10.63×，差异主要来自 coreutils 的 ARMv8 SHA 指令，不代表 Rosetta 开销。
- 结论：**走方案 A**；E6b 需验证动态 amd64、podman 容器内 binfmt（F flag）、真实 x86_64 构建与 ISA 差异。

**E6b 结果（2026-11-26，同机）**：
- guest 内 **podman 5.4.2 + overlay** 可用；`docker save` 的 **114 MiB OCI archive** 直接 `podman load`（2.5 s）。
- 用现有 amd64 引擎镜像执行 `container-entry.sh`，真实构建 minimal **x86_64**：**rc=0**；宿主 wall **435 s**（guest active 167 s，后台调度/swap 拉长了 wall），guest 内 mmdebstrap 151 s。
- `artifact.json`：`arch=x86_64`、`boot.mode=uefi`、14 packages；`disk.qcow2` 420,937,728 B，**sha256 与 artifact 一致**；`disk.img` 4 GiB GPT。
- 6 GiB 盘峰值 2.80 GiB（余量薄）→ **L2 镜像用 12 GiB**；`--network host` 必需（默认 bridge 缺 `nft`）；未做 boot-check。
- 结论：**engine-in-VM 可行**。L2 持久化：VM 镜像 v2（podman + binfmt + Rosetta 挂载 + 预装镜像 + 12 GiB），桌面 VM 构建改走 engine-in-VM。

### 方案 B：guest 内交叉构建 x86_64
- 在 arm64 guest 内装 `qemu-user-static`/binfmt + 解包 `grub-efi-amd64-bin` 模块 + 给 builder 加 `--arch amd64`；mmdebstrap 用 `--arch=amd64`。
- 优点：不引入 podman/镜像；包体小。
- 缺点：需要改冻结的 builder 契约、跨架构 GRUB/OVMF 兼容、dpkg 慢（无 Rosetta 时）；风险高于 A。

### 方案 C：继续依赖宿主机 Docker（现状）
- 不是“一体化”，只作为 L1 的 x86_64 兜底；不满足用户目标。

**决策**：L2 走方案 A（engine-in-VM），E6a/E6b 均已实测通过；下一步把 podman/镜像/Rosetta 持久化进 VM 镜像 v2，并接入打包（E5）。

## 9. 实施切片（后续）

| 切片 | 内容 |
|---|---|
| E5a | `engine/vm/bundle/build-bundle.sh`（压缩/清单/sha256）、app 资源布局、首启稀疏解压 + 校验（Rust） |
| E5b | Tauri 打包脚本：helper 复制/签名、app 重签、ad-hoc 开发模式；打包后 `codesign --verify` |
| E5c | 首次启动 UI：进度、错误、磁盘预检；`engine_info` 识别已安装镜像 |
| E5d | 干净 Mac 验收（无 Docker、无仓库）：安装 → 构建 → 产物 sha256 |
| E6a | Rosetta for Linux spike（Debian arm64 guest + amd64 二进制） | **已完成**：guest 内 x86_64 可执行，同实现开销 1.44×（`docs/plan/P1-e6a-workplan.md`） |
| E6b | engine-in-VM：podman + 预装 amd64 镜像 + binfmt；桌面 Build 走该路径 | **spike 已完成**（rc=0，x86_64 qcow2 sha 一致）；持久化+桌面集成=下一步 |
| E6c | 签名/公证流水线（需 Developer ID）与发布清单 | 待 |

## 10. 未决问题

1. ~~Rosetta/Debian 兼容、动态 amd64、podman binfmt~~：E6b 真实构建已通过（rc=0，x86_64 qcow2）。剩余：**boot-check** 尚未在 L2 路径跑；后台 wall 时间受调度/swap 影响（435 s），需用 power assertion 或前台运行复核；12 GiB 镜像的压缩后体积待实测。
2. Tauri 打包后签名顺序与 `Contents/Helpers` 的脚本化（需在本机用 `cargo tauri build` 验证）。
3. 首启解压 6 GiB 稀疏盘的时间（预计 10–30 s）与中断恢复。
4. L2 包体（600–700 MiB）与 notarization 上传时间是否可接受。
5. Intel Mac 是否值得保留容器兜底，还是直接标注“不支持 VM”。
