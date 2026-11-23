# P0-e1 工作分解：TUI 安装向导

> P0-d3 已有无头安装器；这一步把它重构成**带参数的后端 + 串口 TUI 向导**，同时为 P0-e2 的 Calamares 准备契约。

- 日期：2026-11-23
- 基线提交：`1ba4919`
- 关键目标：交互安装可被 `expect` 在 CI 里驱动，安装后 hostname/用户生效。

---

## 1. 范围

| 做 | 不做 |
|---|---|
| `sysemble-install` 支持 `--disk/--hostname/--user/--password-file/--yes/--tui/--dry-run` | Calamares（P0-e2） |
| 串口 TUI：磁盘、hostname、用户、密码、确认 | 分区方案选择（自动 GPT） |
| 安装后写入 hostname/用户/密码 | LUKS/LVM/双系统 |
| `--installer-tui` ISO + artifact 字段 | 图形界面 |
| `expect` 驱动的 CI 安装冒烟 | 桌面安装（P1 之后） |

## 2. CLI 契约（冻结）

```
sysemble-install [--disk DEV] [--hostname NAME] [--user NAME]
                 [--password-file FILE] [--yes] [--tui] [--dry-run] [--auto]
```

- 无 `--tui`：unattended；未给的参数回退到 `/proc/cmdline` 的 `sysemble.install=`，再回退 `/dev/vda`、`sysemble`、`ops`，密码为空则锁定。
- `--tui`：在 `/dev/ttyS0` 上交互（非 tty 时用 stdin/stdout，便于本地管道测试）。
- `--dry-run`：只打印命令与答案，不分区/不写盘。
- 退出码：0 成功；1 安装失败；2 用法/参数错误；3 非 root / 非 Linux。

### 2.1 提示串（expect 依赖，冻结）

```
SYMBLE-TUI disk [/dev/vda]:
SYMBLE-TUI hostname [sysemble]:
SYMBLE-TUI user [ops]:
SYMBLE-TUI password:
SYMBLE-TUI confirm install to <disk> (yes/no):
```

- 密码用 `stty -echo` 读取，不回声。
- 非法磁盘（非块设备）重新提示。
- `confirm` 非 `yes`/`y` → 退出 2，不安装。
- 成功/失败 marker 沿用：`SYMBLE: install complete` / `SYMBLE: install failed: <reason>`。

### 2.2 安装后配置

- `/etc/hostname`、`/etc/hosts` 写入 hostname。
- `chroot useradd -m -s /bin/bash -G sudo <user>`（已存在则跳过）。
- `echo '<user>:<pass>' | chroot chpasswd`；密码为空则 `passwd -l`。
- 其余（分区、rsync、fstab、GRUB）沿用 P0-d3。

## 3. ISO 与 artifact

- `build.sh --installer-tui`：ISO cmdline 用 `sysemble.install.tui=1`（不用 `/dev/vda`）。
- artifact：
  ```json
  "boot": {
    "mode": "install",
    "iso": "live.iso",
    "install_tui": true,
    "cmdline": "... sysemble.install.tui=1",
    "memory_mb": 1024
  }
  ```
- `--installer`（auto）行为不变，仍用 `sysemble.install=/dev/vda`。

## 4. CI

新增 `tui-install-smoke`（45 min）：

```
apt: 既有 + expect
build --installer-tui
tools/tui-install-check.sh --artifact out/artifact.json --hostname sysemble-tui --timeout 1200 --json
```

`tui-install-check.sh`：
1. 建 6 GiB 磁盘，起 QEMU（ISO + 磁盘）。
2. `expect` 依次回答：回车（默认盘）、`sysemble-tui`、`ops`、`s3cret`、`yes`。
3. 等 `SYMBLE: install complete`（超时 1200s）。
4. 用 `boot-check.sh` 启动安装后的磁盘；断言 login，并检查日志含 `sysemble-tui login:`。
5. 证据 `tui-install-evidence.json`，退出码 0/1/2/3/4 同 install-check。

## 5. 工作分解

| ID | 任务 | 产出 | 负责 |
|---|---|---|---|
| W1 | installer CLI/TUI/用户配置 + `--installer-tui` | `builders/debian/**` | SA-installer-tui |
| W2 | `tools/tui-install-check.sh` + expect + 测试 | `tools/**` | SA-tui-check |
| W3 | CI job | `.github/**` | 主线程 |
| W4 | 独立验收 | `docs/acceptance/P0-e1.md` | SA-verify8 |

## 6. 验收

| # | 检查 | 通过条件 |
|---|---|---|
| H1 | 回归 | P0 全部测试仍过 |
| H2 | CLI | `--dry-run` + 管道输入完成 TUI 流程；非法输入重试；`--yes` 跳过确认 |
| H3 | 安装后配置 | dry-run/伪造 rootfs 断言 hostname/user/password 写入命令 |
| H4 | artifact | install_tui=true、cmdline 含 tui 标记 |
| H5 | **CI tui-install-smoke** | expect 完成安装；安装后磁盘登录提示为 `sysemble-tui login:` |
| H6 | 边界 | 变更只在允许目录 |

## 7. 风险

1. **tty 冲突**：TUI 在 ttyS0 上，serial getty 也在用；脚本需先 `systemctl stop serial-getty@ttyS0` 并直接读写 `/dev/ttyS0`。
2. expect 时序：提示出现前不能发答案；用固定提示串 + `expect` 逐条匹配。
3. 安装后 hostname 生效依赖 `/etc/hostname` + systemd；登录提示应显示新 hostname。
4. 密码含特殊字符时 chpasswd 转义；P0-e1 只测试简单密码。
5. CI 时间：安装 + 两次启动，预算 45 min。
