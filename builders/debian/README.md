# Debian builder (P0-a + P0-b + P0-c1)

`build.sh` reads the `plan.json` produced by `sysemble plan --json` and turns
it into a bootable Debian disk image:

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

The authoritative acceptance is the GitHub Actions `boot-smoke` job on
`ubuntu-latest`. The development host is macOS arm64, where no real native
build can run; see [Local checks](#local-checks).

## Interface

```
builders/debian/build.sh --plan <plan.json> --out <dir> \
  [--dry-run] [--execute] [--engine docker|native]
```

| Option | Meaning |
|---|---|
| `--plan <path>` | Required. `plan.json` from `sysemble plan --json`. |
| `--out <dir>` | Required. Output directory; created if missing. Must not be `/` or an existing file. |
| `--dry-run` | Validate the plan, print the stages/packages/estimates, write only `<out>/plan.copy.json`, exit 0. Output is unchanged by P0-c. |
| `--execute` | Explicit alias for the default build mode (no `--dry-run`): build rootfs + GPT/UEFI disk images + artifact. Mutually exclusive with `--dry-run`. |
| `--engine native` | Default. Build on this Linux host (`uname -s` = Linux, euid 0, and the tools below in `PATH`). |
| `--engine docker` | Bootstrap the rootfs inside `debian:trixie`; needs `docker` CLI and a reachable daemon. P0-c GPT/GRUB/UEFI assembly is **not** implemented for Docker, so `--execute` with `--engine docker` is rejected (exit 2). |
| `-h`, `--help` | Print usage and exit 0. |

`--opt value` and `--opt=value` are both accepted. Missing or unknown
arguments print usage and exit 2.

### Outputs (native `--execute`)

```
<out>/
  rootfs/                 # mmdebstrap rootfs
  disk.img                # raw GPT: p1 ESP (vfat32) + p2 root (ext4)
  disk.qcow2              # qemu-img convert -O qcow2 of disk.img
  esp/                    # ESP staging tree
    EFI/BOOT/BOOTX64.EFI  # grub-mkstandalone, config embedded
    boot/grub/grub.cfg    # copy of the embedded config
  grub.cfg                # the GRUB config (artifact boot.grub.config)
  artifact.json           # sysemble/artifact/v1 manifest (boot.mode = uefi)
  build.log               # full build output (tee)
  plan.copy.json          # byte-identical copy of the input plan
```

`<out>/esp.img` (the FAT32 image merged into `disk.img`) is a temporary
intermediate and is removed after `dd` succeeds.

On failure, `rootfs/`, `disk.img`, `esp/`, `grub.cfg`, and `build.log` are kept
for diagnosis; `esp.img`, a half-written `disk.qcow2`, and the artifact temp
file are removed. `disk.img` is deliberately kept by P0-c: it may already hold a
valid GPT/ext4 partition when a later GRUB/mcopy/dd/qemu-img step failed.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Dry run succeeded, or a complete native image build finished. |
| 1 | Invalid plan: malformed JSON, failed plan validation, or `plan.spec` missing for a real native build. |
| 2 | Usage or I/O error, including an unsafe `--out`, `--dry-run` + `--execute`, or `--engine docker` + `--execute`. |
| 3 | Native engine unavailable: not Linux, not root, or missing `mmdebstrap` / `mkfs.ext4` / `qemu-img` / `sgdisk` / `mkfs.vfat` / `mcopy` / `grub-mkstandalone` / `dd`. |
| 4 | Docker engine unavailable: no `docker` CLI, or `docker info` failed/timed out. |
| 5 | No JSON parser: neither `jq` nor `python3` is available. |
| 6 | A build step failed, `<out>/rootfs` (or an output image) already exists, an artifact input is missing, or the rootfs has no kernel/initrd. |

Every unmet native preflight requirement is reported one line at a time, then
the script exits 3. It never calls `sudo`.

## Dry run

```console
$ bash builders/debian/build.sh \
    --plan /tmp/min-plan.json --out /tmp/sysemble-dry --dry-run
Sysemble Debian builder - dry run (P0-a)
  ...
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

The dry-run text is intentionally unchanged from P0-a/P0-b (P0-c regression
C1). The dry run **does not check the engine**, so it works on macOS/Windows
hosts without Linux, root, mmdebstrap, the UEFI toolchain, or Docker. It
validates the plan first and leaves nothing behind except
`<out>/plan.copy.json`.

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
it an x86_64 plan.

JSON is read with `jq` when available, otherwise with `python3 -c`. Both
backends emit the same validated record stream; the dry-run output is identical
for the same plan. If neither tool exists, the script exits 5 before creating
`<out>`.

## Native engine (`--execute`)

Preflight requires all of:

1. `uname -s` is `Linux`;
2. effective uid is 0;
3. `mmdebstrap` (rootfs bootstrap);
4. `mkfs.ext4` (e2fsprogs with `-d` and `-E offset=` support);
5. `qemu-img` (qemu-utils);
6. `sgdisk` (gdisk, GPT partition table);
7. `mkfs.vfat` (dosfstools, FAT32 ESP);
8. `mcopy` (mtools, ESP population);
9. `grub-mkstandalone` (grub-efi-amd64-bin, BOOTX64.EFI);
10. `dd` (coreutils, ESP merge).

On Debian/Ubuntu the package set is:

```
mmdebstrap e2fsprogs qemu-utils gdisk dosfstools mtools \
grub-efi-amd64-bin grub-common
```

The build then runs:

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

`<ver>` is the basename of the highest-versioned `vmlinuz-*` / `initrd.img-*`
found under `rootfs/boot` with `sort -V` (for example `6.12.3-amd64`). The same
text is written to `<out>/grub.cfg`, staged at
`<out>/esp/boot/grub/grub.cfg`, and embedded into `BOOTX64.EFI` by
`grub-mkstandalone`; no external `/boot/grub` directory is needed at boot time.

### Boot images

If no kernel or initrd exists, the build fails with exit 6 and a message naming
the directory; it never emits an artifact with missing boot paths. The UEFI
cmdline is:

```
root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=multi-user.target
```

The frozen partition layout means the root filesystem is always GPT partition 2
of the virtio disk (`/dev/vda2`).

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
  "boot": {
    "mode": "uefi",
    "disk": "disk.img",
    "kernel": "rootfs/boot/vmlinuz-6.12.3-amd64",
    "initrd": "rootfs/boot/initrd.img-6.12.3-amd64",
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

- `boot.mode` is `"uefi"`. P0-b artifacts (and any artifact without
  `boot.mode`) default to `"kernel"`.
- `boot.disk` and `boot.grub` are relative to the artifact directory.
  `boot.grub.config` is `<out>/grub.cfg`; the same text is also in
  `esp/boot/grub/grub.cfg`.
- `partitions[].size_mb` follows the frozen sample: ESP 512 and
  root = `disk_mb - 512`. The 1 MiB GPT alignment gap is not charged to a
  partition role. The filesystem created inside p2 is 1 MiB smaller
  (3582 MiB on the 4096 MB floor) so it stays clear of the backup GPT; the
  partition itself still spans the rest of the disk.
- `images` still contains exactly the raw and qcow2 images with actual file
  sizes rounded up to MiB and SHA-256 digests (`sha256sum`, `shasum -a 256`, or
  `openssl dgst -sha256`).
- The artifact helper falls back to the P0-b direct-kernel shape (no
  `boot.mode`, no `disk`, no `grub`, no `partitions`, `/dev/vda` cmdline) when
  neither GRUB output exists, and refuses to guess when only one exists.

### Failure behavior

- `mmdebstrap` failure: the partial `rootfs/` (if any) and `build.log` are
  kept; no disk images are created.
- Any later failure (missing kernel/initrd, `truncate`, `sgdisk`,
  `mkfs.ext4`, `mkfs.vfat`, GRUB config rendering, `grub-mkstandalone`,
  `mcopy`, `dd`, `qemu-img`, hashing, manifest write): `rootfs/`, `disk.img`,
  `esp/`, `grub.cfg`, and `build.log` are kept; `esp.img`, a half-written
  `disk.qcow2`, and `.artifact.json.tmp` are removed by the EXIT trap.
- `<out>/rootfs`, `<out>/disk.img`, or `<out>/disk.qcow2` already existing:
  refuse to overwrite and exit 6. Stale `esp/`, `esp.img`, or `grub.cfg` left
  by an interrupted attempt are removed before the retry (they can only be
  derived intermediates once the rootfs and disk images are absent). Because
  `disk.img` is intentionally kept after a failure, retrying into the same
  `<out>` requires removing it (and `rootfs/`, if present) manually first.
- Interrupts (`HUP`/`INT`/`TERM`) run the same EXIT cleanup.

## Docker engine

Preflight requires the `docker` CLI and a successful `docker info`, wrapped in a
20-second watchdog so a wedged daemon cannot hang the script. A missing CLI or
unreachable daemon prints a diagnostic and exits 4.

Docker mode is still **P0-a scope**: it installs mmdebstrap in a
`debian:trixie` container and bootstraps `/out/rootfs`, then stops with a
warning. It does **not** produce `disk.img`, `disk.qcow2`, `esp/`, or
`artifact.json`; that assembly path is native-only and **P0-c unverified**.
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
- The rootfs target and existing disk images are never deleted or overwritten.
- Temporary files live in `$TMPDIR` (or `/tmp`) under `sysemble-build.*` and are
  removed by an EXIT trap. The trap only deletes paths matching that prefix.
- On failure, cleanup only deletes derived intermediates created by this build;
  it never deletes a pre-existing `rootfs/` or image.
- No loop devices, mounts, or host block devices are used.
- Docker mode bind-mounts only `<out>`; no Docker socket or host directories.

## Not implemented in P0-c1

- Calamares or any installer flow; desktop/KDE configuration; first boot after
  installation (P0-d/P0-e).
- ISO/squashfs/PXE assembly, persistence, secure boot signing, dm-verity.
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

## Known risks (tracked by P0-c)

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

## Local checks

```bash
bash -n builders/debian/build.sh
bash -n builders/debian/lib.sh
bash -n builders/debian/tests/artifact_test.sh
bash -n builders/debian/tests/build_exec_test.sh

# Plan fixture / dry-run regression (output unchanged from P0-b)
bash builders/debian/build.sh \
  --plan builders/debian/testdata/plan.example.json \
  --out /tmp/sysemble-dry --dry-run

# Offline artifact manifest tests (fixture rootfs + real sha256)
bash builders/debian/tests/artifact_test.sh        # 36 checks

# Offline native --execute command-sequence test (fake UEFI toolchain)
bash builders/debian/tests/build_exec_test.sh      # 84 checks

# On macOS, without --dry-run, the native preflight is expected to exit 3
bash builders/debian/build.sh \
  --plan builders/debian/testdata/plan.example.json \
  --out /tmp/sysemble-native
```

`builders/debian/testdata/plan.example.json` is a self-contained fixture used
by these checks. The real-plan dry-run uses the CLI:

```bash
cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml > /tmp/min-plan.json
bash builders/debian/build.sh --plan /tmp/min-plan.json --out /tmp/sysemble-dry --dry-run
```

The tests do **not** prove that the real commands work: they prove command
assembly, argument order/content, GRUB config text, hook text, artifact shape,
log tee, and failure cleanup. The authoritative real build is the CI
`boot-smoke` job.

On a macOS host without the UEFI toolchain, `build.sh --execute` exits 3 and
reports every missing item, including `sgdisk`, `mkfs.vfat`, `mcopy`,
`grub-mkstandalone`, and `dd`.

## CI contract

The P0-c CI job installs `mmdebstrap qemu-system-x86 qemu-utils e2fsprogs gdisk
dosfstools mtools grub-efi-amd64-bin grub-common ovmf` on `ubuntu-latest`, then
runs:

```bash
cargo run -p sysemble-cli -- plan examples/minimal-debian.yaml > plan.json
sudo -E bash builders/debian/build.sh --plan plan.json --out /tmp/out --execute
bash tools/boot-check.sh --artifact /tmp/out/artifact.json --timeout 300
```

Expected evidence on success: `rootfs/`, `disk.img` (GPT + ESP + GRUB EFI),
`disk.qcow2`, `esp/`, `grub.cfg`, `artifact.json`, `build.log`, then a
`boot.log` containing the firmware banner, `GRUB`, `Linux version`,
`systemd[1]`/`Reached target`, and `login:`.

## Files

| File | Role |
|---|---|
| `build.sh` | CLI, output directory handling, dry run, native GPT/ESP/GRUB/UEFI pipeline, docker rootfs bootstrap. |
| `lib.sh` | JSON backends, record parsing, plan validation, preflight, disk sizing, GRUB rendering, artifact helpers, usage text. |
| `tests/artifact_test.sh` | Offline fixture tests for `artifact_json` (UEFI + P0-b fallback), kernel/initrd selection, hashing, and disk sizing. |
| `tests/build_exec_test.sh` | Offline fake-toolchain end-to-end test of the native `--execute` P0-c command sequence, arguments, GRUB config, and failure cleanup. |
| `testdata/plan.example.json` | Contract-shaped fixture used by the checks above. |
