# Debian builder (P0-a)

`build.sh` reads the `plan.json` produced by `sysemble plan --json` and
bootstraps a Debian rootfs with [mmdebstrap](https://mmdebstrap.de/), either on
a Linux host or inside a disposable `debian:trixie` container.

This is the **P0-a** slice: the plan validation and dry-run path are the
acceptance target; the real build path bootstraps a rootfs only. Partitioning,
bootloaders, qcow2/ISO assembly, and system configuration are P0-b work.

## Interface

```
builders/debian/build.sh --plan <plan.json> --out <dir> [--dry-run] [--engine docker|native]
```

| Option | Meaning |
|---|---|
| `--plan <path>` | Required. `plan.json` from `sysemble plan --json`. |
| `--out <dir>` | Required. Output directory; created if missing. Must not be `/` or an existing file. |
| `--dry-run` | Validate the plan, print the stages/packages/estimates, write only `<out>/plan.copy.json`, exit 0. |
| `--engine native` | Default. Build on this Linux host (`uname -s` = Linux, euid 0, `mmdebstrap` in `PATH`). |
| `--engine docker` | Build inside `debian:trixie`; needs `docker` CLI and a reachable daemon. |
| `-h`, `--help` | Print usage and exit 0. |

`--opt value` and `--opt=value` are both accepted. Missing or unknown
arguments print usage and exit 2.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Dry run succeeded, or the rootfs bootstrap completed. |
| 1 | Invalid plan: malformed JSON or failed plan validation. |
| 2 | Usage or I/O error, including an unsafe `--out`. |
| 3 | Native engine unavailable: not Linux, not root, or no `mmdebstrap`. |
| 4 | Docker engine unavailable: no `docker` CLI, or `docker info` failed/timed out. |
| 5 | No JSON parser: neither `jq` nor `python3` is available. |
| 6 | A build step failed (mmdebstrap / docker run), or `<out>/rootfs` already exists. |

Exit codes 2, 3, 4, and 5 follow the builder contract; 1 and 6 fill gaps the
contract does not specify, and are listed here so callers can rely on them.

### Dry run

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

Optional fields are used for display only:

| Field | Use |
|---|---|
| `spec` | Spec name shown in the dry-run header. |
| `base.pin` | Snapshot date/digest shown as `pin:`; **not applied** in P0-a. |
| `modules` | Displayed as `id@version`; no module hooks run. |
| `estimates.image_mb`, `estimates.build_minutes`, `estimates.disk_mb` | Printed in the estimates block; absent values print `(not provided)`. |
| `warnings` | Displayed as `code: message`; the builder does not fail on warnings. |

`builders/debian/testdata/plan.example.json` is a self-contained fixture (43
packages, 9 modules, no warnings) regenerated from `sysemble plan` on the
Debian example. Its `linux-image-amd64` package and `x86_64` architecture make
it an x86_64 plan.
Note that the **plan** field is `target.outputs` (plural), while the
**buildspec** schema uses `target.output` (singular); the builder follows the
plan contract.

JSON is read with `jq` when available, otherwise with `python3 -c`. Both
backends emit the same validated record stream; the dry-run output is identical
for the same plan. If neither tool exists, the script exits 5 before creating
`<out>`.

## Native engine

Preflight requires all three:

1. `uname -s` is `Linux`;
2. effective uid is 0;
3. `mmdebstrap` is in `PATH`.

Every unmet requirement is reported, then the script exits 3. It never calls
`sudo`.

The build runs, under `<out>` only:

```
mmdebstrap --variant=minbase --include=<comma-separated packages> \
  <base.release> <out>/rootfs
```

The plan's `packages` list is expected to already include base, desktop, and
dev packages (the resolver's job). The builder does not split layers or run
module hooks. If `<out>/rootfs` already exists, the build refuses to overwrite
it and exits 6; a failed mmdebstrap run may leave a partial rootfs behind, which
must be removed manually before retrying.

The builder's only persistent output is under `<out>`; mmdebstrap itself may
use transient temporary directories (for example under `/tmp`) while it works.

`target.arch` is validated but not passed to mmdebstrap. P0-a builds the host
architecture only; cross-architecture builds (qemu/binfmt) are out of scope.

## Docker engine

Preflight requires the `docker` CLI and a successful `docker info`. The daemon
check is wrapped in a 20-second watchdog so a wedged daemon cannot hang the
script. A missing CLI or unreachable daemon prints a diagnostic and exits 4.

The build runs:

```
docker run --rm --privileged -v <out>:/out debian:trixie \
  bash -c '<apt-get update && apt-get install mmdebstrap; mmdebstrap ...>'
```

- The container installs `mmdebstrap`, `ca-certificates`, and the Debian archive
  keyring with apt, then runs
  `mmdebstrap --variant=minbase --include=<packages> <release> /out/rootfs`.
- `--privileged` is required because mmdebstrap needs mount/chroot inside the
  container. Only `<out>` is bind-mounted and the container is removed with
  `--rm`; the host filesystem is not exposed. Treat docker mode as suitable for
  trusted plans: a privileged container is still a privileged container.
- `--out` must not contain `:` (Docker bind-mount syntax); the script rejects
  such a path with exit 6.
- The container runs on the host architecture; `target.arch` is not applied.
- `debian:trixie` is a moving tag in P0-a; digest pinning is future work.
- Docker mode needs outbound network for apt and the Debian mirror. The script
  never changes the host's network configuration.

## Safety properties

- `set -euo pipefail`; no `eval`, no `sudo`, no host package installation.
- `--out` is rejected if it is empty, `/`/`//`/`///`, an existing non-directory,
  or a symlink resolving to `/`. The canonical path is checked again after
  `mkdir -p`, before any write.
- Dry run writes only `<out>/plan.copy.json`; real builds additionally write
  `<out>/rootfs`. The builder's only persistent writes are under `<out>`;
  transient record/diagnostic files live under `$TMPDIR` and are removed on
  exit.
- `plan.copy.json` is written with a temporary file plus rename, so a
  pre-existing symlink/hardlink cannot redirect the write outside `<out>`.
- The rootfs target is never deleted or overwritten.
- Temporary files live in `$TMPDIR` (or `/tmp`) under `sysemble-build.*` and are
  removed by an EXIT trap. The trap only deletes paths matching that prefix.
- Docker mode bind-mounts only `<out>`; no Docker socket or host directories.

## Not implemented in P0-a

- Partition tables, filesystems, bootloaders, UKI, qcow2/ISO/PXE assembly.
- System configuration: hostname, locale, timezone, keyboard, users, services,
  kernel cmdline, desktop theme. The P0 plan has no fields for these.
- Module hooks and per-module package layering (modules are display-only).
- Snapshot pinning (`base.pin` is displayed but mmdebstrap uses the live
  mirror), reproducible timestamps (`SOURCE_DATE_EPOCH`), SBOM, evidence,
  signatures.
- Cross-architecture builds; native architecture only.
- Build cache, retries, resume, and cleanup of a partial `rootfs` after failure.
- Build locking: do not run two builds against the same `<out>` concurrently.
- Real native build verification: the development host is macOS; the native
  command path was exercised with stubs.
- Real build verification on Docker: the daemon was unavailable in the
  development environment; the docker command path was exercised with a stub.

## Local checks

```bash
bash -n builders/debian/build.sh
bash -n builders/debian/lib.sh
bash builders/debian/build.sh --help
bash builders/debian/build.sh \
  --plan builders/debian/testdata/plan.example.json \
  --out /tmp/sysemble-dry --dry-run
bash builders/debian/build.sh \
  --plan builders/debian/testdata/plan.example.json \
  --out /tmp/sysemble-native          # on macOS: exit 3
bash builders/debian/build.sh \
  --plan builders/debian/testdata/plan.example.json \
  --out /tmp/sysemble-docker --engine docker   # no daemon: exit 4
```

To force the `python3` JSON backend on a machine that has `jq`, run the script
with a `PATH` that contains `python3` but not `jq`; the dry-run output must be
byte-identical.

## Files

| File | Role |
|---|---|
| `build.sh` | CLI, output directory handling, dry run, native/docker builds. |
| `lib.sh` | JSON backends, record parsing, plan validation, preflight checks, usage text. |
| `testdata/plan.example.json` | Contract-shaped fixture used by the checks above. |
