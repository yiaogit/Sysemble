# Debian builder (P0-a + P0-b)

`build.sh` reads the `plan.json` produced by `sysemble plan --json` and turns
it into a bootable Debian disk image:

- **P0-a**: plan validation, dry run, and rootfs bootstrap with
  [mmdebstrap](https://mmdebstrap.de/) (native or `debian:trixie` Docker).
- **P0-b**: the native `--execute` path additionally creates a raw ext4 image
  with `mkfs.ext4 -d`, converts it to qcow2 with `qemu-img`, and writes a
  `sysemble/artifact/v1` manifest. The image boots with `qemu -kernel/-initrd`;
  partitioning and GRUB are P0-c work.

The authoritative P0-b acceptance is the GitHub Actions `boot-smoke` job on
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
| `--dry-run` | Validate the plan, print the stages/packages/estimates, write only `<out>/plan.copy.json`, exit 0. |
| `--execute` | Explicit alias for the default build mode (no `--dry-run`): build rootfs + disk images + artifact. Mutually exclusive with `--dry-run`. |
| `--engine native` | Default. Build on this Linux host (`uname -s` = Linux, euid 0, and the tools below in `PATH`). |
| `--engine docker` | Bootstrap the rootfs inside `debian:trixie`; needs `docker` CLI and a reachable daemon. P0-b disk/artifact assembly is **not** implemented for Docker, so `--execute` with `--engine docker` is rejected (exit 2). |
| `-h`, `--help` | Print usage and exit 0. |

`--opt value` and `--opt=value` are both accepted. Missing or unknown
arguments print usage and exit 2.

### Outputs (native `--execute`)

```
<out>/
  rootfs/                 # mmdebstrap rootfs
  disk.img                # raw ext4 containing rootfs/ (truncate + mkfs.ext4 -d)
  disk.qcow2              # qemu-img convert -O qcow2
  artifact.json           # sysemble/artifact/v1 manifest
  build.log               # full build output (tee)
  plan.copy.json          # byte-identical copy of the input plan
```

`<out>/rootfs` is kept on failure, together with `build.log`; half-written
`disk.img`/`disk.qcow2` (and a half-written artifact temp file) are removed.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Dry run succeeded, or a complete native image build finished. |
| 1 | Invalid plan: malformed JSON, failed plan validation, or `plan.spec` missing for a real native build. |
| 2 | Usage or I/O error, including an unsafe `--out`, `--dry-run` + `--execute`, or `--engine docker` + `--execute`. |
| 3 | Native engine unavailable: not Linux, not root, or missing `mmdebstrap` / `mkfs.ext4` / `qemu-img`. |
| 4 | Docker engine unavailable: no `docker` CLI, or `docker info` failed/timed out. |
| 5 | No JSON parser: neither `jq` nor `python3` is available. |
| 6 | A build step failed, `<out>/rootfs` (or an output image) already exists, an artifact input is missing, or the rootfs has no kernel/initrd. |

Every unmet native preflight requirement is reported, then the script exits 3.
It never calls `sudo`.

## Dry run

```console
$ bash builders/debian/build.sh \
    --plan builders/debian/testdata/plan.example.json \
    --out /tmp/sysemble-dry --dry-run
Sysemble Debian builder - dry run (P0-a)
  plan:       builders/debian/testdata/plan.example.json
  out:        /private/tmp/sysemble-dry
  ...
Stages (planned):
  [1/6] validate          plan structure is valid
  [2/6] fetch base        debian/trixie
  [3/6] bootstrap rootfs  mmdebstrap --variant=minbase
  [4/6] install packages  43 packages via --include
  [5/6] configure         not implemented in P0-a
  [6/6] assemble image    not implemented in P0-a (requested: qcow2, iso)
...
Dry run complete: no image was built.
Plan copy written to: /private/tmp/sysemble-dry/plan.copy.json
```

The P0-a dry-run output is unchanged by P0-b (the stage text still says
"not implemented in P0-a"; the real work happens in the `--execute` path).
The dry run **does not check the engine**, so it works on macOS/Windows hosts
without Linux, root, mmdebstrap, or a running Docker daemon. It validates the
plan before doing anything else and leaves nothing behind except
`<out>/plan.copy.json` (plus the `<out>` directory itself).

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
| `base.pin` | Snapshot date/digest; copied to `artifact.base.pin` (`null` if absent). **Not applied** to the mirror in P0-b. |
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
3. `mmdebstrap` is in `PATH` (rootfs bootstrap);
4. `mkfs.ext4` is in `PATH` (e2fsprogs, with `-d` support);
5. `qemu-img` is in `PATH` (qemu-utils).

The build then runs:

```
DEBIAN_FRONTEND=noninteractive \
mmdebstrap --variant=minbase --include=<comma-separated packages> \
  --customize-hook=<hostname + serial-getty hook> \
  <base.release> <out>/rootfs

# P0-b disk assembly
truncate -s <size_mb>M <out>/disk.img
mkfs.ext4 -d <out>/rootfs -L SYMBLE -F <out>/disk.img
qemu-img convert -O qcow2 <out>/disk.img <out>/disk.qcow2
```

All stage messages and all command stdout/stderr are teed to
`<out>/build.log`.

### Customize hook

mmdebstrap runs the customize hook on the host with the rootfs path as `$1`.
The generated hook:

- writes `plan.spec` (lowercased, sanitized to `[a-z0-9-]`, max 63 chars, with
  a `sysemble` fallback when empty) to `/etc/hostname`;
- runs `chroot "$1" systemctl enable serial-getty@ttyS0.service`.
  Failure is **non-fatal**: a warning is written to stderr, therefore to
  `build.log`, and the build continues.

The P0 plan has no hostname field, so `plan.spec` is the hostname source. This
is a P0-b convenience, not a frozen hostname contract.

### Disk sizing

Integer arithmetic equivalent to:

```
size_mb = ceil((ceil(rootfs_mb * 1.6) + 512) / 256) * 256
size_mb = max(size_mb, 2048)
```

`rootfs_mb` is `du -sk <out>/rootfs` rounded up to MiB. Examples: a 500 MB
rootfs → 2048 MB, 1000 MB → 2304 MB, 2000 MB → 3840 MB. `disk.img` is created
by `truncate`, so the raw file is sparse where the filesystem does not use the
allocated blocks.

### Boot images

The artifact points at the **highest version** of `vmlinuz-*` and
`initrd.img-*` under `rootfs/boot`, selected with `sort -V`. If either is
missing, the build fails with exit 6 and a message naming the directory; it
never emits an artifact with missing boot paths.

The cmdline is frozen for P0-b:

```
console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target
```

### `artifact.json`

`artifact.json` is `sysemble/artifact/v1` and is written atomically (temp file
+ rename) only after every image exists:

```json
{
  "apiVersion": "sysemble/artifact/v1",
  "createdAt": "2026-11-23T12:00:00Z",
  "spec": "minimal-debian",
  "base": {"kind": "debian", "release": "trixie", "pin": "2026-11-01"},
  "arch": "x86_64",
  "packages": ["apt", "ca-certificates", "systemd"],
  "rootfs": {"path": "rootfs", "size_mb": 420},
  "images": [
    {"path": "disk.img", "format": "raw", "size_mb": 2048, "sha256": "..."},
    {"path": "disk.qcow2", "format": "qcow2", "size_mb": 900, "sha256": "..."}
  ],
  "boot": {
    "kernel": "rootfs/boot/vmlinuz-6.12.3-amd64",
    "initrd": "rootfs/boot/initrd.img-6.12.3-amd64",
    "cmdline": "console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target"
  },
  "builder": {"name": "build.sh", "version": "0.1.0"}
}
```

Image `size_mb` values are the actual file sizes rounded up to MiB. `sha256`
uses `sha256sum`, `shasum -a 256`, or `openssl dgst -sha256`, whichever is
available.

### Failure behavior

- `mmdebstrap` failure: the partial `rootfs/` (if any) and `build.log` are kept;
  no disk images are created.
- Any later failure (missing kernel/initrd, `truncate`, `mkfs.ext4`,
  `qemu-img`, hashing, manifest write): `rootfs/` and `build.log` are kept;
  half-written `disk.img`, `disk.qcow2`, and `.artifact.json.tmp` are removed by
  the EXIT trap.
- `<out>/rootfs`, `<out>/disk.img`, or `<out>/disk.qcow2` already existing:
  refuse to overwrite and exit 6. This preserves the P0-a rule for `rootfs`
  and prevents pairing a stale image with a fresh rootfs. Remove them manually
  before retrying.
- Interrupts (`HUP`/`INT`/`TERM`) run the same EXIT cleanup.

## Docker engine

Preflight requires the `docker` CLI and a successful `docker info`, wrapped in a
20-second watchdog so a wedged daemon cannot hang the script. A missing CLI or
unreachable daemon prints a diagnostic and exits 4.

Docker mode is still **P0-a scope**: it installs mmdebstrap in a
`debian:trixie` container and bootstraps `/out/rootfs`, then stops with a
warning. It does **not** produce `disk.img`, `disk.qcow2`, or `artifact.json`;
that assembly path is native-only and **P0-b unverified**. Passing `--execute`
with `--engine docker` is rejected with exit 2 instead of returning a rootfs-only
"success". Do not use Docker mode for the boot-smoke acceptance.

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
- `plan.copy.json` and `artifact.json` are written with a temporary file plus
  rename, so pre-existing symlinks/hardlinks cannot redirect writes outside
  `<out>`.
- The rootfs target and existing images are never deleted or overwritten.
- Temporary files live in `$TMPDIR` (or `/tmp`) under `sysemble-build.*` and are
  removed by an EXIT trap. The trap only deletes paths matching that prefix.
- On failure, cleanup only deletes disk outputs that this build created; it
  never deletes a pre-existing `rootfs/` or image.
- Docker mode bind-mounts only `<out>`; no Docker socket or host directories.

## Not implemented in P0-b

- Partition tables, filesystems on partitions, GRUB/UEFI/UKI, ISO/PXE assembly.
- System configuration beyond `/etc/hostname` and the serial getty enable:
  locale, timezone, keyboard, users, passwords, services, networking, kernel
  cmdline customization.
- Module hooks and per-module package layering (modules are display-only).
- Snapshot pinning (`base.pin` is copied into the artifact but the build uses
  the live mirror), reproducible timestamps, SBOM, signatures.
- Cross-architecture builds; the native build uses the host architecture and
  `target.arch` is validated but not applied.
- Build cache, resume, build locking (do not run two builds against the same
  `<out>` concurrently), and automatic retry.
- Docker disk/artifact assembly (P0-a rootfs bootstrap only; P0-b unverified).
- Real native build verification on the development host: macOS arm64 has no
  Linux, root, mmdebstrap, mkfs.ext4 or qemu-img. The command path is covered
  by offline tests with a fake toolchain (below); the real path is only
  exercised by CI.

## Local checks

```bash
bash -n builders/debian/build.sh
bash -n builders/debian/lib.sh

# Plan fixture / dry-run regression
bash builders/debian/build.sh \
  --plan builders/debian/testdata/plan.example.json \
  --out /tmp/sysemble-dry --dry-run

# Offline artifact manifest tests (fixture rootfs + real sha256)
bash builders/debian/tests/artifact_test.sh

# Offline native --execute command-sequence test (fake uname/id/toolchain)
bash builders/debian/tests/build_exec_test.sh

# On macOS, without --dry-run, the native preflight is expected to exit 3
bash builders/debian/build.sh \
  --plan builders/debian/testdata/plan.example.json \
  --out /tmp/sysemble-native
```

`builders/debian/testdata/plan.example.json` is a self-contained fixture used
by these checks. The real-plan dry-run uses the CLI:

```bash
cargo run -p sysemble-cli -- plan examples/minimal-debian.yaml > /tmp/min-plan.json
bash builders/debian/build.sh --plan /tmp/min-plan.json --out /tmp/sysemble-dry --dry-run
```

The tests do **not** prove that the real commands work: they prove command
assembly, hook text, artifact shape, log tee, call order, and failure cleanup.
The authoritative real build is the CI `boot-smoke` job.

## CI contract

The P0-b CI job installs `mmdebstrap qemu-system-x86 qemu-utils e2fsprogs` on
`ubuntu-latest`, then runs:

```bash
cargo run -p sysemble-cli -- plan examples/minimal-debian.yaml > plan.json
sudo -E bash builders/debian/build.sh --plan plan.json --out /tmp/out --execute
bash tools/boot-check.sh --artifact /tmp/out/artifact.json --timeout 300
```

Expected evidence on success: `rootfs/`, `disk.img`, `disk.qcow2`,
`artifact.json`, `build.log`, then a `boot.log` containing `Linux version`,
`systemd[1]`/`Reached target`, and `login:`.

## Files

| File | Role |
|---|---|
| `build.sh` | CLI, output directory handling, dry run, native build pipeline, docker rootfs bootstrap. |
| `lib.sh` | JSON backends, record parsing, plan validation, preflight, artifact/disk helpers, usage text. |
| `tests/artifact_test.sh` | Offline fixture tests for `artifact_json`, kernel/initrd selection, hashing, disk sizing. |
| `tests/build_exec_test.sh` | Offline fake-toolchain end-to-end test of the native `--execute` command sequence and failure cleanup. |
| `testdata/plan.example.json` | Contract-shaped fixture used by the checks above. |
