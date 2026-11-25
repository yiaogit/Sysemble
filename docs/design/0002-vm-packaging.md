# ADR 0002：macOS 一体化封装设计（引擎 VM + 应用）

- 状态：**设计（P1-e4c）**，实现拆到 P1-e5/P1-e6
- 日期：2026-11-25
- 关联：`docs/plan/P1-e3-workplan.md`（VM 原型）、`docs/plan/P1-e4-workplan.md`（桌面接入）、`docs/design/0001-sysemble-design.md`
- 目标：用户只安装一个 Sysemble `.app`，**不要求预装 Docker/命令行工具/手工下载镜像**，即可在 Apple Silicon Mac 上完成构建。

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
6. **升级按版本目录并存**：新版本安装成功后再 GC 旧版本；清单 schema 版本化，app 与镜像版本解耦。
7. **兼容性先保 macOS 13+ arm64**，Intel 不支持 VZ VM（容器后端兜底）；13/14 未实测，发布前补测。

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
| **app 包（L1）** | **约 280–300 MiB** |
| 首启安装后 | ~560 MiB（稀疏盘）+ 清单 |
| 单次构建临时 | 克隆盘实际 ~0.8–1.5 GiB + 产物 tar 0.25 GiB |
| 建议最小空闲 | **8 GiB**（安装 + 一次构建 + 安全余量） |

结论：L1 包体可接受（< 300 MiB，远低于原 450 MiB 预算）。

## 5. 首启安装（E5 实现）

状态机：`absent → verifying → installing → verifying_image → ready`（失败可重试，不破坏已安装版本）。

1. **预检**：`statfs` 可用空间 ≥ 8 GiB；目标目录可写；macOS arm64；helper 可执行且 entitlement 有效（`probe --json`）。
2. **校验包内文件**：按 `sysemble-vm.json` 重算 `disk.img.zst` + `vmlinuz` + `initrd.img` 的 sha256；不匹配即失败（安装包损坏）。
3. **稀疏解压**：流式 zstd 解码，1 MiB 块；整块为 0 时 `seek` 前进，否则 `write`；避免把 6 GiB 全部分配。写 `<dir>/disk.img.tmp`，`fsync`，关闭后**重算解压后 sha256**（读 6 GiB 逻辑，稀疏读取约数秒）并与清单比对，最后 `rename` 为 `disk.img`。
4. **写安装标记**：`installed.json`（`version`、`disk_sha256`、`disk_size_bytes`、`installed_at`、`app_version`）。原子写。
5. **清理**：删除 `.tmp`；失败时只删本次临时文件，不碰已存在的旧版本目录。
6. **IPC/UI**：新增 `engine_install` 命令 + 进度事件（`verifying/installing/ready/error`）；安装完成前 Build 按钮禁用并显示进度；失败给可读原因（空间、校验、MDM、I/O）。

**解压实现**：Rust `zstd` crate（流式 Decoder），不依赖系统二进制；稀疏写入用 `std::io::Seek`。若目标卷不是 APFS（极少），退化为普通写入并要求 8 GiB 以上空间。

## 6. 签名、公证与分发

1. **构建期**
   - `engine/vm/image/build-image.sh` 产出版本化镜像；`engine/vm/bundle/build-bundle.sh` 压缩、写清单、做 sha256。
   - helper 用 `swift build -c release` 构建；`codesign --force --options runtime --timestamp --entitlements sysemble-vm.entitlements --sign "Developer ID Application: …"`。
   - 打包脚本复制 helper 到 `Contents/Helpers/`，执行 `codesign --force --options runtime --timestamp --sign "Developer ID Application: …" Sysemble.app`（inside-out，先 helper 后 app）。
2. **校验**：`codesign --verify --deep --strict --verbose=2`、`codesign -d --entitlements -` 确认 helper 有 virtualization、`spctl -a -vv`。
3. **公证**：`xcrun notarytool submit --wait` → `xcrun stapler staple`；`stapler validate`。
4. **开发模式**：无证书时 ad-hoc 签名（`--sign -`），不公证；文档说明“从源码构建/本机运行”可用，分发给他人会被 Gatekeeper 拦截。E3 已验证 ad-hoc entitlement 可用。
5. **CI 约束**：公证需要 Apple Developer 证书与 App Store Connect API key（GitHub Secrets）；无 secrets 时 CI 只做 ad-hoc 构建 + 静态检查，发布流水线单独跑。
6. **完整性**：app 内清单固定镜像 sha256；不默认运行时下载；将来若做在线更新，必须签名清单 + TLS + 版本回滚。

## 7. 兼容性与稳定性

| 场景 | 行为 |
|---|---|
| macOS 13/14/15/26 arm64 | 目标支持；13/14 未实测（helper 部署目标 13，`isSupported` 仅 14+ 查询），发布前补测 |
| Intel Mac | 不启动 arm64 VM；`kind` 回落 `container`（有 Docker 时）或 `none` + 原因 |
| MDM/SIP 拒绝 entitlement | `probe.entitled=false`；安装/构建给出签名与策略说明，不崩溃 |
| 无 Docker | L1 不再需要；x86_64 目标见 §8 |
| 磁盘不足 | 安装前预检 8 GiB；构建前由 helper 报可读错误 |
| 重复构建 | 每次 APFS clone 基础盘；`.sysemble-vm/{ready,done,job.sh,log}` 清理；构建后删除克隆（`--keep-disk` 仅调试） |
| 取消/崩溃 | SIGTERM → helper stop VM；崩溃后克隆盘遗留在 out，可在 UI“清理构建产物”删除；不残留 helper 进程 |
| 路径 | repo/out 支持空格/中文；宿主路径不进 guest |
| 升级 | 新版本目录并存；成功后 GC 旧版；保留最近 1 个回滚 |
| 单实例 | app 内串行化 VM 构建（VZ 每 VM 4 GiB；避免并行爆内存） |

## 8. L2：把 x86_64 目标也封装进来（关键差距）

当前 arm64 guest 只构建 arm64 rootfs；产品主目标是 x86_64 的 qcow2/ISO（P0–P1 的 GRUB/OVMF 管线）。要真正做到“一个软件包含全部环境”，需要下列之一：

### 方案 A（推荐先验证）：引擎镜像跑在 VM 内（engine-in-VM）
- arm64 guest 内装 podman（rootless/rootful）+ binfmt；把 **现有 amd64 `sysemble-engine:0.1.0` 镜像**预装进 VM 盘。
- 用 Rosetta for Linux（VZ `VZLinuxRosettaDirectoryShare`，macOS 13+）翻译 x86_64 进程；guest 内 `podman run --platform linux/amd64` 跑同一套 builder，**不改 `builders/**`**。
- 优点：复用 P1-e2 已验证的完整 x86_64 管线与镜像清单；宿主零 Docker；boot-check 可在 guest 内用 arm64 的 qemu-system-x86（TCG）跑。
- 风险：Rosetta for Linux 对 Debian guest 的支持需先做 spike；无 Rosetta 时 qemu-user 慢 5–10 倍；VM 盘 + 镜像使包体增加约 300–500 MiB（压缩后）。
- 包体修正：L2 app ~600–700 MiB；安装后 VM 盘 ~8–9 GiB；构建临时 2–3 GiB。

### 方案 B：guest 内交叉构建 x86_64
- 在 arm64 guest 内装 `qemu-user-static`/binfmt + 解包 `grub-efi-amd64-bin` 模块 + 给 builder 加 `--arch amd64`；mmdebstrap 用 `--arch=amd64`。
- 优点：不引入 podman/镜像；包体小。
- 缺点：需要改冻结的 builder 契约、跨架构 GRUB/OVMF 兼容、dpkg 慢（无 Rosetta 时）；风险高于 A。

### 方案 C：继续依赖宿主机 Docker（现状）
- 不是“一体化”，只作为 L1 的 x86_64 兜底；不满足用户目标。

**建议**：L1 先交付（arm64，零外部依赖）；并行做 Rosetta for Linux on Debian arm64 的 spike（1–2 天）。验证通过走 A；否则退 B，并把 L1 的 x86_64 明确标注为“需 Docker”。

## 9. 实施切片（后续）

| 切片 | 内容 |
|---|---|
| E5a | `engine/vm/bundle/build-bundle.sh`（压缩/清单/sha256）、app 资源布局、首启稀疏解压 + 校验（Rust） |
| E5b | Tauri 打包脚本：helper 复制/签名、app 重签、ad-hoc 开发模式；打包后 `codesign --verify` |
| E5c | 首次启动 UI：进度、错误、磁盘预检；`engine_info` 识别已安装镜像 |
| E5d | 干净 Mac 验收（无 Docker、无仓库）：安装 → 构建 → 产物 sha256 |
| E6a | Rosetta for Linux spike（Debian arm64 guest + amd64 二进制） |
| E6b | engine-in-VM：podman + 预装 amd64 镜像 + binfmt；桌面 Build 走该路径 |
| E6c | 签名/公证流水线（需 Developer ID）与发布清单 |

## 10. 未决问题

1. Rosetta for Linux 在 Debian trixie arm64 guest 的可用性/许可（需 spike；Apple 官方主要支持 Ubuntu）。
2. Tauri 打包后签名顺序与 `Contents/Helpers` 的脚本化（需在本机用 `cargo tauri build` 验证）。
3. 首启解压 6 GiB 稀疏盘的时间（预计 10–30 s）与中断恢复。
4. L2 包体（600–700 MiB）与 notarization 上传时间是否可接受。
5. Intel Mac 是否值得保留容器兜底，还是直接标注“不支持 VM”。
