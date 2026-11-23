# P0-c 工作分解：GPT + GRUB/UEFI 启动

> 主线程冻结版。P0-b 已闭环：rootfs → ext4 → qcow2 → QEMU 直接内核启动，CI 通过。
> 本阶段目标：把"直接 `-kernel` 启动"换成**真实的分区磁盘 + GRUB + UEFI 固件启动**。

- 日期：2026-11-23
- 基线提交：`f1af5a2`
- 切片说明：本阶段只做 **P0-c1（引导层）**。Calamares 安装器、桌面镜像、安装后首启验证留给 P0-d/P0-e。

---

## 1. 范围

| 做 | 不做 |
|---|---|
| GPT 分区表：ESP(512M, FAT32) + root(ext4) | Calamares / 安装器 |
| GRUB EFI（`grub-mkstandalone`，配置内嵌） | 桌面 / KDE |
| OVMF 固件启动（pflash） | 安全启动签名 |
| 5 条断言：firmware / grub / kernel / systemd / login | ISO / squashfs / 持久化 |
| 保留 P0-b 的 `-kernel` 模式（向后兼容） | 跨架构 |

**为什么用 loop-free 方案**：CI 有 root，但 loop 设备在容器化 runner 上不保证可用。用 `mkfs.ext4 -E offset=` + `mkfs.vfat` 镜像 + `mcopy` 写入 ESP，再用 `dd` 拼盘，可以完全不碰 loop device。GRUB 用 `grub-mkstandalone` 把配置嵌进 EFI 二进制，避免 prefix 解析问题。

## 2. 磁盘布局（冻结）

```
disk.img (GPT)
  p1  1MiB   +512MiB  ESP   vfat32  label ESP
  p2  513MiB  rest    root  ext4    label SYMBLE
```

- 总大小：`max(4096, ceil((rootfs_mb*1.6 + 1024)/256)*256)` MB。
- root 文件系统（**必须显式给块数**）：
  ```
  mkfs.ext4 -F -b 4096 -E offset=537919488 -d <rootfs> -L SYMBLE disk.img <blocks>
  blocks = (disk_mb - 513 - 1) * 256        # 4 KiB 块，末尾留 1 MiB 给备份 GPT
  ```
  > 不显式给块数时，mke2fs 会把文件系统一直建到文件末尾，越过 p2 并为备份 GPT 预留的 33 个扇区；ext4 挂载会以 `block count exceeds size of device` 拒绝。实现必须按上面的公式收窄。
- ESP 文件系统：`mkfs.vfat -F 32 -C -n ESP esp.img 524288`（KB），`mcopy -i esp.img -s staging/EFI ::/`，再 `dd seek=1MiB`。
- 分区表：`sgdisk -Z` + `-n 1:2048:+512M -t 1:ef00 -n 2:0:0 -t 2:8300`。

## 3. GRUB（冻结）

- 用 `grub-mkstandalone -O x86_64-efi` 生成 `EFI/BOOT/BOOTX64.EFI`，把 `grub.cfg` 嵌入：
  ```
  grub-mkstandalone -O x86_64-efi -o staging/EFI/BOOT/BOOTX64.EFI \
    --modules="part_gpt part_msdos fat ext2 normal linux search search_fs_uuid configfile serial terminal echo test" \
    "boot/grub/grub.cfg=staging/boot/grub/grub.cfg"
  ```
- `grub.cfg`：
  ```
  set timeout=3
  serial --unit=0 --speed=115200
  terminal_input serial
  terminal_output serial
  menuentry "Sysemble" {
    set root=(hd0,gpt2)
    linux /boot/vmlinuz-<ver> root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=multi-user.target
    initrd /boot/initrd.img-<ver>
  }
  ```
- 依赖：`grub-efi-amd64-bin`、`grub-common`、`mtools`、`dosfstools`、`gdisk`、`ovmf`。

## 4. artifact 契约（v1 兼容扩展）

`artifact.json` 增加：

```json
{
  "boot": {
    "mode": "uefi",
    "disk": "disk.img",
    "kernel": "rootfs/boot/vmlinuz-...",
    "initrd": "rootfs/boot/initrd.img-...",
    "cmdline": "root=/dev/vda2 rw console=ttyS0 ...",
    "grub": {"efi": "esp/EFI/BOOT/BOOTX64.EFI", "config": "grub.cfg"}
  },
  "partitions": [
    {"index": 1, "role": "esp", "size_mb": 512, "fs": "vfat32"},
    {"index": 2, "role": "root", "size_mb": 3584, "fs": "ext4"}
  ]
}
```

- `boot.mode` 缺省为 `"kernel"`（P0-b 行为，向后兼容）。
- `images` 仍含 raw + qcow2；`disk.qcow2` 现在是**带分区表**的镜像。
- `esp/` 是构建中间目录，不必出现在 images 里。

## 5. boot-check 契约（扩展）

```
tools/boot-check.sh --artifact <artifact.json> [--timeout 300] [--json]
                    [--log-from <file>] [--qemu <binary>] [--firmware <OVMF_CODE.fd>]
```

- `mode=uefi`：
  ```
  qemu-system-x86_64 -machine q35 -m 1024 -smp 2 -nographic -no-reboot \
    -drive if=pflash,format=raw,readonly=on,file=<OVMF_CODE_4M.fd> \
    -drive if=pflash,format=raw,file=<临时拷贝的 OVMF_VARS_4M.fd> \
    -drive file=<disk.img>,format=raw,if=virtio
  ```
- 固件自动探测：`/usr/share/OVMF/OVMF_CODE_4M.fd`、`/usr/share/OVMF/OVMF_CODE.fd`、`/usr/share/edk2/ovmf/OVMF_CODE.fd`。
- `mode=kernel`：保持 P0-b 行为。
- 断言（全部 required）：
  1. `boot.firmware`：日志含 `EFI v` 或 `UEFI`
  2. `boot.grub`：日志含 `GRUB` 或 `Booting`
  3. `boot.kernel`：`Linux version`
  4. `boot.systemd`：`systemd[1]` 或 `Reached target`
  5. `boot.login`：`login:`
- 退出码沿用：0/1/2/3/4。缺固件 → 3（与 qemu 不可用同类）。

## 6. 工作分解

| ID | 任务 | 产出 | 负责 | 依赖 |
|---|---|---|---|---|
| W1 | 分区 + ESP + ext4 + GRUB + artifact v1 扩展 | `builders/debian/**` | SA-builder3 | 无 |
| W2 | boot-check UEFI 模式 + 2 条新断言 + 测试 | `tools/boot-check.sh`、`tools/tests/**` | SA-boot2 | artifact 契约 |
| W3 | CI：安装 gdisk/dosfstools/mtools/grub/ovmf，boot-smoke 走 UEFI | `.github/workflows/ci.yml` | 主线程 | W1/W2 |
| W4 | 独立验收 + 报告 | `docs/acceptance/P0-c.md` | SA-verify3 | W1–W3 |
| W5 | 总验、提交、推送、盯 CI | — | 主线程 | 全部 |

## 7. 职责矩阵

| 目录 | 写入者 |
|---|---|
| `builders/debian/**` | SA-builder3 |
| `tools/boot-check.sh`、`tools/tests/**` | SA-boot2 |
| `.github/workflows/**`、`docs/plan/**` | 主线程 |
| `docs/acceptance/**` | SA-verify3 |
| `crates/**`、`spec/**`、`examples/**` | 冻结 |

## 8. 验收标准

| # | 检查 | 通过条件 |
|---|---|---|
| C1 | dry-run 回归 | P0-b 行为不变 |
| C2 | 静态/伪造工具链测试 | 分区命令顺序、GRUB 配置、artifact 字段正确 |
| C3 | artifact v1 | `boot.mode=uefi`、partitions 两项、images raw+qcow2 |
| C4 | boot-check 回归 | kernel 模式 3 断言仍过；UEFI 模式离线日志 5 断言 |
| C5 | 缺固件 | exit 3，信息可读 |
| C6 | **CI boot-smoke** | job 绿；日志出现 EFI + GRUB + Linux + systemd + login |
| C7 | 回归 | 61 tests、P0-a 17 项、builder/boot 测试全过 |
| C8 | 边界 | 变更只在允许目录 |

## 9. 风险

1. `grub-mkstandalone` 的模块集合/内嵌配置在 CI 上可能需要调整；以 CI 日志为准。
2. OVMF 路径因发行版而异；boot-check 需多路径探测 + `--firmware` 覆盖。
3. `mkfs.ext4 -E offset=` + `-d` 组合需 e2fsprogs ≥ 1.47；CI 满足。
4. ESP 的 FAT32 最小尺寸 512MB 偏大但安全；后续可降。
5. GRUB 在 virtio 磁盘上的 `(hd0,gpt2)` 命名需 CI 验证；失败则改用 `search --fs-uuid`。
6. 启动会以 `rw` 挂载并改写 disk.img；P0-c 仍不解决"启动后摘要过期"（R2）。
