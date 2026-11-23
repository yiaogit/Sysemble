# P0-c1 独立验收报告（GPT + ESP + GRUB + UEFI 启动）

- 验收角色：**SA-verify3**（独立验收子代理；只读源码/CI/证据，只写 `docs/acceptance/**`）
- 日期：**2026-11-23**（本机 Europe/Madrid 14:03–14:08；CI 时间线为 UTC）
- 仓库：`sysemble/`，分支 `main`，HEAD **`616c04549407c18b0aea48faa1de73d0bca8a3ee`**
- 权威 CI run：**[45179757707](https://github.com/yiaogit/Sysemble/actions/runs/45179757707)**（push，`success`，创建于 2026-11-23T13:01:05Z）
- 权威 job：**[Boot smoke (Debian) #137710199241](https://github.com/yiaogit/Sysemble/actions/runs/45179757707/job/137710199241)**（`success`，13:01:08–13:02:54 UTC）
- 证据 artifact：`boot-evidence`，artifact ID **14821310676**，zip **19,863 bytes**，zip sha256 **`ceaa2c92...316e`**
- 验收范围：`docs/plan/P0-c-workplan.md` 的 **C1–C8**，以及任务书额外要求核实的 8 个点
- 判定原则：CI 绿 + 证据一致 + 断言真实 → PASS；任何不一致写清证据 → 需修复

**判定摘要：C1–C8 全部 PASS，无 FAIL。结论：`P0-c1 通过`。**

本轮未验证/设计风险集中在“镜像未上传无法独立重算摘要、rw 启动改写镜像、`(hd0,gpt2)` 与 `root=/dev/vda2` 的硬编码假设、OVMF/QEMU 版本绑定、aarch64、Secure Boot、安装器/桌面未做”，见 §6；它们不构成本轮假通过，但必须作为 P0-d 的输入收敛。

---

## 1. 环境与证据获取

### 1.1 本地环境（只做静态检查与离线回归）

| 项 | 实际值 |
|---|---|
| OS / 架构 | macOS **26.6.2**（Build 25G83），Darwin 25.6.0，**arm64** |
| Rust / Cargo | rustc **1.100.0** / cargo **1.100.0**（`<repo>/../.tools/cargo`，`RUSTUP_HOME=<repo>/../.tools/rustup`） |
| Python | **3.14.3**（`/opt/homebrew/bin/python3`）；依赖经 `PYTHONPATH=/tmp/pylibs314`（jsonschema 4.26.0 + PyYAML 6.0.4） |
| jq | **1.7.1-apple** |
| Linux 构建/启动工具 | 本机无 `mmdebstrap`/`mkfs.ext4`/`qemu-img`/`sgdisk`/`mkfs.vfat`/`mcopy`/`grub-mkstandalone`/QEMU；`build.sh --execute` 预期 exit 3 |
| 网络 | 只用 `gh` 读取 CI run/日志/artifact；回归不依赖网络 |

本机是 macOS arm64，**不能**做真实构建或 UEFI 启动；真实构建与 QEMU 启动的权威环境是 GitHub Actions（ubuntu-latest），本轮按工作单要求以 CI 证据为准，并在本机复跑全部可离线执行的回归。

### 1.2 CI 环境（来自 job log）

| 项 | 实际值 |
|---|---|
| Runner | **ubuntu-26.04**（Ubuntu 26.04.1 LTS，Runner Image 20261116.202.1，Azure northcentralus） |
| QEMU | **1:10.2.1+ds-1ubuntu3.3** |
| OVMF | **2025.11-3ubuntu7.3**（`/usr/share/OVMF/OVMF_CODE_4M.fd` + `OVMF_VARS_4M.fd`） |
| GRUB | **2.14-2ubuntu2.1** |
| mmdebstrap | **1.5.7-3** |
| mtools | **4.0.49-1** |
| 构建命令 | `sudo env PATH="$PATH" bash builders/debian/build.sh --plan plan.json --out out --execute` |
| 启动断言命令 | `bash tools/boot-check.sh --artifact out/artifact.json --timeout 300 --json`（**没有** `--log-from`） |
| 上传 | `actions/upload-artifact@v4`，`if: always()`，5 个文件：`plan.json`、`out/artifact.json`、`out/build.log`、`out/boot.log`、`out/boot-evidence.json` |
| 时间线 | Build 13:01:42–13:02:26；Boot 13:02:26.36–13:02:51.72（25s）；job 13:01:08–13:02:54 |

### 1.3 证据获取与防调包校验

```bash
cd "/Users/yiao/Documents/linux软件设计框架/sysemble"
gh run view 45179757707 -R yiaogit/Sysemble
rm -rf /tmp/p0c-verify
gh run download 45179757707 -R yiaogit/Sysemble -n boot-evidence -D /tmp/p0c-verify

# 原始 zip（用于校验上传摘要；gh 默认缓存目录在沙箱外，改用 /tmp）
XDG_CACHE_HOME=/tmp/p0c-verify/cache gh api \
  /repos/yiaogit/Sysemble/actions/artifacts/14821310676/zip \
  > /tmp/p0c-verify/boot-evidence.zip
shasum -a 256 /tmp/p0c-verify/boot-evidence.zip
```

实测：

| 检查 | 结果 |
|---|---|
| zip 大小 | **19,863 bytes**，与 job log `Final size is 19863 bytes` 一致 |
| zip sha256 | **`ceaa2c9247f047cfe36553c6e15a10936ba78f0e4aa209ed70709ea01316316e`**，与 job log `SHA256 digest of uploaded artifact zip is ...` 逐字一致 |
| zip 内容 | 5 个文件：`plan.json`、`out/artifact.json`、`out/build.log`、`out/boot.log`、`out/boot-evidence.json` |
| zip 解压 vs `gh run download` | 5 个文件 sha256 **全部 MATCH**（含 `boot.log=3e243c78...a860`） |
| headSha | `616c04549407c18b0aea48faa1de73d0bca8a3ee` = 本地 HEAD = GitHub 远端 commit（`P0-c1: GPT + ESP + GRUB UEFI boot image`，13:01:02Z） |

zip 内 5 个文件（与 `gh run download` 逐字相同）：

| 文件 | 大小 | sha256 |
|---|---|---|
| `plan.json` | 674 | `a73a4ef37ec4314cf9e9867be5da363e91b644eedebf35429ea9a29bd07e99ba` |
| `out/artifact.json` | 1,293 | `12f6891da65a73fc92140bbdf2ad1d0d61ea6c2101d84b2033e4c6b9e683e8ca` |
| `out/build.log` | 5,203 | `3214e8bc63945f783f47cdff51416ad8271d2454604fbbb6e9a6260378a2c0dc` |
| `out/boot.log` | 56,657 | `3e243c78e925555f19f4eee32fd473ec33f6b3b568b621e76ea7fa3886e2a860` |
| `out/boot-evidence.json` | 898 | `332feb400f2e877bf5a9f4cf753b4ca2e77e4ebcf420ba89072ec1c7976760b3` |

这排除了“拿旧 run 的证据充数”的可能：报告核对的 `boot.log`/`boot-evidence.json`/`artifact.json`/`build.log` 就是该次 run 上传的原始字节。

---

## 2. C1–C8 结果总表

| # | 检查 | 命令 / 证据 | 期望 | 实际 | 判定 |
|---|---|---|---|---|---|
| C1 | dry-run 回归 | `cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml > /tmp/p0c-dryrun-plan.json`；`bash builders/debian/build.sh --plan ... --out /tmp/p0c-dryrun/out --dry-run` | exit 0，P0-b/P0-a 行为不变（6 阶段、14 包），只写 `plan.copy.json` | exit 0；输出 `[1/6]`–`[6/6]`、14 个包、`Dry run complete`；`out/` 只有 `plan.copy.json`，且与输入 plan 字节相同（`cmp` identical） | **PASS** |
| C2 | 静态/伪造工具链测试 | 全部 tracked `*.sh` 跑 `bash -n`；`bash builders/debian/tests/artifact_test.sh`；`bash builders/debian/tests/build_exec_test.sh` | 语法全过；fake 工具链验证分区命令顺序、GRUB 配置、artifact 字段 | `bash -n` 全过；artifact **36/36**、build_exec **84/84**；含 `sgdisk` 布局、`mkfs.ext4 -E offset`、`grub-mkstandalone` 模块表、`mcopy`、`dd seek=1`、`grub.cfg (hd0,gpt2)/root=/dev/vda2`、artifact UEFI 字段等断言 | **PASS** |
| C3 | artifact v1 | `jq -e '<UEFI 形状断言>' /tmp/p0c-verify/out/artifact.json` | `boot.mode=uefi`、`partitions` 两项、`images` raw+qcow2 | `jq` 返回 `true`；`mode=uefi`、`disk=disk.img`、`grub.efi/config` 正确、partitions `esp 512 / root 3584`、images raw 4096 MB + qcow2 403 MB，sha256 均为 64-hex | **PASS** |
| C4 | boot-check 回归 | `bash tools/tests/boot-check-test.sh`；对真实 CI `boot.log` 跑 UEFI `--log-from`（5 断言）与 kernel 模式（3 断言）；缺 `login:` 负例 | kernel 模式 3 断言仍过；UEFI 模式离线 5 断言；负例必失败 | 本地测试 **27/27**；真实日志 UEFI **5/5 pass，exit 0**；kernel 模式 **3/3 pass，exit 0**；删掉 `login:` 的负例 `boot.login=fail`、`result=fail`、**exit 1** | **PASS** |
| C5 | 缺固件 | `bash tools/boot-check.sh --artifact <uefi-fixture> --qemu /usr/bin/true`；再显式 `--firmware /tmp/does-not-exist/OVMF_CODE.fd` | exit 3，信息可读 | 两次均 **exit 3**：`no OVMF firmware found ... looked for: /usr/share/OVMF/...`；显式路径报 `OVMF firmware not found or not readable` + 安装提示 | **PASS** |
| C6 | **CI boot-smoke** | run `45179757707` / job `137710199241`；job log + 下载的 `boot.log`/`boot-evidence.json` | job 绿；日志出现 EFI + GRUB + Linux + systemd + login | run/job 均 `success`；boot.log 含 `BdsDxe`/`GNU GRUB 2.14`/`EFI v2.7`/`Linux version`/`systemd[1]`/`login:`；5 条断言全 pass；真实 QEMU 25s | **PASS** |
| C7 | 回归 | 见 §5 | 61 tests、builder 36+84、boot 27、schema、P0-a 17/17 全过 | **61**；**36/36 + 84/84**；**27/27**；2 schema + 4 examples 全 ok；P0-a **17 passed / 0 failed / 0 blocked，RESULT: PASS** | **PASS** |
| C8 | 边界 | `git status --porcelain -uall`（验收前后）；`git diff --name-status HEAD^ HEAD` | 变更只在允许目录 | 验收前工作区干净；commit 616c045 改动 9 个文件，全在 `builders/debian/**`、`tools/**`、`.github/workflows/**`、`docs/plan/**`；本报告写入后仅新增 `docs/acceptance/P0-c.md` | **PASS** |

> C2 的 fake 工具链测试只验证脚本行为，不能替代真实构建；真实构建由 C6 的 CI 提供。C4 的 UEFI 离线重放是**额外复核**，CI 本身没有传 `--log-from`。

---

## 3. 证据摘录

### 3.1 `boot.log`（56,657 bytes，sha256 `3e243c78e925555f19f4eee32fd473ec33f6b3b568b621e76ea7fa3886e2a860`）

开头是 OVMF（EDK II）的 `BdsDxe`，随后是真实 GRUB 菜单与内核启动（已去除 ANSI 控制符，保留原文行意）：

```text
BdsDxe: loading Boot0002 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
BdsDxe: starting Boot0002 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
GNU GRUB  version 2.14
     Use the ^ and v keys to select which entry is highlighted.
     ...
     *Sysemble
     The highlighted entry will be executed automatically in 3s.
     ... 2s / 1s / 0s
EFI stub: Loaded initrd from LINUX_EFI_INITRD_MEDIA_GUID device path
[    0.000000] Linux version 6.12.118+deb13-amd64 (debian-kernel@lists.debian.org) ... #1 SMP PREEMPT_DYNAMIC Debian 6.12.118-1 (2026-11-20)
[    0.000000] Command line: BOOT_IMAGE=/boot/vmlinuz-6.12.118+deb13-amd64 root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=multi-user.target
...
[    0.000000] efi: EFI v2.7 by Ubuntu distribution of EDK II
[    0.000000] DMI: QEMU Standard PC (Q35 + ICH9, 2009), BIOS 2025.11-3ubuntu7.3 09/23/2026
[    0.000000] secureboot: Secure boot disabled
...
[    5.309709]  vda: vda1 vda2
...
[    8.807552] EXT4-fs (vda2): mounted filesystem 2fd06f35-2fc6-4f55-a49e-846a09c26afe r/w with ordered data mode. Quota mode: none.
...
[    9.386119] systemd[1]: Inserted module 'autofs4'
[    9.647588] systemd[1]: systemd 257.13-1~deb13u1 running in system mode ...
[    9.659905] systemd[1]: Hostname set to <minimal-debian>.
...
[  OK  ] Started serial-getty@ttyS0.service - Serial Getty on ttyS0.
[  OK  ] Reached target multi-user.target - Multi-User System.
...
Debian GNU/Linux 13 minimal-debian ttyS0

minimal-debian login: [   18.014566] ppdev: user-space parallel port driver
qemu-system-x86_64: terminating on signal 15 from pid 13636 (bash)
```

逐项核对：

| 检查 | 结果 | 证据 |
|---|---|---|
| 真 UEFI 固件 | 是 | `BdsDxe`（OVMF/EDK II 的启动管理器）+ `efi: EFI v2.7 by Ubuntu distribution of EDK II` |
| 真 GRUB，不是 `-kernel` 直启 | 是 | `GNU GRUB  version 2.14`、`*Sysemble` 菜单、3s 倒计时、GRUB 加载 initrd（`EFI stub: Loaded initrd...`） |
| 5 条断言内容 | 全中 | `EFI v`、`GRUB`、`Linux version`、`systemd[1]`、`login:`（见 §3.4） |
| 根分区来自 p2 | 是 | cmdline `root=/dev/vda2`；内核枚举 `vda: vda1 vda2`；`EXT4-fs (vda2)` 挂载 |
| 启动的是本次构建的 rootfs | 是 | EXT4 UUID `2fd06f35...6afe` 与 build.log 的 `Filesystem UUID` **完全相同**；hostname `minimal-debian` 与 plan.spec 一致；内核版本与 artifact 一致 |
| 启动到多用户/登录 | 是 | `Reached target multi-user.target`、`serial-getty@ttyS0.service`、`minimal-debian login:` |
| 无内核崩溃 | 是 | 大小写不敏感扫描 `kernel panic|Oops|BUG:|segfault` **无命中** |
| 日志由 QEMU 产生 | 是 | 结尾 `qemu-system-x86_64: terminating on signal 15 from pid ... (bash)`；有 QEMU DMI 与 virtio 磁盘行 |

> 唯一的 “Failed” 是 `systemd[1]: Failed to open libbpf, cgroup BPF features disabled: Operation not supported`（嵌套虚拟化/内核特性限制，良性）；另有 initrd 的 `Warning: fsck not present, so skipping root file system`（低风险，见 R11）。两者都不影响 5 条断言。

### 3.2 `artifact.json`（1,293 bytes，sha256 `12f6891d...e8ca`）

> 以下为字段摘录：省略了 `packages` 数组；两个 `sha256` 用省略号缩写，原文均为完整 64 位小写 hex。

```json
{
  "apiVersion": "sysemble/artifact/v1",
  "createdAt": "2026-11-23T13:02:22Z",
  "spec": "minimal-debian",
  "base": {"kind": "debian", "release": "trixie", "pin": "2026-11-01"},
  "arch": "x86_64",
  "rootfs": {"path": "rootfs", "size_mb": 389},
  "images": [
    {"path": "disk.img", "format": "raw", "size_mb": 4096, "sha256": "a2ce58b4...a6528"},
    {"path": "disk.qcow2", "format": "qcow2", "size_mb": 403, "sha256": "bf302fed...b711e"}
  ],
  "boot": {
    "mode": "uefi",
    "disk": "disk.img",
    "kernel": "rootfs/boot/vmlinuz-6.12.118+deb13-amd64",
    "initrd": "rootfs/boot/initrd.img-6.12.118+deb13-amd64",
    "cmdline": "root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=multi-user.target",
    "grub": {"efi": "esp/EFI/BOOT/BOOTX64.EFI", "config": "grub.cfg"}
  },
  "partitions": [
    {"index": 1, "role": "esp", "size_mb": 512, "fs": "vfat32"},
    {"index": 2, "role": "root", "size_mb": 3584, "fs": "ext4"}
  ],
  "builder": {"name": "build.sh", "version": "0.1.0"}
}
```

核对：

- `boot.mode=uefi`、`boot.disk=disk.img`、`boot.grub.efi/config` 与工作单 §4 契约一致。
- `images` 恰为 raw + qcow2，sha256 均为 64 位小写 hex；raw 4096 MB 与 `truncate -s 4096M` 一致；qcow2 403 MB 由 `qemu-img convert` 产出。
- `boot.kernel/initrd` 版本 `6.12.118+deb13-amd64` 与 `boot.log` 的 `Linux version` 一致；`boot.cmdline` 与 boot.log 的 `Command line` 只差 GRUB 自动加的 `BOOT_IMAGE=` 前缀。
- `partitions` 两项、role/fs 正确。**观察（非 FAIL）**：`partitions[1].size_mb=3584` 按冻结契约取 `disk_mb - ESP_SIZE_MB`（4096−512）；而 p2 实际从 513 MiB 开始、到 GPT 可用末端约 3583 MiB，报告值比物理 p2 大约 1 MiB。工作单 §4 示例本身写 3584，实现是**照契约**；但下游若用该字段推算边界需注意这 1 MiB 对齐差（见 R8）。

### 3.3 `build.log`（5,203 bytes，sha256 `3214e8bc63945f783f47cdff51416ad8271d2454604fbbb6e9a6260378a2c0dc`）

关键命令（连续、非拼接）：

```text
[build] stage 4/6: install packages - 14 packages via --include
  $ mmdebstrap --variant=minbase --include=apt,... linux-image-amd64,... trixie .../out/rootfs
I: success in 33.1571 seconds
[build] boot: kernel=vmlinuz-6.12.118+deb13-amd64, initrd=initrd.img-6.12.118+deb13-amd64
[build] stage 5/6: assemble GPT disk image - rootfs 389 MB, disk 4096 MB
[build] partitions: p1 esp 512 MB (vfat32, start 1 MiB), p2 root 3584 MB (ext4, start 513 MiB)
[build] root fs: 916992 x 4 KiB blocks (explicit size keeps ext4 inside p2/GPT)
  $ truncate -s 4096M .../out/disk.img
  $ sgdisk -Z .../out/disk.img
  $ sgdisk -n 1:2048:+512M -t 1:ef00 -n 2:0:0 -t 2:8300 .../out/disk.img
  $ mkfs.ext4 -F -b 4096 -E offset=537919488 -d .../out/rootfs -L SYMBLE .../out/disk.img 916992
mke2fs 1.47.2 (1-Jan-2025)
Creating filesystem with 916992 4k blocks and 229376 inodes
Filesystem UUID: 2fd06f35-2fc6-4f55-a49e-846a09c26afe
  $ mkfs.vfat -F 32 -C -n ESP .../out/esp.img 524288
  $ grub-mkstandalone -O x86_64-efi -o .../out/esp/EFI/BOOT/BOOTX64.EFI \
      --modules=part_gpt part_msdos fat ext2 normal linux search search_fs_uuid configfile serial terminal echo test \
      boot/grub/grub.cfg=.../out/esp/boot/grub/grub.cfg
  $ mcopy -i .../out/esp.img -s .../out/esp/EFI ::/
  $ dd if=.../out/esp.img of=.../out/disk.img bs=1M seek=1 conv=notrunc
512+0 records in
512+0 records out
536870912 bytes (537 MB, 512 MiB) copied, 0.351391 s, 1.5 GB/s
  $ qemu-img convert -O qcow2 .../out/disk.img .../out/disk.qcow2
[build] stage 6/6: write artifact manifest
[build] complete (mode: uefi)
```

核对：

- `sgdisk -Z` + `sgdisk -n 1:2048:+512M -t 1:ef00 -n 2:0:0 -t 2:8300` 是**真实命令回显**，且后面 `mkfs.ext4`/`mkfs.vfat`/`grub-mkstandalone`/`mcopy`/`dd`/`qemu-img` 均有真实输出或字节计数。
- `mkfs.ext4` 显式 `-b 4096 -E offset=537919488`（=513 MiB）和块数 `916992`；`mke2fs 1.47.2` 输出真实，UUID 与 boot.log 一致。
- `dd` 的 `536870912 bytes = 512 MiB` 与 ESP 大小一致；`seek=1` + `conv=notrunc` 将 ESP 合入 1 MiB 偏移。
- `qemu-img convert` 成功时静默，但后续 stage 6 与 artifact 中 qcow2 的 size/sha 证明其确实产出。
- `sgdisk` 的 “kernel is still using the old partition table” 警告是对文件镜像操作时的正常提示，不是失败。

### 3.4 `boot-evidence.json`（898 bytes，sha256 `332feb400f2e877bf5a9f4cf753b4ca2e77e4ebcf420ba89072ec1c7976760b3`）

```json
{
  "apiVersion": "sysemble/boot-evidence/v1",
  "artifact": "/home/runner/work/Sysemble/Sysemble/out/artifact.json",
  "qemu": "qemu-system-x86_64",
  "timeout_seconds": 300,
  "elapsed_seconds": 25,
  "result": "pass",
  "assertions": [
    {"id": "boot.firmware", "result": "pass", "detail": "matched `EFI v` and `UEFI`"},
    {"id": "boot.grub",     "result": "pass", "detail": "matched `GRUB` and `Booting`"},
    {"id": "boot.kernel",   "result": "pass", "detail": "matched `Linux version`"},
    {"id": "boot.systemd",  "result": "pass", "detail": "matched `systemd[1]` and `Reached target`"},
    {"id": "boot.login",    "result": "pass", "detail": "matched `login:`"}
  ],
  "log": "boot.log",
  "log_sha256": "3e243c78e925555f19f4eee32fd473ec33f6b3b568b621e76ea7fa3886e2a860"
}
```

一致性核对：

| 检查 | 结果 |
|---|---|
| `log_sha256` vs 实际 `shasum -a 256 boot.log` | **逐字相同**（`3e243c78...a860`） |
| 5 条断言 | 全 `pass`，id 顺序为 firmware/grub/kernel/systemd/login，与 UEFI 断言集一致 |
| `result` | `pass`，与 job “Boot and assert” step exit 0 一致 |
| `elapsed_seconds=25` | job log 的 Boot step 13:02:26.36 → 13:02:51.72 = **25.36s**；boot.log 内核时间 18.0s；timeout 300s，余量充足 |
| `log` | `boot.log`，相对 artifact 目录，符合契约 |
| `artifact` | 记录 CI 绝对路径（`/home/runner/work/.../out/artifact.json`），下载后路径不同属正常 |

### 3.5 交叉证据（排除“另一份旧镜像/日志”）

| 交叉项 | build.log / artifact | boot.log | 结果 |
|---|---|---|---|
| ext4 UUID | `Filesystem UUID: 2fd06f35-2fc6-4f55-a49e-846a09c26afe` | `EXT4-fs (vda2): mounted filesystem 2fd06f35-...` | **一致** |
| 内核版本 | `boot.kernel=rootfs/boot/vmlinuz-6.12.118+deb13-amd64` | `Linux version 6.12.118+deb13-amd64` | **一致** |
| hostname | `plan.spec=minimal-debian` / customize hook | `systemd[1]: Hostname set to <minimal-debian>` | **一致** |
| 根设备 | `boot.cmdline=root=/dev/vda2 ...` | `Command line: ... root=/dev/vda2 ...`（GRUB 加 `BOOT_IMAGE=` 前缀） | **一致** |
| 磁盘大小 | `truncate -s 4096M`，artifact raw 4096 MB | virtio `8388608 512-byte logical blocks (4.00 GiB)` | **一致** |
| 分区 | build.sh 的 `sgdisk` 两项 + artifact partitions 两项 | `vda: vda1 vda2` | **一致** |
| GRUB | `menuentry "Sysemble"`、timeout 3 | GRUB 菜单 `*Sysemble`、3s 倒计时 | **一致** |

---

## 4. 真实性判断依据（为什么不是 mock/假通过）

### 4.1 boot-check 的 UEFI 分支确实使用 pflash + disk

`tools/boot-check.sh:1311-1323`（uefi 分支）：

```bash
qemu_args=(
  -machine q35 -m 1024 -smp 2 -nographic -no-reboot
  -drive "if=pflash,format=raw,readonly=on,file=$FIRMWARE_CODE"
  -drive "if=pflash,format=raw,file=$VARS_TMP"
  -drive "file=$BOOT_DISK_ABS,format=raw,if=virtio"
)
```

- 两条 pflash：只读 `OVMF_CODE_4M.fd` + 可写 VARS 临时副本；一条 virtio 磁盘。
- **没有** `-kernel`/`-initrd`/`-append`；`-kernel` 只出现在 `kernel` 分支（`1326-1336`），由 artifact 的 `boot.mode` 选择（`784-838`）。
- `resolve_firmware()`（`1173-1257`）按契约探测 `/usr/share/OVMF/OVMF_CODE_4M.fd` 等路径，VARS 复制到 `$TMP_DIR` 并在退出时清理；缺固件 exit 3。
- CI job log 明确打印 `boot-check: firmware: /usr/share/OVMF/OVMF_CODE_4M.fd`、`firmware vars: ...OVMF_VARS_4M.fd`、`launching qemu-system-x86_64 (uefi/OVMF, -machine q35, timeout 300s)`。
- `grub.cfg` 由 `grub_cfg_text()`（`lib.sh:816-850`）渲染为冻结内容：`set root=(hd0,gpt2)`、`linux /boot/<kernel> root=/dev/vda2 rw ...`、`initrd /boot/<initrd>`；`build_exec_test.sh` 对这份配置逐行断言，真实启动也由它引导成功。
- boot.log 的 `BdsDxe` + `GNU GRUB` 是 OVMF 从磁盘加载 GRUB 的直接证据；如果 CI 用 `-kernel` 直启，不会出现 OVMF 的 BdsDxe 和 GRUB 菜单。

### 4.2 断言是内容匹配，不是硬编码 pass

- `log_has()`（`tools/boot-check.sh:902-906`）是 `grep -Fq "$1" "$LOG_PATH"`，扫描 QEMU 写出的串口日志。
- `all_assertions_pass()`（`913-923`）在 uefi 模式下要求 firmware + grub + kernel + systemd + login **全部**命中；QEMU 监控循环用它决定何时停止。
- `evaluate_assertions()`（`1000-1025`）逐条填充 firmware/grub/kernel/systemd/login 结果；`determine_result()`（`1027-1045`）在 uefi 模式下任一 firmware/grub 失败即 `fail`，其余三条也必须全 pass。
- `write_evidence()`（`1454-1555`）在断言后现场 `sha256_file` 计算日志哈希。
- 本地 `tools/tests/boot-check-test.sh` 的负例证明断言会失败：`UEFI log without GRUB -> boot.grub fail, exit 1`、`UEFI assertion failure -> exit 1`、`empty log -> exit 1`；本报告又用真实 CI 日志删掉 `login:` 重放，得到 `boot.login=fail`、`result=fail`、exit 1。
- 没有 `PASS=1` 之类的短路，也没有“看到 artifact 就通过”；`--log-from` 只在显式离线模式使用，CI 命令没有传。

### 4.3 CI 没有容忍失败

- `.github/workflows/ci.yml:29-68` 的 `boot-smoke` job 中，`Build disk image`（49 行）和 `Boot and assert`（55 行）都是普通 `run` step，**没有 `continue-on-error`、没有 `|| true`**（全文件 grep 无命中）。
- boot-check 非 0 → step 失败 → job 失败；只有 `Upload boot evidence` 是 `if: always()`，用于保留失败现场，不影响 job 结论。
- 本次 run 的 3 个 job 全部 `success`，`Boot and assert` step `success`，job log 无 `##[error]`。
- `boot-check` 以 `--json` 运行，证据由脚本自己写；stdout 打印的 evidence 与下载文件一致。

### 4.4 构建/启动是真实执行，不是 stub

- `build.sh --execute` 走到 `build_native()`，实际调用 `mmdebstrap`、`truncate`、`sgdisk`、`mkfs.ext4 -E offset`、`mkfs.vfat`、`grub-mkstandalone`、`mcopy`、`dd`、`qemu-img`（`builders/debian/build.sh:459-697`）。
- `build.log` 有 mmdebstrap 的真实 apt/解包/安装/清理输出（`I: success in 33.1571 seconds`）、真实 `mke2fs 1.47.2` 输出、`mkfs.fat 4.2`、`dd` 的 512 MiB 字节计数。
- `artifact_json()`（`lib.sh:1028-1189`）在写清单前检查 rootfs/disk.img/disk.qcow2 存在，并用 `find_boot_image`、`sha256_file`、`file_size_mb` 计算真实值；不是硬编码。
- boot.log 的 QEMU DMI、OVMF BdsDxe、GRUB 2.14、virtio 磁盘、内核/systemd/login、QEMU SIGTERM 结束行，都是真实虚拟机串口日志的特征。
- 交叉证据（§3.5）把 build.log 的 ext4 UUID 与 boot.log 的挂载 UUID 对上，把 artifact 的 kernel/cmdline 与 boot.log 对上，排除了“启动一个预先准备好的别的镜像”。

### 4.5 本轮没有做的事（避免过度声称）

- 没有在本机重跑真实 build/QEMU（macOS 无 Linux/root/mmdebstrap/qemu）。真实构建与启动只由 CI 提供。
- 没有独立重算 `disk.img`/`disk.qcow2` 的 sha256（镜像未上传，见 R1）。
- 没有 byte-level 检查 GPT/ESP/ext4（`sgdisk -p`、`blkid`、`fsck` 未在证据里），只能由命令回显 + 启动行为反证。
- 没有做真人登录、安装器、桌面、Secure Boot、aarch64 验证（见 §6）。
- 没有在 CI 之外重复一次真实 UEFI 启动；CI 是唯一权威。

---

## 5. 回归结果（本机实际执行）

| 检查 | 命令 | 结果 |
|---|---|---|
| Rust workspace | `CARGO_HOME=... RUSTUP_HOME=... cargo test --workspace` | **61 passed / 0 failed**（9+12+8+10+8+14；doc-tests 0），exit 0 |
| builder artifact 单测 | `bash builders/debian/tests/artifact_test.sh` | **36/36 passed**，exit 0 |
| builder execute 单测（fake toolchain） | `bash builders/debian/tests/build_exec_test.sh` | **84/84 passed**，exit 0 |
| boot-check 测试 | `bash tools/tests/boot-check-test.sh` | **27 passed / 0 failed**，exit 0 |
| schema | `PYTHONPATH=/tmp/pylibs314 /opt/homebrew/bin/python3 tools/validate.py` | 2 个 schema + 4 个示例全 `ok`，`all specs valid`，exit 0 |
| P0-a 验收 | `PYTHONPATH=/tmp/pylibs314 bash tests/acceptance/run.sh` | **17 passed / 0 failed / 0 blocked**，`RESULT: PASS`，exit 0 |
| dry-run 回归 | 见 C1 | exit 0；6 阶段、14 包；仅 `plan.copy.json` |
| shell 语法 | 对全部 tracked `*.sh` 跑 `bash -n` | 全部通过 |
| macOS 原生拒绝路径 | `bash builders/debian/build.sh --plan ... --out ... --execute` | **exit 3**；逐条报 Linux/root/mmdebstrap/mkfs.ext4/qemu-img/sgdisk/mkfs.vfat/mcopy/grub-mkstandalone 缺失；未创建 out |
| 工作区边界 | `git status --porcelain -uall` / `git diff --stat` | 验收前干净；报告写入后仅新增 `docs/acceptance/P0-c.md` |

> `build_exec_test.sh` 的 fake `mmdebstrap`/`mkfs.*`/`grub-mkstandalone`/`mcopy`/`dd`/`qemu-img` 不能替代真实构建；真实构建以 CI 为准。本报告用真实 CI 日志做离线断言重放，属于额外复核。

---

## 6. 风险与 P0-d 输入

以下均为**未验证项/设计风险**，不是 C1–C8 的失败项；按任务要求列出，供 P0-d 排期。

### R1 — 镜像未上传，摘要无法独立重算（中）

上传的 artifact 只有 5 个文本文件，没有 `disk.img`、`disk.qcow2`、`rootfs/`。因此：

- 无法重算 artifact 里两个 64-hex sha256 是否仍对应当前镜像；
- 无法直接检查 GPT 分区表、ESP 内容、ext4 内文件（hostname、machine-id、serial-getty enable 状态、包列表）；
- 只能依赖 build.log 命令回显 + boot.log 的 UUID/hostname/内核版本行为反证。

**P0-d 输入：** 上传镜像摘要清单（或 `qemu-img info`、`sgdisk -p`、`blkid` 输出）；在 boot-check 启动前校验 `images[].sha256`；必要时上传 `disk.img` 或 rootfs `find | sha256sum` 清单。

### R2 — `rw` 启动会改写 `disk.img`，artifact 摘要在启动后即过期（中）

boot.log 显示 root 以 `rw` 挂载（`EXT4-fs (vda2) ... r/w`），systemd 初始化 machine-id、随机种子、journal 等都会写入。`artifact.json` 的 `disk.img.sha256` 是 **13:02:22 构建时**的摘要，13:02:26 之后 QEMU 以 rw 挂载并写入；之后拿 `out/disk.img` 去对 artifact 的 sha256 会不匹配。

**P0-d 输入：** 冒烟启动改用 `-snapshot`（或只读盘 + overlay）；boot 前校验摘要、boot 后明确“镜像已被测试写脏”；不要用 boot 后的 raw 镜像作为发布物。

### R3 — `(hd0,gpt2)` 与 `root=/dev/vda2` 的硬编码假设（中）

- GRUB 配置写死 `set root=(hd0,gpt2)`；CI 只有一块 virtio 磁盘，所以 `hd0` 成立。若未来增加第二块盘、改变磁盘顺序/控制器（IDE/SATA/NVMe），`hd0`/`vda` 可能变化，导致找不到 root。
- `root=/dev/vda2` 同样依赖 virtio-blk 枚举；没有用 UUID/PARTUUID。
- 本轮 CI 的 `(hd0,gpt2)` 已由成功启动验证（GRUB 从 p2 读内核/initrd），但仅限这一种硬件拓扑。

**P0-d 输入：** 改用 `search --fs-uuid --set=root <UUID>` 或 `root=PARTUUID=...`；在 QEMU 参数中固定磁盘序号/控制器；增加“多磁盘/不同控制器”启动测试。

### R4 — OVMF/QEMU 版本绑定 runner（中/低）

- CI 使用 OVMF **2025.11-3ubuntu7.3**、QEMU **10.2.1**、GRUB **2.14**；boot-check 默认探测 `/usr/share/OVMF/OVMF_CODE_4M.fd` 等路径。
- 不同发行版/旧 OVMF 的 pflash 布局、VARS 模板名、启动项行为可能不同；evidence 只记 `qemu-system-x86_64`，没有 QEMU 版本、OVMF 版本、实际 argv。
- 本轮没有在其他 OVMF 版本上重跑。

**P0-d 输入：** evidence 记录 `qemu --version`、OVMF 路径/版本、`argv`（脱敏）；CI 固定/打印 OVMF 版本；至少在 Debian/Ubuntu 两种 OVMF 包上冒烟。

### R5 — aarch64 / 跨架构未验证（中）

- `boot-check` 对 `boot.mode=uefi` 且 `arch != x86_64` 直接 exit 2（`tools/boot-check.sh:805-810`），UEFI 仅支持 x86_64。
- builder 的 `native_preflight` 不检查宿主 `uname -m` 与 plan `target.arch` 一致（P0-b R5 仍在）；在 arm64 Linux 上构建 x86_64 plan 会产出宿主架构 rootfs 却写 `arch: x86_64`。
- 本轮 CI 是 x86_64，aarch64 的 GPT/GRUB/AAVMF 路径完全未验证。

**P0-d 输入：** 明确 x86_64-only 或实现 aarch64（AAVMF + grub-arm64-efi）；增加宿主架构与 plan.arch 的强校验；在 artifact 记录实际 Debian 架构。

### R6 — Secure Boot 未启用（中）

boot.log 明确 `secureboot: Secure boot disabled`；构建/启动流程没有签名步骤，没有 shim/密钥轮换。本轮只验证“UEFI 能启动”，不验证“安全启动策略下能启动”，也没有检查签名链。

**P0-d 输入：** 生成/签名 shim + GRUB + kernel（或 UKI），在启用 Secure Boot 的 OVMF 上做正/负例；记录签名链与密钥管理方案。

### R7 — 安装器/桌面/ISO 未做（P0-d 范围）

P0-c1 只做引导层：GPT + ESP + GRUB + UEFI。没有 Calamares/安装器、桌面（KDE）、ISO/squashfs、持久化、安装后首启。`examples/debian-kde-dev.yaml` 的桌面目标尚未进入本阶段验收。

**P0-d 输入：** 安装器（Calamares 或等价物）+ 桌面镜像 + 安装后首启验证；ISO/squashfs 与持久化；安装器对 GPT/ESP/GRUB 的复用或重写。

### R8 — artifact 的 root 分区大小比物理 p2 大约 1 MiB（低）

`partitions[1].size_mb=3584` 按冻结契约取 `disk_mb - ESP_SIZE_MB`；p2 实际从 513 MiB 开始，到 GPT 可用末端约 3583 MiB。工作单 §4 示例本身写 3584，实现是照契约，但下游若用该字段推算边界会差 1 MiB。

**P0-d 输入：** 从 GPT 实际几何生成 partitions（或明确该字段是“预算”而非“精确大小”）；在 artifact 里同时给 `start_mb`/`end_mb`/`blocks`。

### R9 — evidence 缺 QEMU/OVMF 版本与 argv（低）

`boot-evidence.json` 只记 `qemu: qemu-system-x86_64`，没有版本、`-accel`、`-cpu`、pflash 路径、argv；boot.log 含 ANSI 控制字符。CI 的 UEFI 参数只能靠源码审查 + job log 的 `launching ... (uefi/OVMF, -machine q35)` 推断，不能从证据文件逐字复核。

**P0-d 输入：** evidence 增加 `qemu_version`、`accelerator`、`firmware`、`argv`（脱敏）；另存去控制字符的 `boot.clean.log`。

### R10 — CI 未运行 builder/boot 单测（低）

`ci.yml` 只跑 schema、`cargo test`、真实 boot-smoke；`artifact_test.sh`、`build_exec_test.sh`、`boot-check-test.sh` 是本地回归，CI 不强制。若未来有人改脚本但只跑 CI，fake 工具链/离线断言回归可能漏掉。

**P0-d 输入：** 在 CI 增加一个 `unit` job 跑三个 shell 测试（不需要 root/QEMU），与 boot-smoke 并行。

### R11 — initrd 的 fsck 警告（低）

boot.log 有 `Warning: fsck not present, so skipping root file system`。对冒烟无影响（root 已成功挂载），但说明 initramfs 未包含 fsck；若 P0-d 要求启动时 fsck，需要补包/钩子并验证。

**P0-d 输入：** 决定是否在 initramfs 中包含 `fsck`/`e2fsck` 并测试异常文件系统场景。

### R12 — 断言是“启动到 login 提示”，不是“可登录/服务健康”（范围说明）

5 条断言只证明固件→GRUB→kernel→systemd→login 提示出现；没有真正输入用户名/密码，也没有检查安装器/桌面/网络。作为 P0-c1 冒烟足够，但不能外推为“发行版可用”。

**P0-d 输入：** 增加登录（或 SSH/serial 自动登录）后的服务健康检查；安装器/桌面场景的端到端断言。

---

## 7. 最终结论

- **C1–C8：全部 PASS，无 FAIL。**
- **CI：** run `45179757707` 全绿；`Boot smoke (Debian)` 真实执行了 `mmdebstrap` → `sgdisk` GPT → `mkfs.ext4 -E offset` → `mkfs.vfat` ESP → `grub-mkstandalone` → `mcopy` → `dd seek=1` → `qemu-img` → **OVMF pflash + virtio disk** 启动，25 秒内命中 5 条串口断言；job 绿不是“跳过/容忍失败”得来的。
- **真实性：** boot.log 有 OVMF `BdsDxe`、`GNU GRUB 2.14` 菜单/倒计时、`EFI v2.7`、`Linux version`、`systemd[1]`、`EXT4-fs (vda2)`、`login:` 和 QEMU SIGTERM 结束行；build.log 的 ext4 UUID 与 boot.log 挂载 UUID 一致，artifact 的 kernel/cmdline 与 boot.log 一致；boot-check 的 UEFI 分支使用 pflash + disk，没有 `-kernel`，断言是 `grep -Fq` 内容匹配，CI 无 `continue-on-error`。
- **证据链：** `log_sha256` 与下载的 `boot.log` 实际 sha256 相同；5 条断言全 pass；`elapsed=25` 与 job 25.36s 相符；上传 zip sha256 与 job log 记录一致，zip 内 5 个文件与下载文件逐字相同。
- **边界：** 验收前工作区干净；P0-c1 commit 改动只在允许目录；本报告只新增 `docs/acceptance/P0-c.md`。
- **非阻断风险：** 镜像未上传导致摘要不可独立复核（R1）、rw 启动使摘要过期（R2）、`(hd0,gpt2)`/`root=/dev/vda2` 硬编码（R3）、OVMF/QEMU 版本绑定（R4）、aarch64（R5）、Secure Boot（R6）、安装器/桌面未做（R7）等，均应在 P0-d 收敛。

**P0-c1 通过。**

---

## 附录 A：本次实际执行的关键命令

```bash
cd "/Users/yiao/Documents/linux软件设计框架/sysemble"

# 证据
gh run view 45179757707 -R yiaogit/Sysemble
rm -rf /tmp/p0c-verify
gh run download 45179757707 -R yiaogit/Sysemble -n boot-evidence -D /tmp/p0c-verify
XDG_CACHE_HOME=/tmp/p0c-verify/cache gh api \
  /repos/yiaogit/Sysemble/actions/artifacts/14821310676/zip \
  > /tmp/p0c-verify/boot-evidence.zip
shasum -a 256 /tmp/p0c-verify/boot-evidence.zip
unzip -q -d /tmp/p0c-verify/zip /tmp/p0c-verify/boot-evidence.zip
# 与 gh run download 的 5 个文件逐字比较（cmp）

# 证据一致性
shasum -a 256 /tmp/p0c-verify/out/boot.log
jq -r .log_sha256 /tmp/p0c-verify/out/boot-evidence.json
jq -e '<artifact UEFI shape 断言>' /tmp/p0c-verify/out/artifact.json
grep -F 'GNU GRUB'      /tmp/p0c-verify/out/boot.log
grep -F 'efi: EFI v'    /tmp/p0c-verify/out/boot.log
grep -F 'Linux version' /tmp/p0c-verify/out/boot.log
grep -F 'systemd[1]'    /tmp/p0c-verify/out/boot.log
grep -F 'login:'        /tmp/p0c-verify/out/boot.log
grep -F 'EXT4-fs (vda2)' /tmp/p0c-verify/out/boot.log
grep -iE 'kernel panic|Oops|BUG:|segfault' /tmp/p0c-verify/out/boot.log  # 无命中

# 离线断言：真实 CI 日志，UEFI 5 条 / kernel 3 条 / 缺 login 负例
bash tools/boot-check.sh --artifact /tmp/p0c-offline/out/artifact.json \
  --log-from /tmp/p0c-offline/out/boot.log --json          # exit 0, 5 pass
bash tools/boot-check.sh --artifact /tmp/p0c-offline/kernel/artifact.json \
  --log-from /tmp/p0c-verify/out/boot.log --json           # exit 0, 3 pass
bash tools/boot-check.sh --artifact /tmp/p0c-offline/out/artifact.json \
  --log-from /tmp/p0c-offline/no-login.log --json          # exit 1, boot.login fail

# 缺固件
bash tools/boot-check.sh --artifact /tmp/p0c-offline/fw/artifact.json \
  --qemu /usr/bin/true                                     # exit 3, no OVMF firmware
bash tools/boot-check.sh --artifact /tmp/p0c-offline/fw/artifact.json \
  --qemu /usr/bin/true --firmware /tmp/does-not-exist/OVMF_CODE.fd  # exit 3

# 本机回归
export CARGO_HOME=/Users/yiao/Documents/linux软件设计框架/.tools/cargo
export RUSTUP_HOME=/Users/yiao/Documents/linux软件设计框架/.tools/rustup
"$CARGO_HOME/bin/cargo" test --workspace
bash builders/debian/tests/artifact_test.sh
bash builders/debian/tests/build_exec_test.sh
bash tools/tests/boot-check-test.sh
PYTHONPATH=/tmp/pylibs314 /opt/homebrew/bin/python3 tools/validate.py
PYTHONPATH=/tmp/pylibs314 bash tests/acceptance/run.sh

# dry-run / 原生拒绝 / 语法 / 边界
"$CARGO_HOME/bin/cargo" run -q -p sysemble-cli -- plan examples/minimal-debian.yaml > /tmp/p0c-dryrun-plan.json
bash builders/debian/build.sh --plan /tmp/p0c-dryrun-plan.json --out /tmp/p0c-dryrun/out --dry-run
bash builders/debian/build.sh --plan /tmp/p0c-dryrun-plan.json --out /tmp/p0c-refuse/out --execute  # exit 3
for f in $(git ls-files '*.sh'); do bash -n "$f" || echo "SYNTAX FAIL: $f"; done
git status --porcelain -uall
```

## 附录 B：C1–C8 与证据位置对照

| 验收项 | 本报告位置 | 判定 |
|---|---|---|
| C1 dry-run 回归 | §2 C1、§5 | PASS |
| C2 静态/伪造工具链 | §2 C2、§5 | PASS |
| C3 artifact v1 | §2 C3、§3.2 | PASS |
| C4 boot-check 回归 | §2 C4、§3.1、§3.4 | PASS |
| C5 缺固件 | §2 C5 | PASS |
| C6 CI boot-smoke | §1.2、§2 C6、§3 | PASS |
| C7 回归 | §5 | PASS |
| C8 边界 | §2 C8、§7 | PASS |
| 任务书 1 真 UEFI/GRUB | §3.1、§4.1、§4.4 | PASS |
| 任务书 2 分区真实 | §3.3、§3.2 | PASS |
| 任务书 3 root 来自 p2 | §3.1、§3.5 | PASS |
| 任务书 4 证据一致 | §3.4、§1.3 | PASS |
| 任务书 5 不是假通过 | §4 | PASS |
| 任务书 6 回归 | §5 | PASS |
| 任务书 7 边界 | §2 C8、§7 | PASS |
| 任务书 8 风险 | §6 | 已列出 |
