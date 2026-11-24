# Sysemble VM guest files (P1-e3a)

These files are baked into the arm64 Debian trixie guest rootfs by
[`engine/vm/image/in-container-build.sh`](../image/in-container-build.sh). The
macOS host only interacts through two virtiofs shares and four files in the
output directory; there is no SSH, no vsock, and no guest network service.

Contract: [`docs/plan/P1-e3-workplan.md`](../../../docs/plan/P1-e3-workplan.md)
sections 1, 2.2, and 2.4.

## Install locations

| Source file | Guest path | Mode |
|---|---|---|
| `sysemble-vm-agent` | `/usr/local/sbin/sysemble-vm-agent` | 0755 |
| `sysemble-vm-agent.service` | `/etc/systemd/system/sysemble-vm-agent.service` | 0644 |
| `virtiofs.conf` | `/etc/modules-load.d/virtiofs.conf` | 0644 |
| `20-wired.network` | `/etc/systemd/network/20-wired.network` | 0644 |

The image build also runs `systemctl --root` to enable
`sysemble-vm-agent.service`, `systemd-networkd.service`,
`systemd-resolved.service`, and (for serial debugging)
`serial-getty@hvc0.service`.

## File job protocol

```
macOS host                                    guest (systemd, root)
──────────                                    ─────────────────────
<out>/.sysemble-vm/          ──virtiofs──▶    /export/.sysemble-vm/
<out>/plan.json              ──virtiofs──▶    /export/plan.json
<repo>                       ──virtiofs──▶    /work (ro)
                                              agent: modprobe virtiofs
                                              agent: mount sysemble-repo -> /work (ro)
                                              agent: mount sysemble-out  -> /export (rw)
                                              agent: write ready (atomic rename)
<out>/.sysemble-vm/job.sh    ─────────────▶   agent: poll, then bash job.sh
                                              agent: job output -> log
                                              agent: exit code -> done (atomic rename)
<out>/.sysemble-vm/done      ◀─────────────   agent: sync, exit 0 (no poweroff)
host reads log + done, then stops the VM
```

Details that the host may rely on:

- `ready` is one line, `<UTC timestamp> ready` (ISO 8601, e.g.
  `2026-11-24T18:00:00Z ready`). It is written to a temporary file and renamed,
  so a partially written marker is never observable.
- `job.sh` is discovered by polling every second. The host must create it with
  a rename (`job.sh.tmp` → `job.sh`), as frozen in the workplan.
- The job runs as `bash /export/.sysemble-vm/job.sh` with stdout and stderr
  redirected to `/export/.sysemble-vm/log`; the guest build log is therefore
  the whole job output, uncompressed and unmodified.
- `done` contains one decimal exit status (0 on success) and is written through
  a temporary file + rename, then `sync`ed.
- The protocol is **single-shot**: the agent exits after one job. Each host run
  uses a freshly cloned disk image, so there is no second job.
- The agent never calls `poweroff`/`reboot`. The macOS host stops the VM after
  reading `done`; the host's own timeout is the only deadline (180 s for
  `ready`, 1800 s for the job by default).
- Every agent log line starts with `sysemble-vm-agent:`. Job output is not
  prefixed: it belongs to the builder/mmdebstrap.

## Minimal build (`minimal-build.sh`)

Called by the host-written `job.sh`:

```
bash /work/engine/vm/guest/minimal-build.sh \
  --plan /export/plan.json --out /out --export /export
```

Stages:

1. `bash /work/builders/debian/build.sh --plan <plan> --out /out/dry --dry-run`
   — proves the frozen P0/P1 builder runs inside the guest against the read-only
   repository. A non-zero status aborts the job. `builder_dry_run=pass` is
   recorded on success.
2. `mmdebstrap --variant=minbase --include="<guest list>" trixie /out/rootfs`
   — native arm64 rootfs (no emulation).
3. `tar -C /out/rootfs -czf /export/rootfs.tar.gz .` plus
   `sha256sum` → `/export/rootfs.tar.gz.sha256` (relative name inside the file).
4. `/export/artifact-vm.json`:

```json
{
  "schema": 1,
  "name": "sysemble-vm-build",
  "arch": "arm64",
  "kernel_release": "6.12.x-arm64",
  "rootfs_files": 12345,
  "tar_path": "rootfs.tar.gz",
  "tar_size_bytes": 123456789,
  "tar_sha256": "…64 hex…",
  "mmdebstrap": "1.5.7",
  "builder_dry_run": "pass",
  "created": "2026-11-24T00:00:00Z",
  "plan": "/export/plan.json",
  "out": "/out"
}
```

`rootfs_files` is the number of entries in the exported tar (files, directories,
and symlinks). Success prints the final line `VM-BUILD: complete`; every failure
prints `VM-BUILD: failed: <reason>` and exits non-zero (2 for usage errors).

`--out` must be guest-local. It is rejected for `/work`, `/export`, and their
subtrees: both shares live on APFS, which is case-insensitive, and unpacking a
Debian rootfs there fails with ELOOP/EEXIST on paths that differ only by case
(`PAM.7.gz` vs `pam.7.gz`; see the P1-e2 evidence in
[`engine/runtime/container-entry.sh`](../../runtime/container-entry.sh)). Only
top-level artifacts are written to `/export`.

## Guest package list

Frozen in `minimal-build.sh` and in the image build:

```
systemd-sysv systemd udev kmod initramfs-tools linux-image-arm64 systemd-resolved
ca-certificates mmdebstrap debian-archive-keyring curl jq rsync procps iproute2
netbase util-linux bash coreutils tar gzip zstd e2fsprogs
```

Debian trixie merged the former `systemd-networkd` binary package into
`systemd`: `systemd-networkd.service` ships in `systemd`, so the list includes
`systemd` explicitly (it is also a dependency of `systemd-sysv`).

`jq` is what the frozen builder uses for JSON parsing in the guest (there is no
python3 in the guest package list); `mmdebstrap` + `debian-archive-keyring` are
what the guest itself uses to build the artifact rootfs.

## Limitations

- **arm64 only.** These files target the Debian arm64 guest used by
  Virtualization.framework on Apple Silicon. The frozen builder's x86_64
  GPT/GRUB/OVMF pipeline is not exercised here.
- **No sshd, no vsock, no guest agent RPC.** The only control channel is the
  four files above; anything else needs a new frozen protocol.
- **Network is required** for both mmdebstrap stages. NAT + DHCP + resolved must
  work (see `20-wired.network`); a DNS failure fails the job, not the VM.
- **The serial console** shows agent and systemd boot lines
  (`console=hvc0`), and `serial-getty@hvc0.service` provides a getty for
  watching boot messages. The prototype has no root password (the root account
  is locked), so the getty is a diagnostic view, not a login path.
- **No cleanup between jobs.** The guest's `/out` is on the ephemeral VM disk;
  the host clones `disk.img` per run and discards it.
