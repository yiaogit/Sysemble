# P1-e3 工作分解：macOS 引擎 VM 原型（Virtualization.framework）

> P1-e2 用容器后端解决了 macOS/Windows 的“今天能构建”。P1-e3 做**原型**：在 Apple Silicon 上用 Virtualization.framework 启动一台 Linux 引擎 VM，通过 virtiofs 共享仓库与 out，在 guest 内执行真实的最小构建，把日志与产物带回宿主。原型先独立于 Tauri 壳，验证通过后再做桌面集成（P1-e4）。

- 日期：2026-11-24
- 基线提交：`0e5550d`（P1-e2 验收）
- 决策依据：见 §0；用户将在另一台 Apple Silicon Mac 上独立验证

## 0. 决策与实测

| 事实 | 证据 |
|---|---|
| VZ 配置（virtio-blk + 2×virtiofs + virtio console serial + NAT + entropy）可通过 `validate()` | 本机 Swift 6.4 spike 编译并输出 `validate ok` |
| 未签名进程被拒；ad-hoc 签名 + `com.apple.security.virtualization` 可用 | `VZVirtualMachineConfiguration.validate()` 实测错误切换；`codesign --force --sign - --entitlements ent.plist` 后通过 |
| Docker Desktop arm64 原生运行 | `docker run --platform linux/arm64 debian:trixie uname -m` → `aarch64`；mmdebstrap 1.5.7 / mke2fs 1.47.2 可用 |
| bind mount 保持稀疏文件 | 容器内 `truncate -s 4G` + 写 8 MiB → 宿主 `du` 8 MiB、逻辑 4 GiB |
| CI 不能启 VZ | GitHub macOS runner 本身是 VZ guest，不支持嵌套虚拟化（官方限制）；`ubuntu-24.04-arm` 是公开仓库可用的原生 arm64 Linux runner |
| 大小写不敏感 rootfs 仍会踩坑 | P1-e2 实测 APFS bind mount ELOOP；本切片沿用“guest 内 `/out` 构建、只导出顶层产物” |

决策：

1. **guest 架构固定 arm64**。VZ 在 Apple Silicon 上只能跑 arm64 guest。当前 builder 的 GPT/GRUB/OVMF 管线是 x86_64（P0–P1），因此原型**不承诺 x86_64 可启动镜像**；它证明 VM 生命周期、共享、以及在 guest 内跑真实 Debian 构建的能力。完整 x86_64 目标仍由 P1-e2 容器后端承担。
2. **直启内核 + ext4 根盘**：`VZLinuxBootLoader(kernel/initrd)` + raw ext4 `disk.img`（6 GiB 稀疏，宿主用 APFS clone 派生临时盘）。
3. **virtiofs 双共享**：repo 只读挂 `/work`，out 读写挂 `/export`；guest 在自身 `/out`（ext4）构建，只把顶层产物复制到 `/export`（复用 P1-e2 的教训）。
4. **文件式 job 协议，不做 SSH/agent 服务**：guest systemd 服务写 `ready`，轮询宿主投递的 `job.sh`，执行后写 `log` 与 `done`（退出码）。宿主 helper 只读这四个文件。
5. **helper 用 SwiftPM + 单可执行**，构建脚本 ad-hoc 签名并带 entitlement；先 CLI，后桌面集成。
6. **CI 只编译/probe**；真实启动由本机 + 用户另一台 Mac 验证。

## 1. 架构

```
macOS host
  engine/vm/macos/build.sh ──► swift build -c release + codesign --entitlements
  sysemble-vm run --image-dir engine/vm/image/build --repo . --out out/vm --plan out/vm/plan.json
        │  (clone disk.img → out/vm/vm-disk.img, prepare .sysemble-vm/)
        ▼
  VZVirtualMachine
    kernel vmlinuz + initrd.img, raw ext4 disk, virtio-net NAT
    virtiofs tag sysemble-repo → guest /work (ro)
    virtiofs tag sysemble-out  → guest /export (rw)
    virtio console → out/vm/vm-serial.log
        │
        ▼
  guest (Debian trixie arm64, systemd)
    sysemble-vm-agent.service
      mount /work /export → touch /export/.sysemble-vm/ready
      wait job.sh → bash job.sh > /export/.sysemble-vm/log 2>&1
      echo $? > /export/.sysemble-vm/done
    job.sh → bash /work/engine/vm/guest/minimal-build.sh \
                   --plan /export/plan.json --out /out --export /export
        │
        ▼
  guest /out (ext4): build.sh --dry-run + mmdebstrap 最小 arm64 rootfs
  /export: rootfs.tar.gz + artifact-vm.json + logs
        │
  host: wait ready/done, read log, stop VM, return exit code
```

## 2. 冻结接口

### 2.1 VM 镜像目录（`engine/vm/image/build/`，gitignore）

```
disk.img          raw ext4，6 GiB 稀疏，label sysemble-engine，guest root
vmlinuz           guest 内核（arm64）
initrd.img        guest initramfs
sysemble-vm.json  清单
```

清单字段（冻结）：

```json
{
  "schema": 1,
  "name": "sysemble-vm",
  "version": "0.1.0",
  "arch": "arm64",
  "kernel": {"path": "vmlinuz", "release": "6.12.x-arm64", "sha256": "..."},
  "initrd": {"path": "initrd.img", "sha256": "..."},
  "disk": {"path": "disk.img", "sha256": "...", "size_bytes": 6442450944},
  "guest": {"agent_unit": "sysemble-vm-agent.service", "minimal_build": "engine/vm/guest/minimal-build.sh"},
  "packages": 123,
  "mmdebstrap": "1.5.7",
  "created": "2026-11-24T00:00:00Z"
}
```

`build-image.sh`：`--ref`（默认 `sysemble-vm:0.1.0`，仅作清单名）、`--out`、`--engine auto|docker|native`、`--verify <dir>`、`--no-cache`、`--help`。macOS 走 docker（arm64 原生）；Linux arm64 CI 自动选 native 或 docker。`--verify` 校验三个 sha256 与清单字段。

### 2.2 guest 路径与 job 协议

| 宿主 | guest | 权限 |
|---|---|---|
| `<repo>` | `/work` | ro（virtiofs tag `sysemble-repo`） |
| `<out>` | `/export` | rw（virtiofs tag `sysemble-out`） |
| — | `/out` | guest ext4 构建目录 |

- 宿主启动前创建 `<out>/.sysemble-vm/`，写入 `<out>/plan.json`。
- guest 就绪：`<out>/.sysemble-vm/ready`（内容含时间戳）。
- 宿主投递：先写 `job.sh.tmp` 再 rename 为 `<out>/.sysemble-vm/job.sh`；内容固定为
  `bash /work/engine/vm/guest/minimal-build.sh --plan /export/plan.json --out /out --export /export`。
- guest 执行：`log` 全量输出；`done` 单行退出码；宿主读完后停 VM。
- 超时：ready 默认 180s、job 默认 1800s；超时停 VM 并返回非 0，保留 serial log 与已产生的文件。

### 2.3 helper CLI

```
sysemble-vm probe [--json]
sysemble-vm run --image-dir <dir> --repo <dir> --out <dir> --plan <plan.json>
                [--cpus 4] [--memory-mb 4096] [--ready-timeout 180] [--timeout 1800]
                [--no-clone] [--json]
```

- `probe`：输出 `supported`、`entitled`、`arch`、`macos`、`cpus`；无 entitlement 时 `entitled=false` 且 reason 可读，退出码 0（这是探测，不是失败）。
- `run`：克隆 `disk.img → <out>/vm-disk.img`（APFS clone，`--no-clone` 直接用原盘）、启动 VM、执行协议、打印 `log` 尾部（`--json` 时输出结构化结果）、停止 VM；退出码 = guest 退出码（基础错误 2/3/4 区分用法/镜像/启动）。
- 中断/超时：`stop()` 等待 VM 停止后退出，不遗留进程。

### 2.4 guest 最小构建（`engine/vm/guest/minimal-build.sh`）

1. `bash /work/builders/debian/build.sh --plan <plan> --out /out/dry --dry-run`（证明同一份 builder 在 guest 内可执行）。
2. `mmdebstrap --variant=minbase --include=... trixie /out/rootfs`（arm64 原生）。
3. `tar -C /out/rootfs -czf /export/rootfs.tar.gz .` + `sha256sum`。
4. 写 `/export/artifact-vm.json`：`arch=arm64`、rootfs 文件数/大小、tar sha256、mmdebstrap 版本、`builder_dry_run=pass`。
5. 失败即非 0，日志由 agent 捕获。

## 3. 切片与写入边界

| 切片 | 内容 | 写入边界 | 状态 |
|---|---|---|---|
| **E3a** VM 镜像 + guest | build-image.sh、Docker/native in-container 构建、guest agent/unit/network/minimal-build、静态+在线测试、CI 片段 | `engine/vm/image/**`、`engine/vm/guest/**` | 派工 |
| **E3b** Swift helper | SwiftPM 可执行、VZ 配置、virtiofs/串口/job 协议、build.sh + entitlement、probe/tests、CI 片段 | `engine/vm/macos/**` | 派工 |
| **E3c** 集成 | CI job、.gitignore、A10、README/roadmap、提交推送 | 主线程 | 待 |
| **E3d** 独立验收 | 下载镜像清单/CI 日志、本机 E2E 复跑、用户设备清单 | `docs/acceptance/**` | 待 |

## 4. 验收矩阵

| # | 检查 | 通过条件 | 证据 |
|---|---|---|---|
| V1 | 镜像可构建 | macOS docker arm64 与 CI arm64 均成功；`--verify` 通过 | 本机 + CI |
| V2 | 清单一致 | kernel/initrd/disk sha256 与文件一致；arch=arm64；kernel release 非空 | `image_test.sh --docker` |
| V3 | helper 可编译/签名 | `swift build` 成功；`codesign -d --entitlements` 含 virtualization；`probe` 输出 `supported/entitled` | CI `vm-helper` + 本机 |
| V4 | VM 能启动 | 本机 `sysemble-vm run` 等到 `ready`；serial log 出现内核启动行 | 本机 E2E |
| V5 | 共享可用 | guest 读到 `/work/builders/debian/build.sh`；out 共享双向可见 | guest log |
| V6 | guest 真实构建 | `minimal-build.sh` 退出 0；`artifact-vm.json` 的 `builder_dry_run=pass`；rootfs.tar.gz + sha256 非空 | 本机 E2E |
| V7 | 宿主导出 | 宿主持有 `rootfs.tar.gz`、`artifact-vm.json`、`.sysemble-vm/log`、`done`；sha256 可重算 | 本机 E2E |
| V8 | 失败可读 | 缺镜像/缺 entitlement/超时分别给出可读错误与非 0 退出；不遗留 VM | 单测/手动 |
| V9 | 回归 | 根 61、桌面 39、acceptance 17/17、既有 9 个 CI job 全绿 | 本机 + CI |
| V10 | 独立验收 + 用户设备 | 验收代理写 `docs/acceptance/P1-e3.md`；用户在另一台 Apple Silicon Mac 跑同一命令并回报 | 报告 |

## 5. CI

- `vm-image`（`ubuntu-24.04-arm`，45 min）：构建 arm64 VM 镜像 → `image_test.sh --docker` → 上传清单/kernel/initrd（不上传 6 GiB 盘）。
- `vm-helper`（`macos-15`，30 min）：`engine/vm/macos/build.sh` → `probe --json` → shell 测试；**不启动 VM**（嵌套虚拟化不可用）。
- 现有 9 个 job 不动。

## 6. 风险

1. **VZ 不能进 CI**：真实启动只在本机与用户设备；CI 只证明编译/签名/探测。报告必须区分。
2. **entitlement**：ad-hoc 签名在开发机可用，但 macOS 版本/策略差异可能拒绝；`probe` 必须把原因写清楚。最低目标 macOS 13（API 用 macOS 12+，`isSupported` 用可用性判断）。
3. **arm64 guest ≠ x86_64 目标**：原型构建 arm64 rootfs；x86_64 GRUB/UEFI 盘仍走容器后端。不得宣称“macOS 上产出可启动 x86_64 镜像”。
4. **guest 启动细节**：`console=hvc0`、virtio_blk 名 `/dev/vda`、initramfs 需含 virtio/ext4；若失败，用 serial log 迭代。
5. **virtiofs 与 APFS**：repo/out 共享仍大小写不敏感；已用 guest `/out` + 顶层导出规避，但 `.sysemble-vm` 目录里只放 ASCII 文件名。
6. **网络/DNS**：guest NAT + systemd-networkd DHCP；apt 下载失败时 job 失败，需保留日志。
7. **磁盘**：6 GiB 稀疏盘；宿主 clone 失败会退化为完整复制；APFS 可用空间需 >10 GiB。
8. **CI arm64 runner**：`ubuntu-24.04-arm` 仅公开仓库；若 Docker/权限不可用，job 退化为静态测试（记录 BLOCKED，不伪造）。
9. **用户设备版本未知**：若低于 macOS 13 或非 Apple Silicon，原型不可运行；验收需记录实际系统。

## 7. 非目标

- 不做 Tauri 桌面集成、镜像分发/签名、WSL2、x86_64 目标、GUI/显示、vsock/SSH、VM 快照。
- 不改 `builders/debian/**` 的冻结契约；原型只调用。
