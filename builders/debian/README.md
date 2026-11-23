# Debian builder (P0-a + P0-b + P0-c1 + P0-d1 + P0-d2 + P0-d3 + P0-e1)

`build.sh` reads the `plan.json` produced by `sysemble plan --json` and turns
it into bootable Debian disk images, a live ISO, an unattended installer ISO,
or a serial TUI installer ISO, selected by `plan.target.outputs` and
`--installer`/`--installer-tui`:

- **P0-a**: plan validation, dry run, and rootfs bootstrap with
  [mmdebstrap](https://mmdebstrap.de/) (native or `debian:trixie` Docker).
- **P0-b**: the native `--execute` path created a raw ext4 image with
  `mkfs.ext4 -d`, converted it to qcow2, and wrote a `sysemble/artifact/v1`
  manifest. That image booted with `qemu -kernel/-initrd`; the direct-kernel
  artifact shape is still accepted by consumers (`boot.mode` absent = kernel).
- **P0-c1**: the native `--execute` path now builds a **GPT disk with a FAT32
  ESP and a GRUB EFI bootloader**, so the image boots through UEFI/OVMF:

  ```
  disk.img (GPT)
    p1  1 MiB   +512 MiB  ESP   vfat32  label ESP   (GRUB BOOTX64.EFI)
    p2  513 MiB  rest      root  ext4    label SYMBLE
  ```

  The artifact gains `boot.mode="uefi"`, `boot.disk`, `boot.grub`, `partitions`,
  and a `root=/dev/vda2` cmdline.
- **P0-d1**: the builder infers a desktop from `plan.packages` (the plan schema
  stays frozen). A display manager (`gdm3`/`sddm`/`lightdm`) selects
  `graphical.target`, `systemd.journald.forward_to_console=1`, 2048 MB of guest
  RAM, and the artifact fields `desktop` + `boot.graphical`/`boot.memory_mb`.
  A plan without a display manager keeps the frozen P0-c multi-user cmdline,
  1024 MB, and no `desktop` object. The XFCE example
  (`examples/debian-xfce.yaml`) plans `xfce4` + `lightdm` and therefore boots
  graphically.
- **P0-d2**: `target.outputs` containing `iso` builds a **UEFI El Torito live
  ISO** (`live.iso`) with live-boot and `live-media-path=/live`. An ISO-only plan
  (`["iso"]`, no `qcow2`/`raw`) skips the disk/partition/ESP/GRUB-disk pipeline
  entirely; `["iso","qcow2"]` builds both. The ISO adds
  `live-boot`/`live-boot-initramfs-tools` to `--include`, stages
  `live/{vmlinuz,initrd.img,filesystem.squashfs}`, builds an 8 MiB FAT
  `efi.img` with `grub-mkstandalone` + `mcopy`, and packs it with `xorriso`.
  Its artifact uses `boot.mode="iso"`/`boot.iso="live.iso"`; an ISO-only
  manifest omits `partitions`.
- **P0-d3**: `--installer` turns an ISO-only build into an **unattended
  installer ISO**. The live rootfs gets `/usr/local/sbin/sysemble-install`
  (0755) and `/etc/systemd/system/sysemble-install.service` (enabled through
  `multi-user.target.wants`), `--include` adds
  `rsync grub-efi-amd64 grub-efi-amd64-bin dosfstools gdisk e2fsprogs`, the ISO
  cmdline gains `sysemble.install=/dev/vda`, and the artifact records
  `boot.mode="install"`/`boot.install_device="/dev/vda"` with `memory_mb=1024`.
  The guest installer partitions/formats `/dev/vda`, rsyncs the live root,
  writes fstab + GRUB, prints `SYMBLE: install complete`, and powers off. A
  non-ISO-only plan is rejected with exit 2; Calamares stays out of scope
  (P0-d3b).
- **P0-e1**: `--installer-tui` builds the same installer ISO with a **serial
  TUI wizard** instead of a preselected disk. The ISO cmdline gains
  `sysemble.install.tui=1`, the shared installer script prompts for disk,
  hostname, user, password, and confirmation, and the artifact records
  `boot.mode="install"`/`boot.install_tui=true` with no `install_device`.
  The installed system gets `/etc/hostname`, `/etc/hosts`, the chosen user,
  and the chosen password (or a locked account when the password is empty).

The authoritative acceptance is the GitHub Actions `boot-smoke` (disk),
`live-smoke` (ISO), `install-smoke` (unattended installer ISO), and
`tui-install-smoke` (TUI installer ISO) jobs on `ubuntu-latest`.
The development host is macOS arm64, where no real native build can run; see
[Local checks](#local-checks).

## Interface

```
builders/debian/build.sh --plan <plan.json> --out <dir> \
  [--dry-run] [--execute] [--engine docker|native] [--installer | --installer-tui]
```

| Option | Meaning |
|---|---|
| `--plan <path>` | Required. `plan.json` from `sysemble plan --json`. |
| `--out <dir>` | Required. Output directory; created if missing. Must not be `/` or an existing file. |
| `--dry-run` | Validate the plan, print the stages/packages/estimates, write only `<out>/plan.copy.json`, exit 0. Disk stage lines stay compatible; ISO plans show a live stage. |
| `--execute` | Explicit alias for the default build mode (no `--dry-run`): build the rootfs plus the outputs requested by `target.outputs` (live ISO and/or GPT/UEFI disk images) and `artifact.json`. Mutually exclusive with `--dry-run`. |
| `--engine native` | Default. Build on this Linux host (`uname -s` = Linux, euid 0, and the tools below in `PATH`). |
| `--engine docker` | Bootstrap the rootfs inside `debian:trixie`; needs `docker` CLI and a reachable daemon. Disk/ISO assembly is **not** implemented for Docker, so `--execute` with `--engine docker` is rejected (exit 2). |
| `--installer` | P0-d3: build the headless installer ISO. Requires an **ISO-only** plan (`target.outputs` contains `iso` and no `qcow2`/`raw`); anything else exits 2 before `<out>` is created. Works with `--dry-run` (prints the installer plan). |
| `--installer-tui` | P0-e1: build the TUI installer ISO. Same ISO-only requirement, script, unit, and runtime packages as `--installer`; the ISO cmdline becomes `sysemble.install.tui=1` and the artifact records `boot.mode="install"`/`boot.install_tui=true` with no `install_device`. Mutually exclusive with `--installer`. |
| `-h`, `--help` | Print usage and exit 0. |

`--opt value` and `--opt=value` are both accepted. Missing or unknown
arguments print usage and exit 2.

### Outputs (native `--execute`)

```
<out>/
  rootfs/                 # mmdebstrap rootfs (live-boot packages for ISO)
  live.iso                # UEFI El Torito live ISO        (ISO plans)
  iso/                    # ISO tree, kept for diagnosis  (ISO plans)
    live/vmlinuz          # highest rootfs/boot/vmlinuz-*
    live/initrd.img       # highest rootfs/boot/initrd.img-*
    live/filesystem.squashfs
    boot/grub/efi.img     # 8 MiB FAT with EFI/BOOT/BOOTX64.EFI
  disk.img                # raw GPT: p1 ESP (vfat32) + p2 root (ext4)
  disk.qcow2              # qemu-img convert -O qcow2 of disk.img
  esp/                    # ESP staging tree
    EFI/BOOT/BOOTX64.EFI  # grub-mkstandalone, config embedded
    boot/grub/grub.cfg    # copy of the embedded config (disk builds)
  grub.cfg                # disk GRUB config, or the live ISO config in
                          #   iso-only mode (artifact boot.grub.config / ISO cfg)
  artifact.json           # sysemble/artifact/v1 manifest (boot.mode = iso,
                          #   install, or uefi; desktop + graphical fields when a
                          #   DM is planned)
  build.log               # full build output (tee)
  plan.copy.json          # byte-identical copy of the input plan
```

ISO-only builds produce only `rootfs/`, `live.iso`, `iso/`, `artifact.json`,
`build.log`, `plan.copy.json`, plus the `esp/`/`grub.cfg` staging files.
`--installer` additionally bakes the installer script/unit into `rootfs/`
(`usr/local/sbin/sysemble-install`, `etc/systemd/system/sysemble-install.service`
and its `multi-user.target.wants` symlink), but still produces only `live.iso`
as the image. `--installer-tui` bakes the same files plus
`etc/systemd/system/sysemble-install.service.d/tui-cmdline.conf`, a drop-in
that makes the unchanged unit start for either installer cmdline marker.
`<out>/esp.img` (the FAT32 image merged into `disk.img`) and `<out>/efi.img`
(the temporary 8 MiB live EFI image) are intermediates and are removed after
their consumers succeed. For an iso+disk plan the live ISO uses a private
`<out>/iso-staging/` tree so it cannot overwrite the disk `esp/` and
`grub.cfg`.

On failure, `rootfs/`, `disk.img` (if built), the `iso/` tree, `esp/`,
`grub.cfg`, and `build.log` are kept for diagnosis; `esp.img`, `efi.img`, a
half-written `disk.qcow2` or `live.iso`, and the artifact temp file are removed.
`disk.img` is deliberately kept by P0-c: it may already hold a valid GPT/ext4
partition when a later GRUB/mcopy/dd/qemu-img step failed.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Dry run succeeded, or a complete native image build finished. |
| 1 | Invalid plan: malformed JSON, failed plan validation, or `plan.spec` missing for a real native build. |
| 2 | Usage or I/O error, including an unsafe `--out`, `--dry-run` + `--execute`, `--engine docker` + `--execute`, or `--installer` without an ISO-only plan. |
| 3 | Native engine unavailable: not Linux, not root, or a tool required by the requested outputs is missing. ISO-only needs `mmdebstrap`, `mkfs.vfat`, `mcopy`, `grub-mkstandalone`, `mksquashfs`, and `xorriso`; disk builds add `mkfs.ext4`, `qemu-img`, `sgdisk`, and `dd`. |
| 4 | Docker engine unavailable: no `docker` CLI, or `docker info` failed/timed out. |
| 5 | No JSON parser: neither `jq` nor `python3` is available. |
| 6 | A build step failed, `<out>/rootfs` (or an output image) already exists, an artifact input is missing, or the rootfs has no kernel/initrd. |

Every unmet native preflight requirement is reported one line at a time, then
the script exits 3. It never calls `sudo`.

## Dry run

```console
$ bash builders/debian/build.sh \
    --plan /tmp/min-plan.json --out /tmp/sysemble-dry --dry-run
Sysemble Debian builder - dry run (P0-d3)
  ...
  outputs:    qcow2
  build mode: disk
Stages (planned):
  [1/6] validate          plan structure is valid
  [2/6] fetch base        debian/trixie
  [3/6] bootstrap rootfs  mmdebstrap --variant=minbase
  [4/6] install packages  14 packages via --include
  [5/6] configure         not implemented in P0-a
  [6/6] assemble image    not implemented in P0-a (requested: qcow2)
...
Dry run complete: no image was built.
```

The six-stage block is unchanged for disk plans (P0-a/P0-c regression); an
ISO plan adds a `build mode: iso` line, lists the builder-added live packages,
and describes the live ISO in stage 6. The dry run **does not check the
engine**, so it works on macOS/Windows hosts without Linux, root, mmdebstrap,
the UEFI/ISO toolchain, or Docker. It validates the plan first and leaves
nothing behind except `<out>/plan.copy.json`.

## Plan input

The P0 plan contract (`docs/plan/P0-workplan.md` §2.1) is the authority. The
builder requires:

| Field | Requirement |
|---|---|
| `apiVersion` | String, exactly `sysemble/plan/v1`. |
| `base.kind` | String, exactly `debian` (this is the Debian builder). |
| `base.release` | Non-empty string, characters `[A-Za-z0-9._-]`, starting alphanumeric. |
| `target.arch` | `x86_64` or `aarch64`. |
| `target.outputs` | Non-empty array of non-empty strings (e.g. `["qcow2", "iso"]`). |
| `packages` | Non-empty array of Debian package names (`[a-z0-9]` start, then `[a-z0-9+.:-]`). |

Optional fields:

| Field | Use |
|---|---|
| `spec` | Spec name (`meta.name`). Displayed in the dry run, written to `artifact.spec`, and sanitized into `/etc/hostname` for the real build. Required for a native `--execute` build. |
| `base.pin` | Snapshot date/digest; copied to `artifact.base.pin` (`null` if absent). **Not applied** to the mirror. |
| `modules` | Displayed as `id@version`; no module hooks run. |
| `estimates.*` | Printed in the dry-run estimates block only; not used for disk sizing. |
| `warnings` | Displayed as `code: message`; the builder does not fail on warnings. |

`builders/debian/testdata/plan.example.json` is a self-contained fixture (43
packages, 9 modules, no warnings) regenerated from `sysemble plan` on the
Debian example. Its `linux-image-amd64` package and `x86_64` architecture make
it an x86_64 plan. `builders/debian/testdata/plan.no-desktop.json` is the
minimal 14-package counterpart used for the P0-d1 no-DM regression: it contains
no `gdm3`/`sddm`/`lightdm`, so the builder must keep the multi-user cmdline.

JSON is read with `jq` when available, otherwise with `python3 -c`. Both
backends emit the same validated record stream; the dry-run output is identical
for the same plan. If neither tool exists, the script exits 5 before creating
`<out>`.

## Native engine (`--execute`)

Preflight requires `uname -s` = `Linux`, euid 0, and the tools needed by the
requested outputs:

| Stage | Required tools |
|---|---|
| All builds | `mmdebstrap` (rootfs bootstrap) |
| Shared boot image | `mkfs.vfat` (dosfstools), `mcopy` (mtools), `grub-mkstandalone` (grub-efi-amd64-bin) |
| Disk only (or iso+disk) | `mkfs.ext4` (e2fsprogs with `-d` and `-E offset=`), `qemu-img`, `sgdisk` (gdisk), `dd` |
| ISO only (or iso+disk) | `mksquashfs` (squashfs-tools), `xorriso` |

On Debian/Ubuntu the package set is:

```
# disk builds
mmdebstrap e2fsprogs qemu-utils gdisk dosfstools mtools \
grub-efi-amd64-bin grub-common
# add for live ISO builds
xorriso squashfs-tools
```

ISO-only plans do not require `sgdisk`, `mkfs.ext4`, `qemu-img`, or `dd`; the
preflight reports only the missing tools for the selected mode. The build then
runs:

```bash
DEBIAN_FRONTEND=noninteractive \
mmdebstrap --variant=minbase --include=<comma-separated packages> \
  --customize-hook=<hostname + serial-getty hook> \
  <base.release> <out>/rootfs

# P0-c1 GPT + ESP + GRUB/UEFI assembly (loop-free: no loop devices)
truncate -s <size_mb>M <out>/disk.img
sgdisk -Z <out>/disk.img
sgdisk -n 1:2048:+512M -t 1:ef00 -n 2:0:0 -t 2:8300 <out>/disk.img
mkfs.ext4 -F -b 4096 -E offset=$((513*1024*1024)) \
  -d <out>/rootfs -L SYMBLE <out>/disk.img <root-fs-blocks>

mkfs.vfat -F 32 -C -n ESP <out>/esp.img 524288
# write <out>/grub.cfg and stage <out>/esp/boot/grub/grub.cfg
grub-mkstandalone -O x86_64-efi -o <out>/esp/EFI/BOOT/BOOTX64.EFI \
  --modules="part_gpt part_msdos fat ext2 normal linux search search_fs_uuid configfile serial terminal echo test" \
  "boot/grub/grub.cfg=<out>/esp/boot/grub/grub.cfg"
mcopy -i <out>/esp.img -s <out>/esp/EFI ::/
dd if=<out>/esp.img of=<out>/disk.img bs=1M seek=1 conv=notrunc
rm -f <out>/esp.img

qemu-img convert -O qcow2 <out>/disk.img <out>/disk.qcow2
```

An ISO plan additionally (and, when ISO-only, instead) runs:

```bash
# P0-d2 live ISO (UEFI El Torito)
mksquashfs <out>/rootfs <out>/iso/live/filesystem.squashfs -comp zstd -noappend
cp <out>/rootfs/boot/vmlinuz-<ver>      <out>/iso/live/vmlinuz
cp <out>/rootfs/boot/initrd.img-<ver>   <out>/iso/live/initrd.img

grub-mkstandalone -O x86_64-efi -o <out>/esp/EFI/BOOT/BOOTX64.EFI \
  --modules="part_gpt part_msdos fat iso9660 normal linux search search_fs_file configfile serial terminal echo test" \
  "boot/grub/grub.cfg=<out>/grub.cfg"
mkfs.vfat -C -n EFI <out>/efi.img 8192
mcopy -i <out>/efi.img -s <out>/esp/EFI ::/
cp <out>/efi.img <out>/iso/boot/grub/efi.img
xorriso -as mkisofs -R -J -joliet-long -V SYMBLE -o <out>/live.iso \
  -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
  -isohybrid-gpt-basdat <out>/iso
rm -f <out>/efi.img
```

The ISO `--include` list additionally gains
`,live-boot,live-boot-initramfs-tools` (deduplicated against the plan); the
customize hook runs `update-initramfs -u -k all` in the chroot so the
live-boot hook is definitely present in the initrd. For an iso+disk plan the
GRUB config/ESP live under `<out>/iso-staging/`, so the disk `esp/` and
`grub.cfg` remain the P0-c artifacts.

For a graphical plan the `--include` list gains
`,xserver-xorg,procps,accountsservice` and the customize hook also
installs/enables the boot evidence unit described above.

All stage messages and all command stdout/stderr are teed to
`<out>/build.log`.

### Partitions and loop-free assembly

| Partition | Start | Size | Type | FS | Label |
|---|---|---|---|---|---|
| 1 | 1 MiB (LBA 2048) | 512 MiB | `ef00` EFI System | FAT32 | `ESP` |
| 2 | 513 MiB | rest of disk | `8300` Linux | ext4 | `SYMBLE` |

`sgdisk -n 1:2048:+512M` puts p2 at sector 1050624 = 513 MiB. The root ext4 is
written **at a byte offset** with `mkfs.ext4 -E offset=537919488` instead of a
loop device, and the FAT32 ESP is built in `esp.img` and merged with
`dd seek=1`. This works in containerized CI runners where loop devices are not
guaranteed. The ESP is written at 1 MiB, after the GPT header/entries, so the
partition table is not overwritten.

**Explicit ext4 size (one deliberate addition to the frozen workplan command):**
without a positional block count, mke2fs sizes the filesystem to
`end-of-file - offset` and even prints
`Warning: offset specified without an explicit file system size`.
That filesystem is slightly larger than GPT partition 2, because the last 33
sectors of the disk hold the backup GPT, and the kernel refuses to mount an
ext4 filesystem whose block count exceeds the partition size
(`bad geometry: block count N exceeds size of device`). The builder therefore
passes `-b 4096` plus `compute_root_fs_blocks(disk_mb) = (disk_mb - 513 - 1) * 256`,
i.e. the root filesystem ends 1 MiB before the end of the disk, inside p2 and
clear of the backup GPT. All frozen `mkfs.ext4` semantics (offset, `-d`, label)
are unchanged; only an explicit block size and size are added. For the 4096 MB floor this is 916992 4 KiB blocks
(3582 MiB).

### Disk sizing

```text
size_mb = max(4096, ceil((rootfs_mb * 1.6 + 1024) / 256) * 256)
```

Integer-only implementation (`(8*rootfs_mb + 5120 + 1279) / 1280 * 256`),
bash 3.2 compatible. Examples: 500 MB rootfs → 4096 MB (floor); 1000 MB → 4096
MB (floor); 1920 MB → 4096 MB; 2000 MB → 4352 MB; 3000 MB → 5888 MB;
4096 MB → 7680 MB; 5000 MB → 9216 MB.

`disk.img` is created by `truncate`; unused blocks stay sparse until the
filesystems and qcow2 conversion read them.

### GRUB configuration

`grub_cfg_text()` renders the frozen P0-c config:

```grub
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

When `plan.packages` contains a display manager, the single `linux` line
instead uses the P0-d1 desktop cmdline:

```grub
  linux /boot/vmlinuz-<ver> root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=graphical.target systemd.journald.forward_to_console=1
```

`systemd.journald.forward_to_console=1` is required for the desktop boot check:
LightDM and Xorg log through journald, so without it their messages never reach
the serial console. The exact same string is written to `artifact.boot.cmdline`;
the tests compare both byte for byte. A no-DM plan does not gain the journald
flag, keeping the P0-c cmdline byte-identical.

`<ver>` is the basename of the highest-versioned `vmlinuz-*` / `initrd.img-*`
found under `rootfs/boot` with `sort -V` (for example `6.12.3-amd64`). The same
text is written to `<out>/grub.cfg`, staged at
`<out>/esp/boot/grub/grub.cfg`, and embedded into `BOOTX64.EFI` by
`grub-mkstandalone`; no external `/boot/grub` directory is needed at boot time.

### Live ISO assembly (P0-d2)

`plan.target.outputs` is interpreted by `plan_build_mode()`:

| Outputs | Mode | What runs |
|---|---|---|
| contains `iso`, no `qcow2`/`raw` | `iso` | only the live ISO stage; no disk/partition/ESP/GRUB-disk work |
| contains `iso` and `qcow2`/`raw` | `iso-disk` | the P0-c/d1 disk stage and the live ISO stage |
| no `iso` | `disk` | frozen P0-c/d1 disk stage (also the default when no plan outputs are loaded) |

The ISO tree is:

```
<out>/iso/
  live/vmlinuz                 # composed from rootfs/boot/vmlinuz-<ver>
  live/initrd.img              # composed from rootfs/boot/initrd.img-<ver>
  live/filesystem.squashfs     # mksquashfs <out>/rootfs ... -comp zstd -noappend
  boot/grub/efi.img            # 8 MiB FAT: EFI/BOOT/BOOTX64.EFI
```

The live GRUB config (`iso_grub_cfg_text()`) is frozen as:

```grub
# P0-d2 live ISO: source kernel=vmlinuz-<ver> initrd=initrd.img-<ver>
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

The comment records the actual rootfs kernel/initrd versions; the boot lines
use the stable live paths. A desktop plan switches the cmdline to
`graphical.target` (same journald forwarding) and adds `desktop` +
`boot.graphical=true`/`memory_mb=2048` to the artifact.

The EFI image is built with `grub-mkstandalone -O x86_64-efi` using the frozen
ISO module list (`part_gpt part_msdos fat iso9660 normal linux search
search_fs_file configfile serial terminal echo test`) and the embedded
`boot/grub/grub.cfg=<cfg>` argument, then formatted with
`mkfs.vfat -C -n EFI <out>/efi.img 8192`, populated with
`mcopy -i <out>/efi.img -s <out>/esp/EFI ::/`, and copied to
`iso/boot/grub/efi.img`. `xorriso -as mkisofs` then writes the UEFI El Torito
ISO:

```bash
xorriso -as mkisofs -R -J -joliet-long -V SYMBLE -o <out>/live.iso \
  -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
  -isohybrid-gpt-basdat <out>/iso
```

The ISO adds `live-boot`/`live-boot-initramfs-tools` to `--include`
(deduplicated against plan packages; `artifact.packages` stays the plan list)
and the customize hook runs `update-initramfs -u -k all` so the live-boot hook
is present in `initrd.img`. For an iso+disk plan the live GRUB config and ESP
live under `<out>/iso-staging/` to keep the disk `grub.cfg`/`esp/` intact.

`tools/boot-check.sh` reads `boot.mode="iso"`, attaches `boot.iso` with
`-cdrom` (no disk), and asserts firmware, GRUB, kernel, systemd, login, and the
live markers (`live-boot`/`live-media`/`squashfs`).

### Unattended installer ISO (P0-d3)

`--installer` keeps the P0-d2 live ISO pipeline but makes the ISO self-install
to a disk. It is accepted **only** for an ISO-only plan (`target.outputs`
contains `iso` and no `qcow2`/`raw`); an iso+disk or disk-only plan exits 2 so
the artifact can never claim `boot.mode="install"` while also carrying disk
images.

The customize hook bakes these files into the live rootfs:

```
/usr/local/sbin/sysemble-install                         0755
/etc/systemd/system/sysemble-install.service
/etc/systemd/system/multi-user.target.wants/sysemble-install.service -> ../sysemble-install.service
```

`--include` additionally receives `rsync grub-efi-amd64 grub-efi-amd64-bin
dosfstools gdisk e2fsprogs` (deduplicated against the plan and the live/desktop
runtime lists; `artifact.packages` stays the plan list). The systemd unit is
frozen by `docs/plan/P0-d3-workplan.md`:

```ini
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

The ISO GRUB cmdline appends `sysemble.install=/dev/vda`, so the unit starts in
the live system (and never after the installed reboot: the installed GRUB
cmdline does not contain the parameter). The installer script then:

1. parses `/proc/cmdline` (`sysemble.install=`, default `/dev/vda`); refuses
   non-`/dev` paths, non-block devices, optical/loop devices, the live medium,
   and any device/partition already mounted;
2. writes the frozen GPT: `sgdisk -Z`, `-n 1:2048:+512M -t 1:ef00`,
   `-n 2:0:0 -t 2:8300`;
3. formats `mkfs.vfat -F 32 -n ESP <dev>1` and
   `mkfs.ext4 -F -L SYMBLE <dev>2`;
4. mounts root at `/mnt`, ESP at `/mnt/boot/efi`, and bind-mounts `/proc`,
   `/sys`, `/dev`, `/run` into the target for the chroot user/password setup;
5. copies the live root with
   `rsync -aHAX --exclude={/proc,/sys,/dev,/run,/tmp,/mnt,/media,/live,/lost+found} / /mnt/`;
6. writes `/etc/fstab` from the two UUIDs;
7. writes `/boot/grub/grub.cfg` (`search --fs-uuid`, the installed
   kernel/initrd, `root=UUID=... rw console=ttyS0 systemd.unit=multi-user.target`)
   and builds a **self-contained** EFI binary with
   `grub-mkstandalone -O x86_64-efi --modules="part_gpt fat ext2 normal linux search search_fs_uuid configfile serial terminal echo test" "boot/grub/grub.cfg=/mnt/boot/grub/grub.cfg" -o /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI`.
   The modules and config are embedded, so the firmware fallback
   `EFI/BOOT/BOOTX64.EFI` never tries to load `/boot/grub/x86_64-efi` from the
   root partition (the P0-d3 `grub-install --removable` core did, which caused
   `grub rescue: file '/boot/grub/x86_64-efi/normal.mod' not found`);
8. unmounts, prints `SYMBLE: install complete` to `/dev/ttyS0` via `tee`, and
   runs `systemctl poweroff -f`.

On any failure it prints `SYMBLE: install failed: <reason>` to `/dev/ttyS0`,
leaves the live system running (no poweroff), and exits 1 so the journal and
serial log survive. The script accepts `SYMBLE_CMDLINE_FILE`, `SYMBLE_ROOT`,
`SYMBLE_MNT`, `SYMBLE_CONSOLE`, `SYMBLE_LIVE_MEDIA`, and `--dry-run` for
offline testing; production uses the defaults above.

The installer ISO artifact is ISO-only and headless:

```json
"boot": {
  "mode": "install",
  "iso": "live.iso",
  "install_device": "/dev/vda",
  "cmdline": "boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1 sysemble.install=/dev/vda",
  "memory_mb": 1024
}
```

`images` is still exactly `[{"path":"live.iso","format":"iso",...}]`, and
`partitions` is omitted. The path is always headless: a plan that names a
display manager still gets a multi-user installer ISO (the DM packages stay in
the rootfs, but no graphical target, desktop runtime packages, or boot-evidence
unit is added) and 1024 MB in the artifact. `build.sh` never partitions the
build host and creates no disk image in this mode; the guest installer writes
the target disk. The CI `install-smoke` job boots the ISO with QEMU/OVMF plus a
6 GiB virtio disk, waits for the completion marker, then runs
`tools/boot-check.sh` against the installed disk (mode `uefi`).

### TUI installer ISO (P0-e1)

`--installer-tui` reuses the P0-d3 ISO pipeline, installer script, unit, and
runtime packages. Only the non-interactive preselection changes: the ISO GRUB
cmdline appends `sysemble.install.tui=1` instead of
`sysemble.install=/dev/vda`, and the script (started by the same unit) runs the
serial wizard. The script also auto-detects the marker when invoked without
arguments, so the frozen P0-d3 unit needs no `ExecStart` change.

Because the unit's frozen condition is the single word `sysemble.install`
(systemd does not treat `sysemble.install.tui` as that word), the TUI rootfs
also gets this drop-in; it resets the condition list and ORs both markers with
triggering conditions:

```ini
[Unit]
ConditionKernelCommandLine=
ConditionKernelCommandLine=|sysemble.install
ConditionKernelCommandLine=|sysemble.install.tui
```

The wizard prompts (frozen, expect-friendly) are:

```
SYMBLE-TUI disk [/dev/vda]:
SYMBLE-TUI hostname [sysemble]:
SYMBLE-TUI user [ops]:
SYMBLE-TUI password:
SYMBLE-TUI confirm install to <disk> (yes/no):
```

The password is read with `stty -echo`; an invalid (non-block) disk re-prompts;
a confirmation other than `yes`/`y` cancels with exit 2. The installer script
supports `--disk`, `--hostname`, `--user`, `--password-file`, `--yes`, `--tui`,
`--dry-run`, and `--auto`. Without `--tui` (or a TUI cmdline marker) it stays
unattended. After rsync it writes `/etc/hostname` and `/etc/hosts`, runs
`useradd -m -s /bin/bash -G sudo <user>` (skipped if the user exists), then
`chpasswd` for a non-empty password or `passwd -l` for an empty one.

The TUI artifact is ISO-only and headless; it has no `install_device`:

```json
"boot": {
  "mode": "install",
  "iso": "live.iso",
  "install_tui": true,
  "cmdline": "boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1 sysemble.install.tui=1",
  "memory_mb": 1024
}
```

`tools/tui-install-check.sh` drives the prompts with `expect` and asserts the
installed disk boots with the chosen hostname; CI is the authoritative check.

### Desktop inference (P0-d1)

The builder reads only `plan.packages`; `desktop` in the spec is not required
(and does not reach the builder as a field). Detection is deliberately simple:

| Package in `plan.packages` | Inferred value | Priority |
|---|---|---|
| `gdm3` | `display_manager: "gdm"` | 1 |
| `sddm` | `display_manager: "sddm"` | 2 |
| `lightdm` | `display_manager: "lightdm"` | 3 |
| `plasma-desktop` | `session: "plasma"` | 1 |
| `gnome-shell` | `session: "gnome"` | 2 |
| `xfce4` | `session: "xfce"` | 3 |

- Only the display manager turns graphical mode on. `xfce4` without `lightdm`
  stays multi-user.
- A display manager without any recognized session package still boots
  graphically; `desktop.session` is then `"unknown"`.
- The 18-package XFCE plan (`xfce4`, `lightdm`, `thunar`,
  `xfce4-terminal`, ...) infers `session=xfce`, `display_manager=lightdm`.

A graphical build also adds three packages that the plan does not name:

| Runtime package | Why |
|---|---|
| `xserver-xorg` | `xfce4` and `lightdm` only **Recommend** the X server, and mmdebstrap installs no Recommends. Without it LightDM cannot start Xorg. |
| `procps` | Provides `pgrep` for the boot evidence unit. procps is `Priority: important`, so `--variant=minbase` does not install it. |
| `accountsservice` | Provides `org.freedesktop.Accounts`, which LightDM uses for the greeter user list. It is only a **Suggests** of lightdm, so it is not installed by default. |

These packages are appended to `--include` only for graphical plans.
`artifact.packages` stays the plan package list; no-DM builds keep the exact
P0-c `--include` and multi-user cmdline.

#### Boot evidence unit (graphical only)

LightDM normally sends Xorg's stdout to `/var/log/lightdm/x-0.log`, so
`systemd.journald.forward_to_console=1` alone may not put `X.Org X Server` on
the serial console. A graphical rootfs therefore gets
`/etc/systemd/system/sysemble-boot-evidence.service`, enabled through a
`graphical.target.wants/` symlink:

```ini
[Unit]
Description=Sysemble boot evidence markers
After=graphical.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'i=0; while [ $$i -lt 60 ]; do if pgrep -x Xorg ...; then echo "SYMBLE: Xorg ready" > /dev/ttyS0; break; fi; i=$$((i+1)); sleep 1; done; ... echo "SYMBLE: lightdm ready" ...; true'
TimeoutStartSec=90

[Install]
WantedBy=graphical.target
```

`$$` is required because systemd consumes one `$` in `ExecStart=` environment
substitution; the shell receives the intended `$i` / `$((i+1))` loop. Both
markers are polled once per second for up to 60 seconds. This matters because
`graphical.target` can be reached before LightDM has spawned the greeter/Xorg
session; the P0-d1 CI run showed `SYMBLE: lightdm ready` at 17 s but Xorg
starting only around 23 s. The oneshot exits 0 (trailing `true`) and never
blocks the boot transaction, though a missing marker can keep the unit running
for up to 60 s after the target.

The marker names the real Debian process (`lightdm`, `sddm`, or `gdm3` for the
artifact's `gdm`), so boot-check's existing `boot.xorg` (`Xorg`) and
`boot.display_manager` (`lightdm`/`sddm`/`gdm`) assertions match without
changes. The unit is written and enabled by the `--customize-hook`; no-DM builds
neither install nor enable it. `build.log` records the installed unit.

### Boot images

If no kernel or initrd exists, the build fails with exit 6 and a message naming
the directory; it never emits an artifact with missing boot paths. The UEFI
cmdline is:

```
root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=multi-user.target
```

For a desktop plan it is:

```
root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=graphical.target systemd.journald.forward_to_console=1
```

The frozen partition layout means the root filesystem is always GPT partition 2
of the virtio disk (`/dev/vda2`).

A live ISO uses a different boot chain (OVMF -> El Torito efi.img -> GRUB ->
`/live/vmlinuz`); its cmdline is:

```
boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1
```

and for a desktop plan:

```
boot=live live-media-path=/live console=ttyS0 systemd.unit=graphical.target systemd.journald.forward_to_console=1
```

`live.iso` carries its own kernel, initrd, GRUB config, and squashfs, so
`boot.kernel`/`boot.initrd` are not part of the ISO manifest.

### `artifact.json`

`artifact.json` is `sysemble/artifact/v1`, written atomically (temp file +
rename) only after every image and GRUB output exists. A P0-c build emits:

```json
{
  "apiVersion": "sysemble/artifact/v1",
  "createdAt": "2026-11-23T12:51:57Z",
  "spec": "debian-kde-dev",
  "base": {"kind": "debian", "release": "trixie", "pin": "2026-11-01"},
  "arch": "x86_64",
  "packages": ["apt", "ca-certificates", "..."],
  "rootfs": {"path": "rootfs", "size_mb": 420},
  "images": [
    {"path": "disk.img", "format": "raw", "size_mb": 4096, "sha256": "..."},
    {"path": "disk.qcow2", "format": "qcow2", "size_mb": 900, "sha256": "..."}
  ],
  "desktop": {"session": "plasma", "display_manager": "sddm"},
  "boot": {
    "mode": "uefi",
    "disk": "disk.img",
    "kernel": "rootfs/boot/vmlinuz-6.12.3-amd64",
    "initrd": "rootfs/boot/initrd.img-6.12.3-amd64",
    "graphical": true,
    "memory_mb": 2048,
    "cmdline": "root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=graphical.target systemd.journald.forward_to_console=1",
    "grub": {"efi": "esp/EFI/BOOT/BOOTX64.EFI", "config": "grub.cfg"}
  },
  "partitions": [
    {"index": 1, "role": "esp", "size_mb": 512, "fs": "vfat32"},
    {"index": 2, "role": "root", "size_mb": 3584, "fs": "ext4"}
  ],
  "builder": {"name": "build.sh", "version": "0.1.0"}
}
```

An ISO-only build emits the P0-d2 shape instead (no `partitions`):

```json
{
  "apiVersion": "sysemble/artifact/v1",
  "createdAt": "2026-11-23T12:51:57Z",
  "spec": "minimal-debian-live",
  "base": {"kind": "debian", "release": "trixie", "pin": "2026-11-01"},
  "arch": "x86_64",
  "packages": ["apt", "ca-certificates", "..."],
  "rootfs": {"path": "rootfs", "size_mb": 420},
  "images": [
    {"path": "live.iso", "format": "iso", "size_mb": 780, "sha256": "..."}
  ],
  "boot": {
    "mode": "iso",
    "iso": "live.iso",
    "cmdline": "boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1",
    "memory_mb": 1024
  },
  "builder": {"name": "build.sh", "version": "0.1.0"}
}
```

- `boot.mode` is `"iso"`, `"uefi"`, or `"install"`. P0-b artifacts (and any
  artifact without `boot.mode`) default to `"kernel"`. `boot.install_device`
  is present only for the P0-d3 unattended installer; the P0-e1 TUI variant has
  `boot.install_tui=true` and no `install_device`.
- `desktop` is present only for a UEFI build whose package list contains a
  display manager. It has exactly two fields: `session` (`plasma`/`gnome`/
  `xfce`/`unknown`) and `display_manager` (`gdm`/`sddm`/`lightdm`).
- `boot.graphical` and `boot.memory_mb` are present in UEFI artifacts:
  `true`/`2048` for a desktop plan and `false`/`1024` for a no-DM plan. The
  cmdline uses `graphical.target`/`multi-user.target` to match.
- The historical P0-b kernel fallback (no GRUB outputs) stays unchanged: it has
  no `desktop`, `graphical`, or `memory_mb` fields and keeps the `/dev/vda`
  cmdline. `boot.graphical` is ignored by boot-check in kernel mode.
- `boot.disk` and `boot.grub` are relative to the artifact directory.
  `boot.grub.config` is `<out>/grub.cfg`; the same text is also in
  `esp/boot/grub/grub.cfg`.
- `partitions[].size_mb` follows the frozen sample: ESP 512 and
  root = `disk_mb - 512`. The 1 MiB GPT alignment gap is not charged to a
  partition role. The filesystem created inside p2 is 1 MiB smaller
  (3582 MiB on the 4096 MB floor) so it stays clear of the backup GPT; the
  partition itself still spans the rest of the disk.
- An ISO artifact lists `live.iso` with `"format": "iso"`; ISO-only builds
  have exactly that one image and omit `partitions`. An iso+disk artifact keeps
  `boot.mode="iso"` (the ISO is the primary boot path) and adds the raw/qcow2
  images plus the P0-c `partitions` array.
- A desktop ISO plan keeps the P0-d1 `desktop` object and
  `boot.graphical=true`/`memory_mb=2048`; no-DM ISO artifacts omit both
  `desktop` and `boot.graphical`.
- `images` still contains actual file sizes rounded up to MiB and SHA-256
  digests (`sha256sum`, `shasum -a 256`, or `openssl dgst -sha256`).
- The artifact helper falls back to the historical P0-b direct-kernel shape (no
  `boot.mode`, no `disk`, no `grub`, no `partitions`, no `desktop`, no
  `graphical`/`memory_mb`, `/dev/vda` cmdline) when neither GRUB output exists,
  and refuses to guess when only one exists.

### Failure behavior

- `mmdebstrap` failure: the partial `rootfs/` (if any) and `build.log` are
  kept; no disk images are created.
- Any later disk failure (missing kernel/initrd, `truncate`, `sgdisk`,
  `mkfs.ext4`, `mkfs.vfat`, GRUB config rendering, `grub-mkstandalone`,
  `mcopy`, `dd`, `qemu-img`, hashing, manifest write): `rootfs/`, `disk.img`,
  `esp/`, `grub.cfg`, and `build.log` are kept; `esp.img`, a half-written
  `disk.qcow2`, and `.artifact.json.tmp` are removed by the EXIT trap.
- Any ISO failure (`mksquashfs`, kernel/initrd copy, ISO GRUB rendering,
  `grub-mkstandalone`, `mkfs.vfat`, `mcopy`, `xorriso`, hashing, manifest
  write): `rootfs/`, the whole `iso/` tree, `esp/`, `grub.cfg`, and
  `build.log` are kept; a half-written `live.iso`, the temporary `efi.img`,
  and `.artifact.json.tmp` are removed. The squashfs is kept so a failed
  xorriso invocation can be diagnosed without re-bootstrapping.
- `<out>/rootfs`, `<out>/live.iso`, or (for disk outputs) `<out>/disk.img` /
  `<out>/disk.qcow2` already existing: refuse to overwrite and exit 6. Stale
  `esp/`, `esp.img`, `grub.cfg`, `iso/`, `iso-staging/`, or `efi.img` left by
  an interrupted attempt are removed before the retry (they can only be
  derived intermediates once the rootfs and final images are absent). Because
  `disk.img` is intentionally kept after a failure, retrying into the same
  `<out>` requires removing it (and `rootfs/`, if present) manually first.
- Interrupts (`HUP`/`INT`/`TERM`) run the same EXIT cleanup.

## Docker engine

Preflight requires the `docker` CLI and a successful `docker info`, wrapped in a
20-second watchdog so a wedged daemon cannot hang the script. A missing CLI or
unreachable daemon prints a diagnostic and exits 4.

Docker mode is still **P0-a scope**: it installs mmdebstrap in a
`debian:trixie` container and bootstraps `/out/rootfs`, then stops with a
warning. It does **not** produce `disk.img`, `disk.qcow2`, `esp/`, `live.iso`,
or `artifact.json`; that assembly path is native-only and **P0-c/P0-d2
unverified**.
Passing `--execute` with `--engine docker` is rejected with exit 2 instead of
returning a rootfs-only "success". Do not use Docker mode for the boot-smoke
acceptance.

- `--privileged` is required because mmdebstrap needs mount/chroot inside the
  container. Only `<out>` is bind-mounted and the container is removed with
  `--rm`; the host filesystem is not exposed.
- `--out` must not contain `:` (Docker bind-mount syntax); the script rejects
  such a path with exit 6.
- The container runs on the host architecture; `target.arch` is not applied.

## Safety properties

- `set -euo pipefail`; no `eval`, no `sudo`, no host package installation.
- `--out` is rejected if it is empty, `/`/`//`/`///`, an existing non-directory,
  or a symlink resolving to `/`. The canonical path is checked again after
  `mkdir -p`, before any write.
- Dry run writes only `<out>/plan.copy.json`; real builds additionally write
  the outputs listed above. Transient record/diagnostic files live under
  `$TMPDIR` and are removed on exit.
- `plan.copy.json`, `grub.cfg`, and `artifact.json` are written with a temporary
  file plus rename, so pre-existing symlinks/hardlinks cannot redirect writes
  outside `<out>`.
- The rootfs target and existing disk/ISO images are never deleted or overwritten.
- Temporary files live in `$TMPDIR` (or `/tmp`) under `sysemble-build.*` and are
  removed by an EXIT trap. The trap only deletes paths matching that prefix.
- On failure, cleanup only deletes derived intermediates created by this build;
  it never deletes a pre-existing `rootfs/` or image.
- No loop devices, mounts, or host block devices are used.
- Docker mode bind-mounts only `<out>`; no Docker socket or host directories.

## Not implemented through P0-e1

- Calamares or any installer GUI (P0-e2); desktop *configuration* (theme,
  apps, users, autologin) beyond installing the session packages and letting
  the display manager start. The P0-e1 TUI installer creates one user,
  writes hostname/hosts, and sets or locks that user's password; first-boot
  setup beyond that is out of scope.
- BIOS boot, persistence, secure boot signing, dm-verity, and PXE assembly.
  (P0-d2 implements UEFI live ISO assembly; P0-d3 implements unattended
  install to `/dev/vda`, not a reproducible installer image or Calamares.)
- Cross-architecture UEFI: `grub-mkstandalone -O x86_64-efi` is x86_64 only;
  `target.arch` is validated but the native build uses the host toolchain.
- System configuration beyond `/etc/hostname` and the serial getty enable:
  locale, timezone, keyboard, users, passwords, services, networking, kernel
  cmdline customization.
- Module hooks and per-module package layering (modules are display-only).
- Snapshot pinning (`base.pin` is copied into the artifact but the build uses
  the live mirror), reproducible timestamps, SBOM, signatures.
- Build cache, resume, build locking, and automatic retry.
- Docker disk/artifact assembly (rootfs bootstrap only).
- Real native build verification on the development host: macOS arm64 has no
  Linux, root, mmdebstrap, sgdisk, mkfs.*, mtools, grub, or qemu. The command
  path is covered by offline tests with a fake toolchain; the real path is only
  exercised by CI.

## Known risks (tracked by P0-c/P0-d1/P0-d2/P0-d3/P0-e1)

1. `grub-mkstandalone`'s module set or embedded-config argument may need
   adjustment on the CI runner; the build.log from the first CI run is the
   authority.
2. GRUB must see the virtio disk as `(hd0,gpt2)`. If the CI boot log shows a
   different device name, the frozen config must switch to
   `search --fs-uuid` (P0-c workplan risk 5). Local tests only prove the text.
3. OVMF firmware paths differ by distribution; `tools/boot-check.sh` probes
   several paths and accepts `--firmware`. This builder does not install OVMF.
4. `mkfs.ext4 -E offset=` with `-d` requires e2fsprogs ≥ 1.47; the Ubuntu
   runner satisfies this. `-b 4096` plus the explicit block count keep the
   filesystem inside p2 and clear of the backup GPT.
5. The 512 MiB ESP is larger than needed; it is kept for safety and can be
   reduced later.
6. Booting with `rw` modifies `disk.img`, so the artifact SHA-256 describes the
   pre-boot image (P0-c still does not solve post-boot digest staleness).
7. The desktop path assumes the Debian display-manager package enables its
   `display-manager.service` symlink during `mmdebstrap` (lightdm/sddm/gdm3 do
   this in their postinst). If the CI boot log reaches multi-user without a DM,
   the customize hook must enable it explicitly.
8. P0-d2 `live-boot` + `live-media-path=/live` behavior on Debian trixie must
   be verified by the `live-smoke` job. `live-boot` +
   `live-boot-initramfs-tools` are installed explicitly and the customize hook
   regenerates the initramfs with `update-initramfs -u -k all`; if the CI log
   still shows the initramfs emergency shell, inspect the initrd contents and
   the live-boot hook.
9. The corrected cmdline (P0-d2 workplan §9) uses `live-media-path=/live`:
   live-boot discovers `/live/filesystem.squashfs` on the boot medium itself.
   The CI boot log is the authority; on failure inspect whether live-boot
   detected the CD-ROM and the `/live` directory.
10. OVMF booting the El Torito EFI image is sensitive to the `efi.img` layout
    and the `-e boot/grub/efi.img`/`-isohybrid-gpt-basdat` options. The ISO
    tree and `build.log` are kept on failure; verify the FAT image contains
    `EFI/BOOT/BOOTX64.EFI` and that xorriso reports the EFI boot entry.
11. The ISO is 8 MiB FAT and UEFI-only: no BIOS El Torito entry, no Secure
    Boot signing, no persistence partition. Squashfs zstd needs the Debian
    kernel's zstd support (it has it); TCG live boot can be slower than disk,
    hence the 600 s boot-check timeout.
12. QEMU runs with TCG on GitHub-hosted runners; Xorg on `-vga virtio` may be
   slow or fail to start. `systemd.journald.forward_to_console=1` is what makes
   the LightDM/Xorg failure (or success) visible in `boot.log`; the P0-d1
   workplan allows falling back to `-vga std` or `nomodeset` if needed.
   The boot evidence unit polls Xorg/display-manager processes for up to 60 s
   after `graphical.target` and prints `SYMBLE:` markers, which is more reliable
   than parsing LightDM's redirected Xorg log. `TimeoutStartSec=90` bounds the
   start job; if Xorg never appears, `boot.xorg` still fails and the usual five
   boot assertions report the failure.
13. P0-d3 rsync copies ~1 GB from the live overlay to the emulated virtio disk
    under TCG; this can take 5–15 minutes. The systemd unit allows 1800 s and
    the CI install job budgets 40 minutes. If the job times out, reduce the
    rootfs package set or raise the job timeout; do not shorten
    `TimeoutStartSec` below the observed install time.
14. The installed ESP gets a self-contained `grub-mkstandalone` binary at
    `EFI/BOOT/BOOTX64.EFI` with the module set and grub.cfg embedded; it no
    longer relies on `grub-install --removable` or a `/boot/grub/x86_64-efi`
    directory on the root partition. The `/proc`, `/sys`, `/dev`, and `/run`
    bind mounts are kept for the chroot user/password setup and are always
    unmounted, including on error. The real OVMF handoff is only proved by CI;
    local tests assert the EFI target path, module list, and embedded cfg text.
15. The installer targets `/dev/vda` (frozen). A different device can be passed
    on the live cmdline (`sysemble.install=/dev/...`), but only whole disks with
    predictable `<dev>1`/`<dev>2` (or nvme/mmcblk `p1`/`p2`) names are
    supported. LUKS, LVM, RAID, multi-disk, and a GUI/first-boot flow are out of
    scope for P0-d3.
16. The TUI wizard reads/writes `/dev/ttyS0` directly and stops
    `serial-getty@ttyS0.service` first. A getty restarting concurrently, a
    different serial device, or a non-serial console can race or hide the
    prompts; the `expect`-driven CI check is the authority. If no ttyS0 terminal
    exists the script falls back to stdin/stdout (used by local pipe tests).
17. The TUI condition drop-in relies on systemd's empty-assignment reset and
    triggering-condition (`|`) syntax (documented and supported by trixie's
    systemd). The real install path, the dropped getty, and the password
    prompt's `stty` handling are only verified by CI; the offline tests prove
    command assembly and dry-run behavior.
18. `chpasswd` receives `user:password` verbatim. A password containing a colon
    or newline is out of scope for P0-e1 (the CI smoke test uses a simple
    password); `--password-file` reads only the first line.

## Local checks

```bash
bash -n builders/debian/build.sh
bash -n builders/debian/lib.sh
bash -n builders/debian/installer/sysemble-install.sh
bash -n builders/debian/tests/artifact_test.sh
bash -n builders/debian/tests/build_exec_test.sh
bash -n builders/debian/tests/installer_test.sh

# Plan fixture / dry-run regression
bash builders/debian/build.sh \
  --plan builders/debian/testdata/plan.example.json \
  --out /tmp/sysemble-dry --dry-run

# Live ISO plan (the P0-d2 example) dry run
cargo run -q -p sysemble-cli -- plan examples/minimal-debian-live.yaml > /tmp/live-plan.json
bash builders/debian/build.sh --plan /tmp/live-plan.json --out /tmp/p0d2-dry --dry-run

# Offline artifact manifest tests (fixture rootfs + real sha256)
bash builders/debian/tests/artifact_test.sh        # 131 checks

# Offline native --execute command-sequence tests (fake disk + ISO toolchain)
bash builders/debian/tests/build_exec_test.sh      # 312 checks

# Offline installer static + dynamic dry-run tests (no partition/mount)
bash builders/debian/tests/installer_test.sh       # 201 checks

# Installer ISO dry run (P0-d3)
bash builders/debian/build.sh --plan /tmp/live-plan.json \
  --out /tmp/p0d3-dry --dry-run --installer

# TUI installer ISO dry run (P0-e1)
bash builders/debian/build.sh --plan /tmp/live-plan.json \
  --out /tmp/p0e1-dry --dry-run --installer-tui

# On macOS, without --dry-run, the native preflight is expected to exit 3
bash builders/debian/build.sh \
  --plan builders/debian/testdata/plan.iso.json \
  --out /tmp/sysemble-native-iso
```

`builders/debian/testdata/` contains the contract-shaped fixtures:

| Fixture | Outputs | Use |
|---|---|---|
| `plan.example.json` | `["qcow2","iso"]` | CLI/fixture dry-run checks |
| `plan.disk.json` | `["qcow2"]` | P0-c/P0-d1 disk regression |
| `plan.no-desktop.json` | `["qcow2"]` | P0-d1 no-DM regression |
| `plan.iso.json` | `["iso"]` | P0-d2 iso-only build tests |
| `plan.iso-disk.json` | `["qcow2","iso"]` | P0-d2 iso+disk build tests |
| `plan.iso-desktop.json` | `["iso"]` | P0-d2 desktop ISO (sddm/plasma) tests |

The real-plan dry run uses the CLI:

```bash
cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml > /tmp/min-plan.json
bash builders/debian/build.sh --plan /tmp/min-plan.json --out /tmp/sysemble-dry --dry-run
```

The tests do **not** prove that the real commands work: they prove command
assembly, argument order/content, GRUB config text, hook text, artifact shape,
log tee, mode-aware preflight, failure cleanup, and the installer's static
command sequence plus its `--dry-run` ordering/markers. The authoritative real
builds are the CI `boot-smoke` (disk), `live-smoke` (ISO), and `install-smoke`
(installer ISO → installed disk) jobs.

On a macOS host without the UEFI/ISO toolchain, `build.sh --execute` exits 3
and reports every missing item for the requested mode. For an ISO-only plan
that is `mksquashfs` and `xorriso` plus the shared `mkfs.vfat`, `mcopy`, and
`grub-mkstandalone`; `sgdisk`, `mkfs.ext4`, `qemu-img`, and `dd` are not
required.

## CI contract

The disk jobs install `mmdebstrap qemu-system-x86 qemu-utils e2fsprogs gdisk
dosfstools mtools grub-efi-amd64-bin grub-common ovmf` on `ubuntu-latest`, then
run:

```bash
cargo run -p sysemble-cli -- plan examples/minimal-debian.yaml > plan.json
sudo -E bash builders/debian/build.sh --plan plan.json --out /tmp/out --execute
bash tools/boot-check.sh --artifact /tmp/out/artifact.json --timeout 300
```

Expected evidence on success: `rootfs/`, `disk.img` (GPT + ESP + GRUB EFI),
`disk.qcow2`, `esp/`, `grub.cfg`, `artifact.json`, `build.log`, then a
`boot.log` containing the firmware banner, `GRUB`, `Linux version`,
`systemd[1]`/`Reached target`, and `login:`.

The P0-d2 `live-smoke` job adds `xorriso squashfs-tools`, plans
`examples/minimal-debian-live.yaml`, and runs the same build/boot-check pair:

```bash
cargo run -p sysemble-cli -- plan examples/minimal-debian-live.yaml > plan.json
sudo -E bash builders/debian/build.sh --plan plan.json --out /tmp/out --execute
bash tools/boot-check.sh --artifact /tmp/out/artifact.json --timeout 600
```

Expected evidence: only `live.iso` (plus `rootfs/`, `iso/`, `esp/`,
`grub.cfg`, `artifact.json`, `build.log`); boot-check attaches the ISO with
`-cdrom` and asserts firmware, GRUB, kernel, systemd, login, and `live-boot`/
`live-media`/`squashfs` (any of the live markers).

The P0-d3 `install-smoke` job reuses the P0-d2 ISO toolchain and builds the
installer variant, then runs the two-phase install check (install marker, then
UEFI boot of the installed 6 GiB disk):

```bash
cargo run -p sysemble-cli -- plan examples/minimal-debian-live.yaml > plan.json
sudo -E bash builders/debian/build.sh --plan plan.json --out /tmp/out --execute --installer
sudo chown -R "$(id -u):$(id -g)" /tmp/out
bash tools/install-check.sh --artifact /tmp/out/artifact.json --timeout 1200 --json
```

Expected evidence: only `live.iso` (no `disk.img`), a serial install log with
`SYMBLE: install complete`, and a `boot-evidence-install` artifact whose
`phases.boot.assertions` show the installed disk passing the five UEFI
assertions. The installer script, unit, and packages are inside the ISO; the
build host is never partitioned.

The P0-e1 `tui-install-smoke` job builds with `--installer-tui` and drives the
serial wizard with `expect` (default disk, hostname, user, password, `yes`):

```bash
cargo run -p sysemble-cli -- plan examples/minimal-debian-live.yaml > plan.json
sudo -E bash builders/debian/build.sh --plan plan.json --out /tmp/out --execute --installer-tui
sudo chown -R "$(id -u):$(id -g)" /tmp/out
bash tools/tui-install-check.sh --artifact /tmp/out/artifact.json \
  --hostname sysemble-tui --timeout 1200 --json
```

Expected evidence: only `live.iso`, a serial install log containing all five
`SYMBLE-TUI` prompts and `SYMBLE: install complete`, then a boot of the installed
disk whose login prompt is `sysemble-tui login:`.

## Files

| File | Role |
|---|---|
| `build.sh` | CLI, output directory handling, dry run, mode-aware native GPT/ESP/GRUB/UEFI and live ISO pipelines, the P0-d3/P0-e1 installer ISO, docker rootfs bootstrap. |
| `lib.sh` | JSON backends, record parsing, plan validation, mode-aware preflight, disk sizing, disk/ISO GRUB rendering, P0-d1 desktop inference/runtime packages/boot evidence unit, P0-d2 ISO + P0-d3/P0-e1 installer artifact helpers, usage text. |
| `installer/sysemble-install.sh` | Guest installer: unattended backend + serial TUI wizard; GPT + ESP/ext4, rsync root, fstab, hostname/hosts/user/password, self-contained `grub-mkstandalone` EFI with embedded cfg, serial markers, poweroff on success / stay-alive on failure. Testable via `SYMBLE_*` overrides, pipe input, and `--dry-run`. |
| `installer/sysemble-install.service` | Frozen `sysemble-install.service` oneshot (ConditionKernelCommandLine, 1800 s, WantedBy multi-user.target). |
| `tests/artifact_test.sh` | Offline fixture tests for `artifact_json` (UEFI no-DM + graphical + P0-b fallback), `artifact_iso_json` (iso-only, graphical, iso+disk), `artifact_install_json`/`artifact_install_tui_json`, ISO/installer GRUB text, plan output mode selection, desktop inference, boot evidence unit, installer runtime packages, kernel/initrd selection, hashing, and disk sizing. |
| `tests/build_exec_test.sh` | Offline fake-toolchain end-to-end tests of the native `--execute` disk/ISO/installer/TUI-installer command sequences, arguments, GRUB configs, include lists, baked installer script/unit/symlink/drop-in, mode-aware preflight, artifacts, and failure cleanup. |
| `tests/installer_test.sh` | Static contract checks plus real `--dry-run` runs with sentinel fake commands (no partition/mount/poweroff): unattended, piped TUI prompts, invalid-disk retry, cancel, `--yes`, password file, hostname/user commands, serial marker, and failure/exit-code paths. |
| `testdata/plan.example.json` | Contract-shaped KDE plan with a display manager (`["qcow2","iso"]`). |
| `testdata/plan.disk.json` | Same KDE plan with `["qcow2"]` for the P0-c/P0-d1 disk regression. |
| `testdata/plan.no-desktop.json` | Minimal fixture without a display manager for the P0-d1 no-DM regression. |
| `testdata/plan.iso.json` | Minimal 14-package live plan with `["iso"]` (also the `--installer` fixture). |
| `testdata/plan.iso-disk.json` | Minimal 14-package plan with `["qcow2","iso"]`. |
