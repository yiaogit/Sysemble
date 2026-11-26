# Rosetta for Linux spike (P1-e6a)

This directory holds the **guest-side** proof that a Sysemble arm64 VM can
translate x86_64 Linux ELFs with Apple Rosetta, plus the evidence we need to
choose the L2 packaging route (E6b). It is a spike, not a product feature.

- Plan and acceptance matrix: [`docs/plan/P1-e6a-workplan.md`](../../../docs/plan/P1-e6a-workplan.md)
- Host helper: [`engine/vm/macos`](../macos/README.md)
- Guest protocol: [`engine/vm/guest`](../guest/README.md)

## What it does

`rosetta-spike.sh` runs as root in the E3a Debian trixie arm64 guest. The macOS
host starts the VM with `sysemble-vm run --rosetta --job rosetta-spike.sh`,
which:

1. installs `binfmt-support` and `file` with apt over the VZ NAT network;
2. mounts the `rosetta` virtiofs share at `/mnt/rosetta` and checks
   `/mnt/rosetta/rosetta`;
3. registers the x86_64 ELF interpreter with `update-binfmts`, then asserts
   that `/proc/sys/fs/binfmt_misc/rosetta` is `enabled`;
4. executes the static `busybox-amd64` from `/export` and requires
   `uname -m` to print `x86_64`;
5. benchmarks 64 MiB `sha256sum` twice for native arm64 and twice through
   Rosetta, keeps the fastest run of each, prints the overhead ratio, writes
   `/export/rosetta-spike-summary.txt`, and ends with
   `ROSETTA-SPIKE: pass`. If an optional static **arm64** busybox is present at
   `/export/busybox-arm64`, it also prints a like-for-like
   `busybox_arm64` vs `busybox_amd64` ratio that isolates translation cost from
   the coreutils-vs-busybox implementation gap.

On failure it prints diagnostics (binfmt status, share listing, dmesg tail)
and exits 1. The guest agent stores the full output in
`<out>/.sysemble-vm/log`; the host keeps it as evidence.

## Host preparation

From the repository root:

```bash
# 1. Build and ad-hoc sign the helper (probe reports the rosetta status).
bash engine/vm/macos/build.sh
./engine/vm/macos/.build/release/sysemble-vm probe --json

# 2. Static amd64 busybox (Docker; the VM itself is not run in Docker).
rm -rf /tmp/e6a-out && mkdir -p /tmp/e6a-out
docker run --rm --platform linux/amd64 -v /tmp/e6a-out:/out debian:trixie bash -c '
  set -e
  apt-get update -qq
  cd /tmp && apt-get download busybox-static >/dev/null 2>&1
  dpkg-deb -x busybox-static_*.deb /tmp/x
  cp /tmp/x/usr/bin/busybox /out/busybox-amd64
  chmod 755 /out/busybox-amd64'
# Debian trixie ships it as /usr/bin/busybox (not /bin/busybox); `file` is not
# installed in the debian:trixie image, so check it on the macOS host instead:
file /tmp/e6a-out/busybox-amd64
# ELF 64-bit LSB executable, x86-64, statically linked

# 2b. Optional like-for-like control: the same Debian trixie busybox, arm64.
docker run --rm --platform linux/arm64 -v /tmp/e6a-out:/out debian:trixie bash -c '
  set -e
  apt-get update -qq
  cd /tmp && apt-get download busybox-static >/dev/null 2>&1
  dpkg-deb -x busybox-static_*.deb /tmp/x
  cp /tmp/x/usr/bin/busybox /out/busybox-arm64
  chmod 755 /out/busybox-arm64'
file /tmp/e6a-out/busybox-arm64
# ELF 64-bit LSB executable, ARM aarch64, statically linked

# 3. Plan.
CARGO_HOME="$PWD/../.tools/cargo" RUSTUP_HOME="$PWD/../.tools/rustup" \
  PATH="$PWD/../.tools/cargo/bin:$PATH" \
  cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml \
  > /tmp/e6a-out/plan.json

# 4. Stage the guest script.
cp engine/vm/spikes/rosetta-spike.sh /tmp/e6a-out/
chmod 755 /tmp/e6a-out/rosetta-spike.sh
```

## Run

```bash
./engine/vm/macos/.build/release/sysemble-vm run \
  --image-dir "$PWD/engine/vm/image/build" --repo "$PWD" \
  --out /tmp/e6a-out --plan /tmp/e6a-out/plan.json \
  --rosetta --job rosetta-spike.sh --timeout 1800 --json
```

`--rosetta` attaches a `VZLinuxRosettaDirectoryShare` as a third virtiofs
device (tag `rosetta`, next to `sysemble-repo` and `sysemble-out`). The helper
refuses to boot when
`VZLinuxRosettaDirectoryShare.availability != installed` and exits 3 with the
install hint. `probe --json` reports the same status as
`"rosetta": "installed|notInstalled|notSupported|unknown"`.

`--job rosetta-spike.sh` replaces the frozen guest build command with
`bash /export/rosetta-spike.sh`. It only accepts a basename of a file already
present in `--out`; it is a debugging/E6b override, not a general path
channel. Without `--job`, `job.sh` is byte-identical to P1-e3.

## binfmt registration

```bash
update-binfmts --install rosetta /mnt/rosetta/rosetta \
  --magic '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00' \
  --mask  '\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' \
  --credentials yes --preserve yes --fix-binary yes
```

- magic: `\x7fELF`, ELFCLASS64, little-endian, version 1, e_type and
  e_machine `EM_X86_64` (`\x3e\x00`). The e_type byte mask is `\xfe`, so it
  matches both `ET_EXEC` (`\x02\x00`) and `ET_DYN`/PIE (`\x03\x00`); the mask
  also ignores the OS/ABI byte, padding, and EI_VERSION's high bytes.
  **This spike only exercises a static `ET_EXEC` binary**; E6b must test the
  engine image's actual ELF type and ABI.
- `--fix-binary yes` (F flag) opens the interpreter at registration time, so
  `/mnt/rosetta` must be mounted first.
- `--credentials yes` (C) and `--preserve yes` (P) match Apple's Rosetta
  instructions.

The status file must start with `enabled`; the script fails otherwise.

## Local result (2026-11-26, developer Mac)

Host: macOS 26.6.2 arm64, 4 vCPU / 4 GiB VM, E3a image `0.1.0`
(kernel `6.12.118+deb13-arm64`), Debian trixie arm64 guest.

- `sysemble-vm run --rosetta --job rosetta-spike.sh --timeout 1800 --json`
  returned **rc=0**; the first (cold) run took 36.6 s end to end, a repeat run
  took 6.8 s (boot + apt + spike);
- `VZLinuxRosettaDirectoryShare.availability` = `installed`;
  `/mnt/rosetta/rosetta` mounted from virtiofs tag `rosetta`;
- `/proc/sys/fs/binfmt_misc/rosetta` was `enabled` with `flags: POCF`;
- `busybox-amd64 uname -m` printed `x86_64`;
- primary benchmark (coreutils `sha256sum` vs busybox-amd64):
  24.859 ms vs 264.241 ms = **10.63x** (`under_10x=no`);
- like-for-like control (busybox-arm64 vs busybox-amd64):
  183.966 ms vs 264.772 ms = **1.44x** (`under_10x=yes`).

The 10.63x is dominated by the implementation gap (coreutils uses the arm64
SHA extensions; Debian busybox uses a generic C digest), not by Rosetta. The
same-binary control is the number to use for translation overhead: **about
1.4x** on this CPU-bound workload. Both numbers are evidence, not a benchmark
suite; E6b should measure the real engine workload.

## Limitations

- **Developer Mac only.** GitHub-hosted macOS runners are themselves VMs and
  Apple does not support nested Virtualization.framework; CI cannot run this.
- **Rosetta must be installed on the host.** `softwareupdate --install-rosetta`
  (or `--agree-to-license`); `probe` tells you the status. It can also be
  disabled by MDM policy.
- **apt installs are per-run.** The helper clones `disk.img` to
  `<out>/vm-disk.img`; `binfmt-support`, `file` and the binfmt registration
  exist only in that clone. The E3a base image is unchanged.
- **Static test binary only.** This spike proves translation of a static
  x86_64 ELF. A dynamically linked amd64 engine needs amd64 libraries inside
  the container/guest (E6b).
- **Benchmark is indicative.** The primary ratio compares coreutils
  `sha256sum` (arm64, hardware SHA extensions) with busybox `sha256sum`
  (x86_64), so it mixes implementation and translation cost. The optional
  `busybox-arm64` control removes that gap; use it for the Rosetta overhead
  number and the primary ratio for the workplan's literal check.
- **No qemu control run.** If Rosetta is unavailable, the fallback is
  `apt-get install qemu-user-static` (its postinst registers qemu-x86_64 with
  binfmt-support). Static binaries then run, but dynamic amd64 containers
  still need their libraries, and qemu-user is typically slower than Rosetta.
  This spike only records that plan; it does not measure qemu unless Rosetta
  is unavailable.

## E6b: engine-in-VM (x86_64 build under Rosetta)

[`e6b-engine.sh`](e6b-engine.sh) is the follow-up spike: inside the arm64 guest
it installs podman, registers the Rosetta binfmt, loads the existing amd64
`sysemble-engine:0.1.0` OCI archive and runs
`engine/runtime/container-entry.sh` against a minimal x86_64 plan. It produced a
real `disk.qcow2` whose sha256 matches `artifact.json` (rc=0). See
[`e6b-engine.md`](e6b-engine.md) for timings, disk usage and the L2 conclusions
(12 GiB disk, `--network host`, preload the engine image in the VM image).
