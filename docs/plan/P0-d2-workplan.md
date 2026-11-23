# P0-d2 工作分解：Live ISO（UEFI 启动）

> P0-d1 已闭环：桌面磁盘镜像 + UEFI 启动 + 8 条断言，CI 通过并修复了 marker 竞态。
> 本切片：产出**可从 ISO 启动的 live 系统**。Calamares 安装器留给 P0-d3。

- 日期：2026-11-23
- 基线提交：`2e030c8`
- 选择最小 Debian（无桌面）做 ISO，先隔离 ISO 机制；桌面 live 留给 P0-d3。

---

## 1. 范围

| 做 | 不做 |
|---|---|
| `mksquashfs` 生成 `filesystem.squashfs` | 桌面 live |
| `live-boot` initramfs（findiso） | Calamares / 安装到磁盘 |
| `grub-mkstandalone` 生成 EFI 镜像 + 内嵌 cfg | Secure Boot |
| `xorriso` 生成 UEFI El Torito ISO | BIOS 引导 |
| QEMU 从 CD-ROM 启动 + 6 条断言 | 持久化 |

## 2. 产物与 artifact

```
<out>/
  rootfs/                 # mmdebstrap + live-boot
  live.iso                # 最终 ISO
  iso/                    # ISO 树（诊断用）
    live/vmlinuz
    live/initrd.img
    live/filesystem.squashfs
    boot/grub/efi.img
  artifact.json
  build.log
```

`artifact.json`：

```json
{
  "images": [{"path": "live.iso", "format": "iso", "size_mb": 780, "sha256": "..."}],
  "boot": {
    "mode": "iso",
    "iso": "live.iso",
    "cmdline": "boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1",
    "memory_mb": 1024
  }
}
```

- `target.outputs` 只含 `iso` → 不构建磁盘（跳过 sgdisk/ESP/GRUB 磁盘）。
- 含 `iso` 且含 qcow2/raw → 两者都构建（P0-c 行为保留）。
- `partitions` 在 iso-only 模式下省略。

## 3. 构建步骤（冻结）

1. rootfs 额外安装：`live-boot`、`live-boot-initramfs-tools`（mmdebstrap 不装 Recommends）。
2. `mksquashfs rootfs iso/live/filesystem.squashfs -comp zstd -noappend`
3. 复制 `/boot/vmlinuz-*`、`/boot/initrd.img-*` 到 `iso/live/`。
4. `efi.img`（8 MiB FAT）：
   - `grub-mkstandalone -O x86_64-efi -o esp/EFI/BOOT/BOOTX64.EFI --modules="part_gpt part_msdos fat iso9660 normal linux search search_fs_file configfile serial terminal echo test" "boot/grub/grub.cfg=<cfg>"`
   - `mkfs.vfat -C -n EFI efi.img 8192` + `mcopy -i efi.img -s esp/EFI ::/`
5. `grub.cfg`：
   ```
   set timeout=3
   serial --unit=0 --speed=115200
   terminal_input serial
   terminal_output serial
   menuentry "Sysemble Live" {
     search --no-floppy --file --set=root /live/vmlinuz
     linux /live/vmlinuz boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1
     initrd /live/initrd.img
   }
   ```
6. `xorriso -as mkisofs -R -J -joliet-long -V SYMBLE -o live.iso \
     -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat iso/`

## 4. boot-check ISO 模式

```
tools/boot-check.sh --artifact <artifact.json> [--timeout 600] [--json]
```

- `boot.mode=iso`：QEMU 用 `-cdrom <iso>`，不挂磁盘；q35 + OVMF pflash 不变。
- 断言（6 条）：firmware、grub、kernel、systemd、login、**live**。
  - `boot.live`：日志含 `live-boot` 或 `live-media` 或 `squashfs`（不接受泛化的 `overlay`）。
- 退出码沿用 0/1/2/3/4。

## 5. CI

新增 `live-smoke`（ubuntu-latest，40 min）：

```
apt: 既有 + xorriso squashfs-tools
plan examples/minimal-debian-live.yaml → build --execute → boot-check --timeout 600
artifact: boot-evidence-live
```

## 6. 工作分解

| ID | 任务 | 产出 | 负责 |
|---|---|---|---|
| W1 | ISO 组装 + live-boot + artifact iso | `builders/debian/**` | SA-builder5 |
| W2 | boot-check iso 模式 + live 断言 + 测试 | `tools/boot-check.sh`、`tools/tests/**` | SA-boot4 |
| W3 | 示例 + CI live job | `examples/**`、`.github/**` | 主线程 |
| W4 | 独立验收 | `docs/acceptance/P0-d2.md` | SA-verify5 |

## 7. 验收

| # | 检查 | 通过条件 |
|---|---|---|
| E1 | 回归 | P0-a/b/c/d1 测试全过 |
| E2 | iso-only | 产物只有 live.iso；artifact mode=iso |
| E3 | 离线断言 | canned live 日志 6 pass；缺 live-boot 则 fail |
| E4 | boot-check 参数 | `-cdrom`、无 `-drive disk`、OVMF pflash |
| E5 | **CI live-smoke** | job 绿；日志出现 GRUB、Linux、systemd、login、live-boot/squashfs |
| E6 | 边界 | 变更只在允许目录 |

## 8. 风险

1. `live-boot` 的 initramfs 钩子/`findiso` 在 trixie 上的行为需 CI 验证；失败则改用 `live-boot-initramfs-tools` + 自定义 hook。
2. OVMF 从 El Torito EFI 启动对 `efi.img` 布局敏感；失败则检查 `-e boot/grub/efi.img` 与 FAT 内容。
3. `xorriso -isohybrid-gpt-basdat` 可能要求额外参数；以 CI 为准。
4. Squashfs zstd 需要内核支持（Debian 内核有）。
5. TCG 下 live 启动可能比磁盘慢；超时 600s。


## 9. 契约更正（2026-11-23，查证 live-boot 文档后）

`findiso=` 的参数是 **ISO 文件的路径**，不是 squashfs 的路径（见 [live-boot 文档](https://manpages.debian.org/bullseye/live-boot-doc/live-boot.7.en.html) 与 [Debian 邮件列表实测](https://lists.debian.org/debian-live/2018/04/msg00019.html)）。从真实 CD 启动时 live-boot 会自动在介质上找 `/live/filesystem.squashfs`，正确写法是：

```
boot=live live-media-path=/live console=ttyS0 ...
```

`boot.live` 断言只接受 `live-boot` / `live-media` / `squashfs` 三者（`overlay` 被排除：`evm: overlay not supported` 这类负向行也含该词，不构成 live 证据）。
