# Sysemble macOS VM helper (P1-e3b)

`sysemble-vm` is the macOS side of the P1-e3 prototype: a single,
dependency-free SwiftPM executable that boots the E3a Linux image with
**Virtualization.framework**, exposes the repository and the output directory
over virtiofs, and speaks the file-based job protocol frozen in
[`docs/plan/P1-e3-workplan.md`](../../../docs/plan/P1-e3-workplan.md) sections
2.2 and 2.3.

It is deliberately **not** a daemon, SSH server, or desktop integration. One
process runs one VM and then exits with the guest's exit code. The Tauri shell
and distribution signing are P1-e4 work.

## Requirements

- macOS 13 or newer, Apple Silicon (`arm64`). The E3a guest image is arm64-only;
  Virtualization.framework cannot run an arm64 guest on an Intel Mac.
- Xcode Command Line Tools with Swift 5.9+ and `codesign`
  (tested with Swift 6.4 on macOS 26.6.2).
- The runtime `com.apple.security.virtualization` entitlement. `build.sh`
  ad-hoc signs the binary with it; an unsigned process fails `validate()` with
  an entitlement error.
- For `run` only: an E3a image (`engine/vm/image/build/`), an E3a guest script
  (`engine/vm/guest/minimal-build.sh`), and a `plan.json`.

The deployment target is `.macOS(.v13)`. The Linux-VM APIs used here are
available by macOS 12, but `probe` consults `VZVirtualMachine.isSupported`
only inside `#available(macOS 14, *)`; on macOS 13 `probe --json` reports
`"supported": "unknown"` and explains why. `run` does not depend on that query:
it lets `VZVirtualMachineConfiguration.validate()` decide.

## Build and sign

```bash
bash engine/vm/macos/build.sh          # release
bash engine/vm/macos/build.sh --debug  # debug configuration
```

The script:

1. runs `swift build -c release` (or `debug`) for this package;
2. `codesign --force --sign - --entitlements sysemble-vm.entitlements` on the
   product, i.e. an **ad-hoc** signature carrying
   `com.apple.security.virtualization`;
3. verifies the signature with `codesign --verify`, checks that
   `codesign -d --entitlements -` contains the entitlement, prints the
   entitlements and the absolute binary path.

The default product is `.build/release/sysemble-vm` (a SwiftPM symlink into
`.build/out/Products/Release/`). `.build/` is gitignored by the local
`.gitignore`. Rebuilding replaces the signature, so always run `build.sh`
rather than a bare `swift build` before `probe`/`run`.

`build.sh` pins clang's module cache to `.build/clang-module-cache` and passes
`--disable-sandbox` to SwiftPM. The package has no dependencies or build
plugins, so SwiftPM's build sandbox has nothing to isolate; this also lets the
build run when the script itself is inside a sandbox. Neither choice affects
the produced binary.

## probe

```bash
./engine/vm/macos/.build/release/sysemble-vm probe
./engine/vm/macos/.build/release/sysemble-vm probe --json
```

Real output on the development Mac (macOS 26.6.2, arm64):

```json
{
  "arch" : "arm64",
  "cpus" : 10,
  "entitled" : true,
  "macos" : "26.6.2",
  "reason" : "ok: Virtualization.framework is supported and VZVirtualMachineConfiguration.validate() accepted the signature.",
  "rosetta" : "installed",
  "supported" : true
}
```

| Field | Type | Meaning |
|---|---|---|
| `supported` | boolean, or `"unknown"` on macOS < 14 | `VZVirtualMachine.isSupported`; false on a host that cannot virtualize (e.g. a CI runner). |
| `entitled` | boolean | `VZVirtualMachineConfiguration.validate()` accepted a minimal Linux VM configuration built from 1 MiB throw-away kernel/initrd/disk files. `false` means the signature/entitlement was rejected. |
| `arch` | string | `uname -m` (`arm64` on Apple Silicon). |
| `macos` | string | Host macOS version, e.g. `26.6.2`. |
| `cpus` | number | `ProcessInfo.processorCount`. |
| `rosetta` | string | `VZLinuxRosettaDirectoryShare.availability`: `installed`, `notInstalled`, `notSupported`, or `unknown`. This host-capability query does not need the virtualization entitlement or a VM. |
| `rosetta_reason` | string, optional | Present when `rosetta` is `unknown` (and when the test override is active). Explains why the status could not be determined. |
| `reason` | string | Human-readable explanation; `ok: ...` only when supported and signed and Rosetta is installed. |

The entitlement check creates a temporary configuration with
`VZLinuxBootLoader` + `VZDiskImageStorageDeviceAttachment`, calls `validate()`,
and deletes the temporary directory. **No VM is started.** `probe` always exits
0 (except for invalid arguments): it is a diagnostic, not a gate. On CI it is
expected to report `supported=false`; that is not a test failure.

What `entitled=true` means: `validate()` did not reject the code signature. If
the host cannot virtualize, the probe reports that as a `reason` note instead of
blaming the signature. It is still possible for a managed/MDM Mac to reject an
ad-hoc entitlement at `VZVirtualMachine` start time even though `validate()`
passed; `run` then exits 4 with the framework's error and the serial log.

### Rosetta for Linux (`--rosetta`, P1-e6a)

`run --rosetta` first checks
`VZLinuxRosettaDirectoryShare.availability` and only continues when it is
`installed`; otherwise it exits 3 with a readable message:

- `notInstalled`: run `softwareupdate --install-rosetta` (add
  `--agree-to-license` for a non-interactive install);
- `notSupported`: the host cannot run Rosetta for Linux (hardware, OS policy,
  or MDM), so x86_64 translation is not available;
- `unknown`: the status could not be read; the message carries the reason.

When it proceeds, the helper adds a `VZLinuxRosettaDirectoryShare` as a third
virtiofs device with tag `rosetta` (next to `sysemble-repo`/`sysemble-out`).
Nothing is mounted in the guest automatically: the guest job mounts tag
`rosetta` itself and registers the interpreter with `binfmt_misc`. The
end-to-end proof is
[`engine/vm/spikes/rosetta-spike.sh`](../spikes/rosetta-spike.sh).

For tests only, `SYSEMBLE_VM_TEST_ROSETTA_AVAILABILITY` can force
`installed|notInstalled|notSupported|unknown` in both `probe` and `run`. This is
how the failure branches are exercised without uninstalling Rosetta; it is not
used by the helper or the desktop app.

## run

```bash
# 1. Produce a plan for the E3a guest.
mkdir -p out/vm
cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml > out/vm/plan.json

# 2. Boot the image, share the repo/out, run the guest job, return its rc.
./engine/vm/macos/.build/release/sysemble-vm run \
  --image-dir engine/vm/image/build \
  --repo "$PWD" \
  --out out/vm \
  --plan out/vm/plan.json
```

Options (matching workplan section 2.3):

| Option | Default | Meaning |
|---|---|---|
| `--image-dir <dir>` | required | Directory with `disk.img`, `vmlinuz`, `initrd.img` (E3a). |
| `--repo <dir>` | required | Repository shared read-only at `/work`. Must contain `builders/debian/build.sh` and `engine/vm/guest/minimal-build.sh`. |
| `--out <dir>` | required | Host output directory shared read-write at `/export`; created if missing. |
| `--plan <plan.json>` | required | Copied to `<out>/plan.json` (guest sees `/export/plan.json`). |
| `--cpus N` | `4` | vCPU count; validated against VZ's allowed range. |
| `--memory-mb N` | `4096` | Guest memory; validated against VZ's allowed range. |
| `--ready-timeout N` | `180` | Seconds to wait for `.sysemble-vm/ready`. |
| `--timeout N` | `1800` | Seconds to wait for `.sysemble-vm/done` after dispatch. |
| `--no-clone` | off | Use `<image-dir>/disk.img` in place instead of cloning to `<out>/vm-disk.img`. |
| `--rosetta` | off | Check `VZLinuxRosettaDirectoryShare.availability`; only `installed` proceeds (otherwise exit 3) and a virtiofs share with tag `rosetta` is attached. |
| `--job <name>` | off (frozen build) | Run `bash /export/<name>` instead of the frozen guest build. `<name>` must be a basename of a regular file in `--out`; no `/`, `.`, or `..`. Debug/E6b override. |
| `--dry-run` | off | Validate inputs, prepare `--out`, publish and print `job.sh`, then exit 0 before cloning a disk or starting a VM. |
| `--json` | off | Print a structured result object on stdout instead of the human log tail. Diagnostics stay on stderr. |

By default the disk is cloned to `<out>/vm-disk.img` with `cp -c` (APFS
copy-on-write) and falls back to a full `FileManager` copy if cloning is not
available. The E3a `disk.img` is a 6 GiB sparse raw ext4 image; cloning is cheap
but guest writes consume space on the out volume. `--no-clone` skips the clone
and lets the guest write directly to the image, so only use it on a disposable
image.

### Host/guest paths

| Host | Guest | Share | Access |
|---|---|---|---|
| `<repo>` | `/work` | virtiofs tag `sysemble-repo` | read-only |
| `<out>` | `/export` | virtiofs tag `sysemble-out` | read-write |
| Rosetta | `/mnt/rosetta` (guest-chosen) | virtiofs tag `rosetta` | read-only, only with `--rosetta` |
| — | `/out` | guest raw ext4 disk | guest-internal build directory |

The helper adds **no host paths** to the guest. The kernel command line is
fixed, the attached disk is a block device, and the job script contains only
guest paths. The guest builds on its own case-sensitive ext4 `/out` and copies
only top-level artifacts to `/export`, avoiding APFS case-collision problems.

### Protocol

The host prepares `<out>/.sysemble-vm/` (removing stale `ready`, `done`,
`job.sh`, `job.sh.tmp`, `log`) and writes `<out>/plan.json`. It never writes
the guest's `ready`, `log`, or `done`.

| File | Direction | Contract |
|---|---|---|
| `.sysemble-vm/ready` | guest → host | Written by `sysemble-vm-agent.service` once shares are mounted. Presence starts the job phase. |
| `.sysemble-vm/job.sh` | host → guest | Published atomically (`job.sh.tmp` + `rename`). Default exact content:<br>`bash /work/engine/vm/guest/minimal-build.sh --plan /export/plan.json --out /out --export /export`<br>With `--job <name>`: `bash /export/<name>` (one line). |
| `.sysemble-vm/log` | guest → host | Full stdout/stderr of `job.sh` (redirected by the guest agent). |
| `.sysemble-vm/done` | guest → host | One line: the guest exit code. |
| `vm-serial.log` | guest → host | Virtio console output; input side is `/dev/null`. Truncated at the start of each run. |

On success the host reads `done`, prints the last 100 lines of `log` (human
mode; `--json` omits the log body and reports `log_path`), stops the VM with
`stop()` and waits for the stopped state before exiting with the guest's code.
Full logs stay on disk as evidence.

### JSON result

```json
{
  "done" : true,
  "elapsed_seconds" : 215.705,
  "job" : "minimal-build.sh",
  "log_path" : "/Users/me/sysemble/out/vm/.sysemble-vm/log",
  "rc" : 0,
  "ready" : true,
  "rosetta" : false,
  "serial_log" : "/Users/me/sysemble/out/vm/vm-serial.log",
  "work_dir" : "/Users/me/sysemble/out/vm/.sysemble-vm"
}
```

Paths above are illustrative; the scalar fields are from the local E2E run
described below.

`rc` is the value read from `done`, or the helper's failure code (3/4/130/143).
`ready`/`done` say whether each protocol milestone was observed; they are
booleans even on failure. `elapsed_seconds` is wall time from the start of the
run (from VM start once a VM exists) to the result, rounded to milliseconds.
`job` is the effective job name (the frozen `minimal-build.sh` or the `--job`
override) and `rosetta` is the boolean `--rosetta` switch.
An `error` string is added on failures after argument parsing, including path
errors before a VM exists. Usage errors (exit 2) are plain text on stderr, with
no JSON object. Diagnostics (serial/guest log tails) go to stderr so stdout
stays valid JSON. With `--dry-run --json` the object is
`{"dry_run": true, "rc": 0, "job": ..., "job_path": ..., "rosetta": ..., "work_dir": ...}`.

### Local E2E status

On 2026-11-24, a developer Mac (macOS 26.6.2, arm64, 4 vCPU / 4 GiB) ran the
helper twice against E3a image `0.1.0` with
`--ready-timeout 180 --timeout 900 --json`. Both runs returned guest
**rc=0**:

- VM reached `ready` about 1.7 s after start; `done` arrived after 92.5 s and
  215.7 s respectively (mmdebstrap took 76 s vs 165 s; package download
  dominates). The serial log shows `virtio_blk ... [vda] ... 6.00 GiB`, systemd
  on arm64, and both virtiofs mounts;
- the frozen builder ran `--dry-run` against the read-only `/work` share
  (`builder_dry_run=pass`), then `mmdebstrap` 1.5.7 built the arm64 rootfs
  (19,301 entries) and exported `rootfs.tar.gz` (about 246.4 MB) plus
  `artifact-vm.json`;
- the host recomputed the tar sha256 for each run and it matched the
  corresponding `rootfs.tar.gz.sha256` (for the final run,
  `1ee9d6b4d3d58af11ad1f65ff33a51e1cb13a297ffb6b16f0a7f7871adad1b58`);
- `disk.img` was APFS-cloned to `vm-disk.img` (6 GiB logical, 1.5 GiB
  allocated) and the VM was stopped cleanly after each `done`.

Failure paths were exercised on the same image: a 1 s ready timeout exited 4
with `rc=4` in JSON and preserved the serial log; SIGINT and SIGTERM stopped
the VM and exited 130/143; an ad-hoc re-sign without the entitlement made
`run` exit 4 with the entitlement hint before a VM existed; and a deliberately
invalid plan returned the guest's `rc=1` (with the builder validation error in
`.sysemble-vm/log`). This was a developer Mac, not a CI runner. See the
workplan acceptance matrix V3-V8.

### Rosetta for Linux E2E (P1-e6a)

On 2026-11-26 the same developer Mac ran the P1-e6a spike with
`--rosetta --job rosetta-spike.sh --timeout 1800 --json`. The helper reported
`rosetta=installed`, attached the share, and the guest proved:

- `/mnt/rosetta/rosetta` mounted from virtiofs tag `rosetta`;
- `/proc/sys/fs/binfmt_misc/rosetta` was `enabled` with `flags: POCF`;
- `busybox-amd64 uname -m` printed `x86_64`;
- 64 MiB `sha256sum`: 24.859 ms native arm64 vs 264.241 ms through Rosetta
  (10.63x, over the workplan's 10x warning line); the like-for-like
  busybox-arm64 vs busybox-amd64 control was 183.966 ms vs 264.772 ms
  (**1.44x**), so the raw ratio is mostly the coreutils-vs-busybox digest
  implementation gap, not translation.

The run returned **rc=0**; the cold run took 36.6 s and a repeat took 6.8 s
end to end. `pgrep -fl sysemble-vm` showed no leftover helper. Details and the
reproduction script are in [`engine/vm/spikes`](../spikes/README.md).

### Exit codes

| Code | Meaning |
|---|---|
| `0` | success (probe: always, unless arguments are invalid) |
| `2` | usage error: unknown/missing option, bad number, out of VZ range, `--out /`, bad `--job` basename |
| `3` | image/path error: missing `disk.img`/`vmlinuz`/`initrd.img`, repo scripts, plan; unreadable/clone-failed disk; bad `--out`; `--job` file missing; `--rosetta` with Rosetta not installed/not supported/unknown |
| `4` | VM lifecycle: configuration rejected, start failure, `ready` timeout, `done` timeout, unreadable `done` |
| `n` | the guest's exit code (0–255 as seen by the shell) |
| `130` / `143` | SIGINT / SIGTERM: `stop()` is called and the VM is waited for before exiting |

Timeouts stop the VM and preserve `vm-serial.log`, the guest `log`, and any
partial exports.

## Tests

```bash
bash engine/vm/macos/tests/vm_test.sh
```

The default suite (46 checks on this host) never starts a VM:

- `probe --json` schema/types, host arch/macOS, self-consistency, exit 0;
- `probe` `rosetta` field and the forced `installed/notInstalled/notSupported/
  unknown` mapping (including `rosetta_reason` for `unknown`);
- human `probe` fields;
- `--help`/`run --help` exit 0; unknown/missing options exit 2;
- `run` path validation with synthetic image/repo trees exits 3 (missing
  image-dir, missing `disk.img`, missing guest script, missing plan, bad disk
  size, `--out` is a file);
- `run --rosetta` exits 3 with the right hint for notInstalled/notSupported/
  unknown, and proceeds when installed;
- `--job` basename validation (slash/`..`/empty exit 2, missing or directory
  file exit 3) and the exact `job.sh`/stdout override;
- `--dry-run` keeps the frozen default job and does not clone a disk;
- `--json` error object contract (`rc=3`, required fields);
- `codesign --verify` and the virtualization entitlement;
- `bash -n` for the shell scripts, including the Rosetta spike.

`--boot` adds an opt-in E2E smoke test (3 more checks, 49 total when it runs).
It is **skipped by default** and only runs when `engine/vm/image/build/` has a
complete E3a image and the E3a guest script exists:

```bash
bash engine/vm/macos/tests/vm_test.sh --boot --plan out/vm/plan.json
```

The suite prints `VM helper tests: N passed, M failed, K skipped` and exits
non-zero only on failures. CI runs the default mode.

## CI

[`ci-snippet.yml`](ci-snippet.yml) is the `vm-helper` job fragment for the main
workflow (`macos-15`, 30 min): build + ad-hoc sign, `probe --json`, static
tests. The fragment is merged into the real workflow by the P1-e3 integration
slice; this copy is the frozen reference.

GitHub-hosted macOS runners are themselves Virtualization.framework guests and
Apple does not support nested virtualization, so the CI job **never** calls
`run`. `probe --json` is expected to report `supported=false` there; build,
signature, and probe still prove V3.

## Known limits

- **No VM in CI.** Real boot is verified on a developer Mac (and the independent
  acceptance Mac), not on `macos-15` runners. Do not turn the CI job into a boot
  gate.
- **arm64 guest only.** The E3a image is an arm64 Debian rootfs and the helper's
  device set has no UEFI/GRUB path. This prototype does not boot an x86_64
  kernel; with `--rosetta`, x86_64 *userland* binaries run under translation
  inside the arm64 guest (P1-e6a spike), while the P1-e2 container backend
  remains the native x86_64 path.
- **Rosetta needs the host install.** `--rosetta` exits 3 unless
  `VZLinuxRosettaDirectoryShare.availability` is `installed`; the install is a
  host-wide action (`softwareupdate --install-rosetta`) that may be blocked by
  MDM. CI runners cannot run the spike (no nested virtualization), so Rosetta
  evidence is local-only.
- **Ad-hoc entitlement only.** The binary is signed ad-hoc, not with a Developer
  ID and not notarized. Managed Macs or future OS policy may reject it. This is
  local-development signing, not a distribution mechanism.
- **No image verification.** `run` checks that the image files exist, are
  non-empty, and that `disk.img` is 512-byte aligned. It does not verify the
  manifest `sha256` values; that is `image_test.sh --verify` (E3a).
- **Guest artifacts are not bit-reproducible.** Two local runs had the same
  19,301 rootfs entries but different `rootfs.tar.gz` bytes/hashes because
  mmdebstrap embeds timestamps. The helper returns the guest's exit code and
  exports whatever the guest wrote; it does not claim reproducibility.
- **Shared filesystem semantics.** virtiofs shares sit on APFS (case-insensitive
  by default). The protocol uses ASCII filenames and the guest builds in
  `/out`, but arbitrary case-colliding paths must not be written to `/export`.
- **`--no-clone` is destructive.** The guest writes to the original image.
- **`--job` runs a host-provided script as root.** It is an explicit debug/E6b
  override, not a sandbox: the helper only requires a basename that exists in
  `--out`, and the script has the same root access as the frozen build. Do not
  pass untrusted names.
- **`--dry-run` is not a build.** It leaves `plan.json` and
  `.sysemble-vm/job.sh` in `--out` but starts no VM and produces no artifacts.
- **No snapshots, SSH, vsock, graphics, or resume.** Serial and the four
  protocol files are the entire guest interface.
- **Logs are unbounded.** `vm-serial.log` and `.sysemble-vm/log` are kept in
  full; the helper only tails them (100 guest lines, 40 serial lines on
  failures). A very chatty job can fill the host disk.
- **One VM per process.** Resource limits (CPU/memory ranges) come from
  Virtualization.framework and vary by host.
