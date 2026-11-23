# P0-b 工作分解：真实构建 + QEMU 启动验证

> 主线程冻结版。P0-a 已闭环（61 tests、17/17 验收、CI 绿）。
> 本阶段目标：把 `plan` 变成**可启动的磁盘镜像**，并在 QEMU 里证明它真的能起来。

- 日期：2026-11-23
- 基线提交：`10729db`
- 关键约束：本机是 macOS arm64，没有 Linux/root、mmdebstrap、qemu、docker daemon。
  **真实构建与启动的唯一验收环境是 GitHub Actions（ubuntu-latest）**；本地只做 dry-run、静态检查、离线断言测试。

---

## 1. 范围

| 做 | 不做（留给 P0-c） |
|---|---|
| `mmdebstrap` 真实 rootfs | 分区表 / GRUB / UEFI 引导 |
| `mkfs.ext4 -d` 生成磁盘镜像 | 安装器（Calamares） |
| `qemu-img` 转 qcow2 + artifact manifest | 桌面、Windows VM、开发环境 |
| 直接内核启动（`-kernel/-initrd`） | 安全启动 / dm-verity |
| 串口断言：kernel / systemd / login | 图形界面断言 |
| CI `boot-smoke` job 作为权威证据 | 跨架构构建 |

**为什么 P0-b 不用 GRUB**：`qemu -kernel/-initrd` 直接启动内核，绕开 bootloader 的分区/安装复杂度，先证明"镜像里的系统能起来"。分区与引导是独立问题，放 P0-c。

## 2. 架构与接口（冻结）

```
build.sh --execute
  plan.json → mmdebstrap rootfs → mkfs.ext4 -d → disk.img → qemu-img → disk.qcow2
                                 → artifact.json

tools/boot-check.sh --artifact artifact.json
  artifact.json → qemu -kernel/-initrd/-drive → boot.log → boot-evidence.json
```

### 2.1 builder 输出

```
<out>/
  rootfs/                 # mmdebstrap 产物
  disk.img                # raw ext4，含 rootfs
  disk.qcow2              # 转换产物
  artifact.json           # 清单
  build.log
```

`artifact.json`（`sysemble/artifact/v1`）：

```json
{
  "apiVersion": "sysemble/artifact/v1",
  "createdAt": "2026-11-23T12:00:00Z",
  "spec": "minimal-debian",
  "base": {"kind": "debian", "release": "trixie", "pin": "2026-11-01"},
  "arch": "x86_64",
  "packages": ["..."],
  "rootfs": {"path": "rootfs", "size_mb": 420},
  "images": [
    {"path": "disk.img", "format": "raw", "size_mb": 3072, "sha256": "..."},
    {"path": "disk.qcow2", "format": "qcow2", "size_mb": 900, "sha256": "..."}
  ],
  "boot": {
    "kernel": "rootfs/boot/vmlinuz-6.12.x-amd64",
    "initrd": "rootfs/boot/initrd.img-6.12.x-amd64",
    "cmdline": "console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target"
  },
  "builder": {"name": "build.sh", "version": "0.1.0"}
}
```

### 2.2 boot-check 接口

```
tools/boot-check.sh --artifact <artifact.json> [--timeout 300] [--json]
                    [--log-from <file>] [--qemu <binary>]
```

- `--log-from`：离线模式，直接对已有日志跑断言（本地可测，不需要 qemu）。
- 正常模式：起 qemu，串口日志写到 `<artifact 所在目录>/boot.log`，证据写 `boot-evidence.json`。
- 断言（全部 required）：
  1. `boot.kernel`：日志含 `Linux version`
  2. `boot.systemd`：日志含 `systemd[1]` 或 `Reached target`
  3. `boot.login`：日志含 `login:`（serial getty 起来）
- 退出码：0 全过；1 断言失败；2 用法/文件错误；3 qemu 不可用；4 超时。

### 2.3 CI 契约

`.github/workflows/ci.yml` 新增 `boot-smoke` job（ubuntu-latest）：

```
apt-get install mmdebstrap qemu-system-x86 qemu-utils e2fsprogs
cargo run -p sysemble-cli -- plan examples/minimal-debian.yaml > plan.json
sudo -E bash builders/debian/build.sh --plan plan.json --out /tmp/out --execute
bash tools/boot-check.sh --artifact /tmp/out/artifact.json --timeout 300
```

- 该 job 是 P0-b 的**权威验收**；本地通过不算数。
- 上传 `boot.log` / `boot-evidence.json` / `artifact.json` 为 artifact。

## 3. 工作分解

| ID | 任务 | 产出 | 负责 | 依赖 |
|---|---|---|---|---|
| W1 | builder 真实执行路径 + artifact manifest + 静态测试 | `builders/debian/**` | SA-builder | 无 |
| W2 | `tools/boot-check.sh` + 离线断言测试 + 文档 | `tools/boot-check.sh`、`tools/tests/**` | SA-boot | artifact 契约 |
| W3 | CI `boot-smoke` job + 集成 | `.github/workflows/ci.yml` | 主线程 | W1/W2 |
| W4 | 独立验收：静态 + CI 证据复核 | `docs/acceptance/P0-b.md` | SA-verify | W1–W3 |
| W5 | 总验、提交、推送、盯 CI | — | 主线程 | 全部 |

## 4. 职责矩阵

| 目录 | 写入者 |
|---|---|
| `builders/debian/**` | SA-builder |
| `tools/boot-check.sh`、`tools/tests/**` | SA-boot |
| `.github/workflows/**`、`docs/plan/**` | 主线程 |
| `docs/acceptance/**`、`tests/acceptance/**` | SA-verify |
| `crates/**`、`spec/**`、`examples/**` | 冻结（主线程已加 `examples/minimal-debian.yaml`） |

## 5. 验收标准

| # | 检查 | 通过条件 |
|---|---|---|
| B1 | `build.sh --dry-run` 回归 | P0-a 行为不变，PASS |
| B2 | builder 静态检查 | `bash -n`、无 qemu/mmdebstrap 时明确报错 |
| B3 | artifact 形状 | `jq` 校验必需字段；kernel/initrd 路径存在 |
| B4 | boot-check 离线断言 | 3 条 canned 日志全过；缺 login 的日志 FAIL |
| B5 | boot-check 无 qemu | exit 3，信息可读 |
| B6 | **CI boot-smoke** | job 绿，日志含 `Linux version` + `login:` |
| B7 | 回归 | `cargo test --workspace`、`tools/validate.py`、P0-a 17 项验收仍全过 |
| B8 | 工作区 | 变更仅落在允许目录 |

## 6. 已知风险

1. GitHub runner 无 KVM，qemu 走 TCG，启动可能 1–3 分钟；超时设 300s。
2. Debian trixie 的 serial getty 依赖 `console=ttyS0` 生成器；若 `login:` 不出现，builder 需加 `systemctl enable serial-getty@ttyS0` hook，或把 `boot.login` 降级为 warning（由 SA-verify 判定）。
3. `mkfs.ext4 -d` 需要 e2fsprogs ≥ 1.47；Ubuntu 24.04 runner 满足。
4. `mmdebstrap` 在 CI 用 root；本地 macOS 永远走拒绝路径，属预期。
5. Docker 引擎仍不在 P0-b 验收范围。
