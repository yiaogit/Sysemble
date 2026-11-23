# P0-d3 工作分解：无人值守安装到磁盘

> P0-d2 已闭环：278 MB live ISO 从 UEFI CD 启动，live-boot 挂载 squashfs，CI 通过。
> 本切片：让 live 介质把系统**安装到空白磁盘**，再从安装后的磁盘启动。

- 日期：2026-11-23
- 基线提交：`a083321`
- **重要取舍**：先做**无头安装后端**（`sysemble-install`），Calamares GUI 留到 P0-d3b。
  原因：Calamares 是图形安装器，CI 里无头驱动需要 Xvfb + 坐标点击，脆弱且不可重复；
  先把"分区 → 复制根 → 装 GRUB → 重启进系统"这条真实链路验证掉，UI 只是壳。

---

## 1. 范围

| 做 | 不做 |
|---|---|
| live ISO 内置 `sysemble-install` + systemd unit | Calamares GUI |
| 自动安装到 `/dev/vda`（GPT + ESP + ext4） | 用户交互 / 分区向导 |
| 安装完成 marker + poweroff | 加密 / LUKS |
| 从安装后的磁盘 UEFI 启动并断言 | 桌面安装（P0-d4） |
| `tools/install-check.sh` 两阶段验证 | 持久化 / 双系统 |

## 2. 安装器契约（冻结）

### 2.1 live 侧

- 内核 cmdline 追加：`sysemble.install=/dev/vda`
- systemd unit `sysemble-install.service`：
  ```
  [Unit]
  Description=Sysemble unattended installer
  ConditionKernelCommandLine=sysemble.install
  After=multi-user.target
  [Service]
  Type=oneshot
  ExecStart=/usr/local/sbin/sysemble-install
  TimeoutStartSec=1800
  StandardOutput=journal+console
  [Install]
  WantedBy=multi-user.target
  ```
- 脚本 `/usr/local/sbin/sysemble-install`：
  1. 从 `/proc/cmdline` 读 `sysemble.install=`，默认 `/dev/vda`；校验是块设备且不是 live 介质。
  2. `sgdisk -Z`；`-n 1:2048:+512M -t 1:ef00`；`-n 2:0:0 -t 2:8300`。
  3. `mkfs.vfat -F 32 -n ESP ${dev}1`；`mkfs.ext4 -F -L SYMBLE ${dev}2`。
  4. mount root `/mnt`；mount ESP `/mnt/boot/efi`。
  5. `rsync -aHAX --exclude={/proc,/sys,/dev,/run,/tmp,/mnt,/media,/live,/lost+found} / /mnt/`
  6. 写 `/mnt/etc/fstab`（ESP + root 的 UUID）。
  7. chroot：`grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=sysemble --removable --no-nvram`；
     写 `/boot/grub/grub.cfg`（`search --fs-uuid` + `linux /boot/vmlinuz-<ver> root=UUID=<uuid> rw console=ttyS0` + initrd）。
  8. 输出 `SYMBLE: install complete` 到 `/dev/ttyS0`，`systemctl poweroff -f`。
- ISO 额外包：`rsync grub-efi-amd64 grub-efi-amd64-bin dosfstools gdisk e2fsprogs`。

### 2.2 artifact

```json
"boot": {
  "mode": "install",
  "iso": "live.iso",
  "install_device": "/dev/vda",
  "cmdline": "boot=live live-media-path=/live console=ttyS0 ... sysemble.install=/dev/vda",
  "memory_mb": 1024
}
```

### 2.3 install-check

```
tools/install-check.sh --artifact <installer.json> [--timeout 1200] [--json]
```

1. 在 `$TMPDIR` 创建 **6 GiB sparse raw** 磁盘（`truncate -s 6G`）。
2. QEMU：q35 + OVMF pflash + `-cdrom <iso>` + `-drive file=<disk>,format=raw,if=virtio`；串口日志 `install.log`。
3. 等待 `SYMBLE: install complete`（超时 → exit 4）；kill QEMU。
4. 生成临时 artifact：`{"boot":{"mode":"uefi","disk":"<disk>","memory_mb":1024}}`，调用 `tools/boot-check.sh` 验证安装后的磁盘。
5. 合并证据 `install-evidence.json`：
   ```json
   {"result":"pass|fail|timeout","phases":{"install":{"result":"pass","marker":"SYMBLE: install complete"},"boot":{"result":"pass","assertions":[...]}}}
   ```
6. 退出码：0 两阶段都过；1 安装后启动失败；2 用法/artifact；3 qemu/固件不可用；4 安装超时。

## 3. CI

新增 `install-smoke`（40 min）：

```
apt: 既有 + xorriso squashfs-tools
plan examples/minimal-debian-live.yaml
build.sh --plan plan.json --out out --execute --installer
chown
tools/install-check.sh --artifact out/artifact.json --timeout 1200 --json
upload: boot-evidence-install
```

## 4. 工作分解

| ID | 任务 | 产出 | 负责 |
|---|---|---|---|
| W1 | 安装器脚本/unit/包 + `--installer` ISO + artifact | `builders/debian/**` | SA-builder6 |
| W2 | `install-check.sh` 两阶段 + 测试 | `tools/install-check.sh`、`tools/tests/**` | SA-install |
| W3 | CI job | `.github/**` | 主线程 |
| W4 | 独立验收 | `docs/acceptance/P0-d3.md` | SA-verify6 |

## 5. 验收

| # | 检查 | 通过条件 |
|---|---|---|
| F1 | 回归 | P0-a…d2 全过 |
| F2 | installer artifact | mode=install、iso、install_device、cmdline 含 `sysemble.install=/dev/vda` |
| F3 | 脚本/unit 静态 | 分区/挂载/rsync/grub/марker/poweroff 命令齐全；测试用伪工具链 |
| F4 | install-check 离线 | 伪 QEMU 两阶段：安装 marker → 调 boot-check → 合并证据；超时/失败路径 |
| F5 | **CI install-smoke** | 安装日志有 marker；安装后磁盘启动 5 条断言全过 |
| F6 | 边界 | 变更只在允许目录 |

## 6. 风险

1. TCG 下 rsync 复制 ~1 GB 到 emulated disk 可能 5–15 分钟；超时 1200s，job 40 min。
2. `grub-install --removable` 在 chroot 内需要 `/proc`/`/sys`/`/dev` 绑定；脚本要 mount --bind。
3. 安装后内核/initramfs 的 virtio 驱动（MODULES=most）需验证。
4. live 环境的 overlay 里 `/boot` 与安装源一致；rsync 排除项要准确。
5. 6 GiB 磁盘 + 1 GB rootfs 足够；CI runner 空间需关注。
6. Calamares 未做，P0-d3b 再接 GUI；文档必须写清。
