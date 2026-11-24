# Sysemble engine image (E2a)

`sysemble-engine:0.1.0` is the disposable, versioned Linux sandbox that runs
Sysemble's build and boot verification. It is a Debian trixie (`linux/amd64`)
image that carries the **same** `builders/debian/build.sh` and
`tools/boot-check.sh` as the host, so a container build is not a second
implementation of the builder.

Frozen contract: [`docs/plan/P1-e2-workplan.md`](../../docs/plan/P1-e2-workplan.md)
sections 2.1 (image/manifest) and 2.3 (container command). This directory only
adds the image, its build/verify scripts, the tests, and the CI job fragment.

## Contents

| Group | Packages |
|---|---|
| Rootfs bootstrap | `mmdebstrap`, `debian-archive-keyring` |
| Disk / GPT / ESP | `e2fsprogs`, `gdisk`, `dosfstools`, `mtools` |
| UEFI boot | `grub-efi-amd64-bin`, `grub-common`, `ovmf` |
| Live ISO | `xorriso`, `squashfs-tools` |
| Boot verification | `qemu-system-x86`, `qemu-utils` |
| Shell / JSON / evidence | `bash`, `coreutils`, `grep`, `sed`, `gawk`, `findutils`, `tar`, `gzip`, `xz-utils`, `zstd`, `rsync`, `jq`, `expect`, `curl`, `ca-certificates`, `file`, `procps`, `util-linux` |

The Dockerfile pins `debian:trixie-slim` by sha256 digest and installs
everything in one `apt-get update && apt-get install --no-install-recommends
... && rm -rf /var/lib/apt/lists/*` layer. There is no `ENTRYPOINT`: callers
always pass an explicit command (`bash builders/...`), which is what the CI and
the desktop app do.

## Build and verify

```bash
# Build the image and write engine/image/build/sysemble-engine.json.
bash engine/image/build-image.sh

# Same, with an explicit reference / output directory and no build cache.
bash engine/image/build-image.sh \
  --ref sysemble-engine:0.1.0 \
  --out engine/image/build \
  --no-cache

# Verify an existing manifest against the local image and the Dockerfile pin.
# On success the manifest is rewritten atomically with "verified": true.
bash engine/image/build-image.sh --verify engine/image/build
```

`build-image.sh` records the image id, the base reference, the tool versions,
and the full dpkg package list collected from the built image itself. The
manifest lives at `<out>/sysemble-engine.json` and is a CI artifact, not a
committed file (`engine/image/build/` is gitignored).

Verify checks (all failures exit 1 with a specific reason):

1. the manifest exists and is valid JSON with `schema: 1`;
2. the image reference exists locally;
3. the manifest `image_id` matches `docker image inspect`;
4. the manifest `base` digest matches the digest pinned in the Dockerfile;
5. all five `tool_versions` entries are present and non-empty.

`--platform` accepts only `linux/amd64`: the engine target architecture is
fixed for P1-e2, and the Dockerfile pins the amd64 base digest.

## Container contract

The desktop app / CI runs the engine exactly like this (see
[`tests/container_smoke.sh`](tests/container_smoke.sh)):

```bash
# phase 1 - build (the builder runs in the container's own filesystem)
docker run --rm --init --privileged --platform linux/amd64 \
  --name sysemble-build-<id> \
  -v <repo>:/work:ro \
  -v <out>:/export \
  -w /work \
  sysemble-engine:0.1.0 \
  bash engine/runtime/container-entry.sh \
    --plan /export/plan.json --out /out --export /export --mode execute

# phase 2 - UEFI boot-check on the exported artifact (same image)
docker run --rm --init --privileged --platform linux/amd64 \
  -v <repo>:/work:ro -v <out>:/out -w /work \
  sysemble-engine:0.1.0 \
  bash tools/boot-check.sh --artifact /out/artifact.json --timeout 900 --json
```

- **Mounts.** The repository is mounted read-only at `/work`. The host output
  directory is mounted at `/export`; `container-entry.sh` runs
  `builders/debian/build.sh --out /out` **inside the container** and copies only
  the top-level result files (`artifact.json`, `disk.img`, `disk.qcow2`, any
  `*.iso`) to `/export`. `rootfs/`, `iso/`, `esp/` and `build.log` are not
  exported. Host paths are never passed into the container, which keeps
  non-ASCII repository paths (for example the Chinese path used on the macOS dev
  machine) working.
- **Why build in `/out` and export.** macOS APFS is case-insensitive by
  default. Debian packages contain paths that differ only by case (e.g.
  `libpam-runtime` ships `/usr/share/man/man7/pam.7.gz -> PAM.7.gz`). Writing a
  rootfs directly into a bind-mounted host directory turns that into a symlink
  loop (`Too many levels of symbolic links`) and dpkg fails. Building on the
  container's case-sensitive filesystem and exporting single files keeps macOS
  usable; the cost is that the host only receives artifacts, so kernel-mode
  boot-check of `rootfs/boot/*` is not available on the host (P1-e2 does the
  boot-check inside the container, as above).
- **`--privileged`.** `mmdebstrap` bootstraps a rootfs with `chroot` and
  requires mount/namespace capabilities that a default container does not have.
  This is a local, one-shot build sandbox, **not** a security boundary: Run the
  image only on specs you trust, exactly as you would trust a local root build.
- **`--init`.** Reaps the short-lived QEMU/mmdebstrap children so the container
  exits cleanly.
- **No daemon.** The container has no docker socket; it can only write under
  `/out` (container-local) and `/export` (host), plus the boot-check outputs in
  `/out`. Boot logs (`boot.log`, `boot-evidence.json`) are written next to the
  exported artifact by phase 2.
- **`linux/amd64` on Apple Silicon.** The image is amd64-only. Docker Desktop
  runs it through Rosetta, so a full build + TCG boot takes minutes (measured
  191 s on an idle M-series host and 504 s while other cargo jobs ran; budget
  15–40 minutes on slower hosts). CI (`ubuntu-latest`) is native amd64. Rosetta
  keeps file descriptors 3–9 open in every process, so the image uses bash as
  `/bin/sh`: mmdebstrap hands apt a `cat >&<fd>` hook whose fd then exceeds 9,
  and dash cannot parse multi-digit redirections. The guest rootfs still uses
  Debian's default dash.

## Tests

```bash
# Static checks only: no docker daemon needed. Exits non-zero on any failure.
bash engine/image/tests/image_test.sh

# Static plus container checks; requires a built image and a running daemon.
bash engine/image/tests/image_test.sh --docker

# End-to-end: build a minimal Debian image and boot it, all inside the engine.
mkdir -p /tmp/engine-smoke
cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml \
  > /tmp/engine-smoke/plan.json
bash engine/image/tests/container_smoke.sh \
  --image sysemble-engine:0.1.0 \
  --repo "$PWD" \
  --out /tmp/engine-smoke
```

The smoke test prints `CONTAINER-SMOKE: pass` only after `artifact.json`,
`disk.img` (the raw UEFI boot target), `disk.qcow2`, and `boot-evidence.json`
exist, and prints their sha256 sums. QEMU runs under TCG (no `/dev/kvm` inside
the container), so the CI job does not need nested virtualization.

## CI

[`ci-snippet.yml`](ci-snippet.yml) is the `engine-check` job fragment for the
main `.github/workflows/ci.yml` (ubuntu-latest, 45 min): build, verify, plan,
container build + boot-check, upload evidence. The job is merged into the real
workflow as [`engine-check`](../../.github/workflows/ci.yml); this file is kept
as the frozen contract fragment.

## Known limits

- **apt drift.** The base image is pinned by digest and `SOURCE_DATE_EPOCH` is
  recorded, but `apt-get install` resolves packages from the live Debian mirror
  and records them only after the fact. The image is therefore **not
  bit-for-bit reproducible**; the manifest describes the image that was built,
  not a rebuild from the same inputs.
- **Image size.** QEMU, GRUB, and OVMF make the image roughly 120 MB compressed
  / 500 MB on disk in the 0.1.0 build. There is no registry distribution in this
  slice; the image is built locally (or in CI) and loaded into the local daemon.
- **No signing/SBOM.** cosign signatures and CycloneDX SBOMs are P3 work. The
  manifest is an internal record, not an attestation.
- **No native VM.** This is the container backend (E2a). Virtualization.framework
  / WSL2 helpers are E2c and are not promised here.
- **Host out only holds artifacts.** `container-entry.sh` exports top-level
  files only, so `rootfs/`, `build.log`, and the ISO staging tree stay in the
  container. Re-running with the same `--out` is fine (the container-local
  `rootfs/` disappears with the container); exported files are overwritten.
