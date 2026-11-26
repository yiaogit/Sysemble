# Engine-in-VM spike (P1-e6b)

**Verdict: feasible.** The existing amd64 `sysemble-engine:0.1.0` image runs
inside the arm64 Debian VM through podman + Apple Rosetta, and the frozen
entry point `engine/runtime/container-entry.sh` really builds the x86_64
minimal Debian qcow2. The run ended with rc 0, the host received
`artifact.json`, `disk.img`, `disk.qcow2`, `build.log` and the container logs,
and the host-side qcow2 sha256 matches `artifact.json`.

The guest-side driver is [`e6b-engine.sh`](e6b-engine.sh). This file records
how it is staged, the exact run, and the measured result. It is a developer-Mac
spike, not a product feature.

- Host helper: [`engine/vm/macos`](../macos/README.md)
- Guest protocol: [`engine/vm/guest`](../guest/README.md)
- Prior Rosetta proof: [`README.md`](README.md) (P1-e6a)

## Environment

| Item | Value |
|---|---|
| Host | macOS 26.6.2 arm64, 16 GiB RAM; load avg ≈ 2.4–2.8, 2.2 GiB swap in use |
| Repo | `65c99b2` |
| VM helper | `engine/vm/macos/.build/release/sysemble-vm` (`probe`: `rosetta=installed`) |
| VM image | `engine/vm/image/build` (6 GiB disk, kernel `6.12.118+deb13-arm64`, sha256 `bbde42f8…24a021`) |
| VM resources | 4 vCPU / 4096 MiB (helper defaults), disk cloned per run |
| Engine image | `sysemble-engine:0.1.0`, `linux/amd64`, 4 OCI layers |
| Plan | `examples/minimal-debian.yaml` → `x86_64`, 14 packages, qcow2 |

The host exports the image with Docker's current containerd-backed `save`
format: an **OCI archive** with `index.json`/`oci-layout`/`blobs/` plus a
compatibility `manifest.json`:

```text
/tmp/e6b-out/engine-image.tar   119,632,384 bytes (114 MiB)
```

Podman 5.4.2 loads it directly and reports the unpacked image as 379 MB.
Docker's own `docker images` shows 516 MB of layer accounting, while the
transferable OCI archive is 114 MiB (gzip-compressed layers).

## Host preparation

From the repository root:

```bash
rm -rf /tmp/e6b-out && mkdir -p /tmp/e6b-out

# 1. x86_64 plan
CARGO_HOME="$PWD/../.tools/cargo" RUSTUP_HOME="$PWD/../.tools/rustup" \
  PATH="$PWD/../.tools/cargo/bin:$PATH" \
  cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml \
  > /tmp/e6b-out/plan.json

# 2. The already-built engine image
docker save sysemble-engine:0.1.0 -o /tmp/e6b-out/engine-image.tar

# 3. Guest script (the helper's --job only accepts a basename inside --out)
cp engine/vm/spikes/e6b-engine.sh /tmp/e6b-out/
chmod 755 /tmp/e6b-out/e6b-engine.sh
```

## Run

```bash
./engine/vm/macos/.build/release/sysemble-vm run \
  --image-dir "$PWD/engine/vm/image/build" --repo "$PWD" \
  --out /tmp/e6b-out --plan /tmp/e6b-out/plan.json \
  --rosetta --job e6b-engine.sh --timeout 3600 --json
```

The helper's JSON result:

```json
{
  "done" : true,
  "elapsed_seconds" : 435.395,
  "job" : "e6b-engine.sh",
  "log_path" : "/tmp/e6b-out/.sysemble-vm/log",
  "rc" : 0,
  "ready" : true,
  "rosetta" : true,
  "serial_log" : "/tmp/e6b-out/vm-serial.log",
  "work_dir" : "/tmp/e6b-out/.sysemble-vm"
}
```

`real 7m15.665s`, rc 0. The full guest output is
`/tmp/e6b-out/.sysemble-vm/log`; the build log is `/tmp/e6b-out/build.log`.

## What the guest script does

1. `apt-get update` + install `podman binfmt-support file` from trixie over the
   VZ NAT network (5.06 s), then cleans apt lists/cache to preserve the 6 GiB
   guest disk.
2. `modprobe overlay`, asserts podman's storage driver is **overlay** (no vfs
   fallback was needed).
3. Mounts the `rosetta` virtiofs share at `/mnt/rosetta` and registers
   `/mnt/rosetta/rosetta` with `update-binfmts` (magic/mask for x86-64 ELF,
   `--credentials yes --preserve yes --fix-binary yes`). The entry is
   `enabled`, `flags: POCF`.
4. `podman load -i /export/engine-image.tar` (2.47 s) and checks
   `amd64 linux`; `podman run … uname -m` prints `x86_64`, proving Rosetta is
   active inside the container. A DNS smoke test resolves
   `deb.debian.org` through the guest's `127.0.0.53` stub resolver.
5. Runs the frozen entry point with podman:

   ```bash
   podman run --name e6b-engine --privileged --network host \
     --platform linux/amd64 \
     -v /work:/work:ro -v /export:/export \
     sysemble-engine:0.1.0 \
     bash /work/engine/runtime/container-entry.sh \
       --plan /export/plan.json --out /out --export /export --mode execute
   ```

   The task's command used `--rm`; this script uses `--name` instead so it can
   copy the container-local `/out/build.log` (the frozen entry point
   deliberately does not export it), then removes the container with
   `podman rm -f`. Every other option matches. The container-external job log
   alone would still contain the whole build output if `--rm` were kept.
6. Copies `build.log`, `podman logs`, `podman inspect`, `podman system df`;
   removes the container; computes the qcow2 sha256 on the guest and compares
   it with `artifact.json`.
7. Writes `/export/e6b-summary.txt` and a 10-second `df` monitor
   `/export/e6b-df.log`; prints `E6B: pass`.

## Result

### Artifacts on the host (`/tmp/e6b-out`)

| File | Size | Notes |
|---|---|---|
| `artifact.json` | 1,340 B | `arch=x86_64`, `boot.mode=uefi`, 14 packages |
| `disk.img` | 4,294,967,296 B apparent / 991 MiB allocated | GPT: p1 512 MiB vfat ESP, p2 3584 MiB ext4 |
| `disk.qcow2` | 420,937,728 B (402 MB) | `QFI\xfb` qcow2 magic |
| `build.log` | 4,278 B | copy of the container's `/out/build.log` |
| `podman-container.log` | 4.5 KB | `podman logs` of the build container |
| `podman-inspect.json` | 16 KB | `privileged=true`, `network=host`, exit 0 |
| `podman-system-df.txt` | 247 B | image 378.7 MB; container 5.092 GB apparent |
| `e6b-summary.txt` | 819 B | machine-readable guest timings/disk |
| `e6b-df.log` | 5.1 KB | 10 s `df` samples |

`container-entry.sh` also exported `grub.cfg` and `plan.copy.json`; those are
top-level regular files, so the frozen export loop copies them too.

### artifact.json (key fields)

```json
"arch": "x86_64",
"rootfs": {"size_mb": 389},
"images": [
  {"path": "disk.img",   "format": "raw",   "size_mb": 4096, "sha256": "0c13ea82109dfe9ff1685863fb5a2ecf4892cd4bb1fea451820e6606c1434f78"},
  {"path": "disk.qcow2", "format": "qcow2", "size_mb": 402,  "sha256": "1c8dfc80376bf8c89641e637b2fdef4f65a5ea66281ce2be41a05b208f2e6b7e"}
],
"boot": {"mode": "uefi", "kernel": "rootfs/boot/vmlinuz-6.12.118+deb13-amd64",
         "initrd": "rootfs/boot/initrd.img-6.12.118+deb13-amd64",
         "graphical": false, "memory_mb": 1024},
"partitions": [
  {"index": 1, "role": "esp",  "size_mb": 512,  "fs": "vfat32"},
  {"index": 2, "role": "root", "size_mb": 3584, "fs": "ext4"}
]
```

Both hashes were recomputed independently on the host with Python:

```text
disk.img    artifact=0c13ea82…34f78 actual=0c13ea82…34f78 match=True
disk.qcow2  artifact=1c8dfc80…e6b7e actual=1c8dfc80…e6b7e match=True
```

The guest had already recomputed the qcow2 hash over virtiofs and compared it
with the same artifact value before printing `E6B: pass`.

### Container build (from `build.log`)

```text
[build] stage 3/6: bootstrap rootfs - /out/rootfs
I: success in 151.4692 seconds
[build] stage 5/6: assemble GPT disk image - rootfs 389 MB, disk 4096 MB
[build] root fs: 916992 x 4 KiB blocks (explicit size keeps ext4 inside p2/GPT)
  $ mkfs.ext4 -F -b 4096 -E offset=537919488 -d /out/rootfs -L SYMBLE /out/disk.img 916992
  $ dd if=/out/esp.img of=/out/disk.img bs=1M seek=1 conv=notrunc
  $ qemu-img convert -O qcow2 /out/disk.img /out/disk.qcow2
[build] complete (mode: uefi)
container-entry: exported artifact.json
container-entry: exported disk.img
container-entry: exported disk.qcow2
container-entry: exported grub.cfg
container-entry: exported plan.copy.json
container-entry: build and export complete
```

Podman details: `podman version 5.4.2`, storage driver **overlay**,
`podman load` **2.47 s**, image `localhost/sysemble-engine:0.1.0`
`amd64 linux` `6d5fbbb96e2a`. The container was `--privileged`,
`--network host`, mounts `/work` read-only and `/export` read-write, and
exited 0. Container `uname -m` = `x86_64`; Debian 13.8; DNS resolved.

### Guest disk

| Point | Used | Available |
|---|---|---|
| Before (base image) | 528 MiB | 4.99 GiB |
| After apt + image load | 1.1 GiB | 4.5 GiB |
| **Peak during build** | **2.80 GiB** | **2.71 GiB** |
| After container removal | 1.07 GiB | 4.43 GiB |

`podman system df` while the container existed: image 378.7 MB, container
5.092 GB *apparent* (the 4 GiB sparse `disk.img` plus rootfs/qcow2), all
reclaimable. `/var/lib/containers/storage` was 2.1 GB on disk. The raw image
stayed sparse in the container and on the host (`du` 991 MiB for a 4 GiB
file).

**6 GiB is sufficient for this minimal plan**, with about 2.7 GiB free at the
peak, but the headroom is thin for larger plans (desktop/ISO, bigger rootfs,
more packages, another container layer). For L2 packaging use **12 GiB** (or a
separate data disk) as recommended in the brief.

### Timings and the guest-clock caveat

Guest-measured (`e6b-summary.txt`):

| Stage | Guest clock |
|---|---|
| apt install podman + binfmt-support + file | 5.060 s |
| `podman load` | 2.471 s |
| `podman run` (mmdebstrap + disk + export) | 167.010 s |
| Guest script total | 176.225 s |
| mmdebstrap internal | 151.4692 s |

Host wall: **435.395 s** (7m15.7s), rc 0. The container started at
guest-clock 00:06:41, when the 10 s monitor was still host-aligned
(guest 00:06:33 vs host file birth 00:06:32), and the host first saw the
exported artifacts at 00:13:42. The container's wall time was therefore
**≈421 s**, not the 167 s the guest reported. The guest summary's
`created=2026-11-26T00:09:29Z` while the host finished at
`2026-11-26T00:13:45Z`; over the run the guest clock advanced 176 s while
435 s of host wall passed (**≈0.40x**). This was a background/headless run on
a 16 GiB Mac already using 2.2 GiB of swap and host load ≈2.7; this is
consistent with macOS background scheduling/paging throttling the VM, with
the guest's virtual clock advancing only while the VM actually ran. The
functional result is unaffected, but **guest `date` is not a wall clock
here**:

- treat **435 s** as the end-to-end wall time;
- the container's guest-side 167 s (mmdebstrap 151.5 s) is VM-active time;
- the artifact timestamps are guest-clock timestamps, so
  `createdAt=00:09:17Z` is ~4 minutes behind host wall.

The export itself was not the delay: the host-created `disk.img` was born at
00:13:42.8 and finished at 00:13:43.8, and `disk.qcow2` at 00:13:43.5–44.4
(roughly 2 s for a 4 GiB apparent / 991 MiB allocated raw image plus 402 MB
qcow2, with APFS keeping the raw image sparse). The multi-minute wall gap
therefore reflects the VM/guest clock running at ≈0.40x wall, not virtiofs
throughput.

For comparable L2 timings, run the helper in the foreground (or hold a macOS
`ProcessInfo.beginActivity`/power assertion), measure on the host, and do not
use guest `date` for stage timing.

### Comparison with P1-e2

| Path | Build time | Notes |
|---|---|---|
| CI native amd64 (`engine-check`) | ≈88 s | P1-e2 reference |
| Local Docker Desktop container | ≈2–3 min | P1-e2 reference |
| This VM, Rosetta, guest-active | **167 s** container run / **151.5 s** mmdebstrap | same plan and engine image |
| This VM, `podman run` host wall | **≈421 s** | derived from container start and host artifact birth; the guest clock ran at ≈0.40x wall in this background run |
| This VM, host wall E2E | **435 s** | includes boot, apt, image load, build, export; VM throttled |

In VM-active terms the engine work (151.5 s mmdebstrap, 167 s container run)
is in the same range as the local Docker build and ≈1.7–1.9x the CI build.
The host-visible `podman run` was ≈421 s (2.3–3.5x the local container,
≈4.8x CI) because this background run's guest clock ran at ≈0.40x wall.
Rosetta itself is not the limiting factor (E6a measured ≈1.4x translation
overhead on a like-for-like binary); the wall penalty is VM scheduling/paging.
A foreground, power-asserted run is expected to land closer to the VM-active
number.

## Findings for L2 packaging

1. **Feasible route.** Preinstall `podman` (5.4.x), `binfmt-support`, `file`,
   `crun`/`conmon`/`containers-common` in the VM image; mount the Rosetta
   virtiofs share at boot and register the x86_64 interpreter before any
   container starts. The helper already attaches the share with `--rosetta`.
2. **Storage.** Podman rootful + overlay on the guest ext4 works with no extra
   configuration; no `vfs`/`storage.conf` fallback was needed. The loaded
   image is 379 MB and fits comfortably.
3. **Image transport.** A Docker `save` OCI archive loads directly with
   `podman load` (2.5 s for 114 MiB). No registry, no `skopeo`, no conversion
   step was needed.
4. **Networking.** Use `--network host` (the frozen desktop engine command
   already does). Podman's default bridge fails on the stock guest with
   `netavark: nftables error: unable to execute nft: No such file or
   directory` because trixie's `podman` does not pull the `nft` binary. Add
   `nftables` only if bridge networking is required; host networking avoids
   netavark/slirp entirely.
5. **Privileges/platform.** `--privileged` + `--platform linux/amd64` works;
   seccomp/privilege restrictions are not an issue for this build path. The
   container's `/work` is the read-only repo; `/out` stays container-local
   (case-sensitive) as the frozen contract requires; only top-level artifacts
   go to `/export`.
6. **Cleanup.** Stop/remove the build container after copying `build.log`.
   The stock podman starts a `netavark firewalld-reload` helper daemon that
   survives `podman rm` inside the guest; it is inside the disposable VM
   clone, but a packaged engine should `pkill -f /usr/lib/podman/netavark` (or
   use a transient unit) before reporting "no leftover processes".
7. **Timing.** The guest's virtual clock can lag badly while the VM is
   throttled; the host must own the wall clock and hold an activity/power
   assertion during long builds. The 4 GiB raw artifact is large; on this run
   the host-side copy took about 2 s and stayed sparse, but for larger plans
   prefer qcow2-only export or a separate data disk.
8. **Disk sizing.** 6 GiB is enough for the minimal qcow2 plan (peak 2.80 GiB
   used), but **12 GiB** is the right packaging default for desktop/ISO
   plans and to avoid a hard 6 GiB ceiling. Do not enlarge the frozen E3a base
   image in this spike; that is an image-build decision.
9. **Kernel noise.** `evm: overlay not supported` appears once in the serial
   log when podman first mounts overlay; it is benign (EVM is not enabled) and
   overlay worked.

## Regression / hygiene

- **Base image untouched**: `engine/vm/image/build/disk.img` sha256
  `bbde42f8277c71f686585a9946ec39d8b4790b218c50989932bb05c92124a021` before
  and after, equal to `sysemble-vm.json` `disk.sha256`. The helper's APFS clone
  (`/tmp/e6b-out/vm-disk.img`) received all apt/podman/build writes.
- **No host residual processes**: `pgrep -fl sysemble-vm` is empty after the
  run. The helper's background job finished cleanly.
- **Scope**: only `engine/vm/spikes/e6b-engine.sh` and this file were added.
  No changes under `.github/`, `docs/`, `README.md`, `apps/`, `builders/`,
  `engine/image/`, `engine/vm/guest/`, `engine/vm/macos/` or
  `engine/vm/image/`; no git commit/add/checkout was performed. (Read-only
  `git rev-parse`/`git status` were used to record HEAD and the final diff.)
- The guest's only leftover was the podman `netavark` helper daemon noted
  above, inside the stopped VM clone; the build container itself was removed
  (`podman ps -a` empty).

## Limitations

- One plan (`minimal-debian`, qcow2 only), one arch target (`x86_64`), one
  run. No boot test was run; P1-e2's boot-check is a separate path. The
  artifact was built and hash-verified, not booted.
- Developer Mac only: GitHub-hosted macOS runners cannot nest
  Virtualization.framework, so CI cannot run this spike.
- The 6 GiB disk is sufficient here; larger plans need the 12 GiB decision.
- Guest timings are distorted by background VM throttling (see above); the
  host elapsed is the number to quote.
