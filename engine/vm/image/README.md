# Sysemble VM image (P1-e3a)

Builds the frozen arm64 engine-VM image consumed by the macOS
Virtualization.framework helper (P1-e3b):

```
engine/vm/image/build/
  disk.img          raw ext4, 6 GiB sparse, label sysemble-engine, guest root
  vmlinuz           guest kernel (arm64 Image, Debian trixie linux-image-arm64)
  initrd.img        guest initramfs
  sysemble-vm.json  manifest (schema 1)
```

Contract: [`docs/plan/P1-e3-workplan.md`](../../../docs/plan/P1-e3-workplan.md)
sections 1, 2.1, and 4 (V1/V2). The guest files baked into the disk are in
[`engine/vm/guest/`](../guest/README.md).

## Build

macOS (Apple Silicon) via Docker Desktop, arm64 native — no emulation:

```sh
bash engine/vm/image/build-image.sh --out engine/vm/image/build
```

Linux arm64 (CI or a dev box):

```sh
# auto: docker when the daemon is usable, otherwise the native path with sudo
bash engine/vm/image/build-image.sh --out engine/vm/image/build

# explicit, native, passwordless sudo (GitHub ubuntu-24.04-arm)
sudo bash engine/vm/image/build-image.sh --engine native --out engine/vm/image/build

# explicit docker
bash engine/vm/image/build-image.sh --engine docker --out engine/vm/image/build
```

Options:

| Flag | Meaning |
|---|---|
| `--ref <name>` | manifest label (default `sysemble-vm:0.1.0`); not a docker tag |
| `--out <dir>` | output directory (default `engine/vm/image/build`) |
| `--engine auto\|docker\|native` | `auto` = macOS → docker; Linux arm64 → docker if the daemon answers, else native |
| `--no-cache` | docker: `--pull=always` for the base image; native: ignored |
| `--verify <dir>` | re-check an existing manifest and its files (no build) |
| `-h, --help` | usage |

The build streams everything to `<out>/build-image.log` and verifies the
manifest on the host with `python3` when it finishes. `--verify` can be run on
any host with `python3` (amd64 included): it does not need Docker.

The native path installs mmdebstrap, e2fsprogs, systemd and python3 with
`apt-get` as root, so use it on an ephemeral CI runner or a disposable arm64
host (the docker path only touches the build container).

```sh
bash engine/vm/image/build-image.sh --verify engine/vm/image/build
```

## What the build does

1. Runs `in-container-build.sh` as root in Linux arm64, either inside
   `debian:trixie` (`docker run --rm --privileged --platform linux/arm64 -v
   <repo>:/src:ro -v <out>:/out`) or directly on an arm64 host.
2. Installs `mmdebstrap`, `debian-archive-keyring`, `e2fsprogs`, `systemd`
   (only for `systemctl --root`), `python3` and `file` in the build
   environment.
3. `mmdebstrap --variant=minbase --include=<guest list> trixie <rootfs>` —
   arm64 native, no qemu, no Rosetta.
4. Installs the guest agent, its unit, `modules-load.d/virtiofs.conf` and
   `20-wired.network`, enables the units offline, points `/etc/resolv.conf` at
   the systemd-resolved stub (with a `1.1.1.1` fallback), sets the hostname and
   a machine-id.
5. Creates the 6 GiB sparse ext4 image with
   `mke2fs -t ext4 -F -L sysemble-engine -d <rootfs> disk.img`, copies the
   newest `/boot/vmlinuz-*` / `initrd.img-*`, and reads the finished disk back
   with `debugfs` (the `diskcheck: OK` lines in the log).
6. Writes `sysemble-vm.json` from the files themselves: kernel release and
   sha256, initrd sha256, disk sha256 + size, guest dpkg package count,
   `mmdebstrap` version, UTC timestamp.

### Why the rootfs is not built under `--out`

On Docker Desktop for Mac the `--out` bind mount is APFS, which is
case-insensitive by default. Debian packages contain paths that differ only by
case (`PAM.7.gz` vs `pam.7.gz`); a symlink whose target collapses onto its own
name fails with ELOOP/EEXIST. P1-e2 hit exactly this when the builder wrote a
rootfs straight into a bind-mounted host directory
([`engine/runtime/container-entry.sh`](../../runtime/container-entry.sh)). The
rootfs therefore stays at `/build/rootfs` (container/host-local,
case-sensitive) and only `disk.img`, `vmlinuz`, `initrd.img` and the manifest
cross the bind mount. `mke2fs -d` copies the tree into the ext4 image, and the
image itself stays sparse (the plan's `du` < logical-size check).

## Manifest

```json
{
  "schema": 1,
  "name": "sysemble-vm",
  "version": "0.1.0",
  "ref": "sysemble-vm:0.1.0",
  "arch": "arm64",
  "kernel": {"path": "vmlinuz", "release": "6.12.x-arm64", "sha256": "..."},
  "initrd": {"path": "initrd.img", "sha256": "..."},
  "disk": {"path": "disk.img", "sha256": "...", "size_bytes": 6442450944},
  "guest": {
    "agent_unit": "sysemble-vm-agent.service",
    "minimal_build": "engine/vm/guest/minimal-build.sh"
  },
  "packages": 166,
  "mmdebstrap": "1.5.7",
  "created": "2026-11-24T00:00:00Z"
}
```

`packages` is the guest's installed dpkg package count (not the build
environment's), and `disk.size_bytes` is the logical 6 GiB size; the allocated
(physical) size stays much smaller because the image is sparse.

## Tests

```sh
# static only: files, unit/network/modules contracts, script CLIs, CI snippet
bash engine/vm/image/tests/image_test.sh

# artifacts: --verify, manifest fields, sha256 recomputation, ext4/arm64
# magic, sparseness, guest files (debugfs, or the build log on macOS)
bash engine/vm/image/tests/image_test.sh --docker
```

`--docker` is historical: it checks the built image directory and works for
both engines. On hosts without `debugfs` (macOS) the guest-install checks use
the `diskcheck: OK` lines that `in-container-build.sh` records with `debugfs`
before writing the manifest. `--manifest-dir <dir>` points the artifact checks
somewhere else.

## arm64-only limitation

Virtualization.framework on Apple Silicon can only boot arm64 guests, so this
image is arm64-only: the build refuses a non-arm64 host, and the manifest hard
codes `"arch": "arm64"`. This prototype does **not** produce a bootable x86_64
image; the x86_64 GPT/GRUB/OVMF pipeline stays with the container backend
(P1-e2). The guest build in `engine/vm/guest/minimal-build.sh` also produces an
arm64 rootfs.

## CI

[`ci-snippet.yml`](ci-snippet.yml) adds a `vm-image` job on
`ubuntu-24.04-arm` (45 min): build, `image_test.sh --docker`, then upload the
manifest, kernel, initrd and logs. The 6 GiB disk is **not** uploaded.
`ubuntu-24.04-arm` is a native arm64 Linux runner; GitHub's macOS runners are
Virtualization.framework guests themselves, so they cannot start a nested VM —
the real boot/protocol checks (V4-V7) run on Apple Silicon only.

The build is intentionally not bit-for-bit reproducible: `debian:trixie` is a
moving tag (override with `SYSEMBLE_VM_BUILD_IMAGE`), mmdebstrap pulls the
current trixie packages and `created` is the build time. Pin the image and
`SOURCE_DATE_EPOCH` if a byte-stable artifact is ever needed.

## Troubleshooting

- **`docker daemon is not reachable`** — start Docker Desktop; or on Linux arm64
  use `--engine native` with sudo.
- **`the VM image is arm64-only`** — the host reports an x86_64 machine; use an
  Apple Silicon Mac or an arm64 Linux runner.
- **`diskcheck failed`** — the ext4 image does not contain the guest files; read
  the preceding `systemctl --root`/`install` output in `build-image.log`.
- **`no /boot/vmlinuz-*`** — `linux-image-arm64` did not finish installing;
  check network/mirror access and the mmdebstrap log.
- **`no initramfs found`** — the kernel postinst could not run
  `update-initramfs`; the build retries it with `chroot ... update-initramfs`.
- **Stale output** — `--out` is rewritten per build; delete it for a clean run.
  `--no-cache` only refreshes the docker base image.

## Out of scope

No VM boot, no serial log, no virtiofs protocol, no Swift helper here — those
are P1-e3b. This slice only produces and verifies the image bytes.
