#!/usr/bin/env bash
# Sysemble VM image build (P1-e3a) - runs as root inside Linux arm64.
#
# Invoked by engine/vm/image/build-image.sh, either inside a privileged
# debian:trixie container (macOS via Docker Desktop, Linux via docker) or
# directly on an arm64 Linux host as root (CI: sudo). It produces the frozen
# image directory of docs/plan/P1-e3-workplan.md section 2.1:
#
#   <out>/disk.img           raw ext4, 6 GiB sparse, label sysemble-engine
#   <out>/vmlinuz            guest kernel (arm64 Image)
#   <out>/initrd.img         guest initramfs
#   <out>/sysemble-vm.json   manifest (schema 1)
#
#   in-container-build.sh --out <dir> [--ref <name>] [--rootfs-dir <dir>]
#
# Why the rootfs is NOT built under --out (important on macOS):
#   build-image.sh bind-mounts <out> into the container. On Docker Desktop for
#   Mac that bind mount is APFS, which is case-insensitive by default. Debian
#   packages contain paths that differ only by case (PAM.7.gz vs pam.7.gz); a
#   symlink whose target collapses onto its own name fails with ELOOP/EEXIST.
#   P1-e2 hit this when the builder wrote a rootfs straight into a bind-mounted
#   host directory (engine/runtime/container-entry.sh). The rootfs therefore
#   stays in the container/host's own case-sensitive filesystem and only the
#   top-level artifacts (disk.img, vmlinuz, initrd.img, manifest) cross the
#   bind mount. mke2fs -d copies the tree into the ext4 image.
#
# Requires bash 3.2+ (macOS host / Linux). No bash 4-only constructs.

set -Eeuo pipefail

case "$0" in
  */*) SCRIPT_DIR=${0%/*} ;;
  *) SCRIPT_DIR=. ;;
esac
SCRIPT_DIR=$(cd "$SCRIPT_DIR" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd -P)

VERSION_FILE="$SCRIPT_DIR/version"
GUEST_DIR="$REPO_ROOT/engine/vm/guest"
MANIFEST_NAME="sysemble-vm.json"
DISK_SIZE="6G"
DISK_LABEL="sysemble-engine"
GUEST_INCLUDE="systemd-sysv,systemd,udev,kmod,initramfs-tools,linux-image-arm64,systemd-resolved,ca-certificates,mmdebstrap,debian-archive-keyring,curl,jq,rsync,procps,iproute2,netbase,util-linux,bash,coreutils,tar,gzip,zstd,e2fsprogs"
AGENT_UNIT="sysemble-vm-agent.service"

OUT=""
REF=""
ROOTFS_DIR="/build/rootfs"
VERSION=""
BUILD_START_SECONDS=$SECONDS

log() {
  printf 'vm-image: %s\n' "$*"
}


die() {
  printf 'vm-image: error: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'vm-image: error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

on_err() {
  printf 'vm-image: error: unexpected command failure (status %s) at line %s: %s\n' \
    "$1" "$2" "$3" >&2
  exit 1
}
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

usage() {
  cat <<EOF
Usage: engine/vm/image/in-container-build.sh --out <dir> [options]

Runs as root in Linux arm64 (inside the build container or on an arm64 host)
and writes the VM image plus its manifest.

Options:
  --out <dir>          output directory (default: /out; mounted at <out> on the
                       host by build-image.sh)
  --ref <name>         label recorded in the manifest (default:
                       sysemble-vm:<version>)
  --rootfs-dir <dir>   case-sensitive working directory for the mmdebstrap
                       rootfs (default: /build/rootfs). It must NOT be inside
                       --out: APFS bind mounts on macOS are case-insensitive and
                       break Debian rootfs extraction.
  -h, --help           show this help and exit 0

Environment:
  SOURCE_DATE_EPOCH    optional UTC epoch recorded as "created"

Exit codes: 0 success, 1 build failure, 2 usage error.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out)
        [ "$#" -ge 2 ] || usage_error "--out requires a value"
        OUT=$2
        shift 2
        ;;
      --ref)
        [ "$#" -ge 2 ] || usage_error "--ref requires a value"
        REF=$2
        shift 2
        ;;
      --rootfs-dir)
        [ "$#" -ge 2 ] || usage_error "--rootfs-dir requires a value"
        ROOTFS_DIR=$2
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage_error "unknown argument: $1"
        ;;
    esac
  done
}

load_version() {
  [ -f "$VERSION_FILE" ] || die "version file not found: $VERSION_FILE"
  VERSION=$(tr -d '[:space:]' <"$VERSION_FILE")
  [ -n "$VERSION" ] || die "version file is empty: $VERSION_FILE"
}

validate() {
  load_version

  [ -n "$OUT" ] || OUT=/out
  [ -n "$REF" ] || REF="sysemble-vm:$VERSION"

  case "$OUT" in
    /*) ;;
    *) usage_error "--out must be an absolute path, got '$OUT'" ;;
  esac
  case "$ROOTFS_DIR" in
    /*) ;;
    *) usage_error "--rootfs-dir must be an absolute path, got '$ROOTFS_DIR'" ;;
  esac

  OUT=$(cd "$OUT" 2>/dev/null && pwd -P) ||
    die "output directory not found: $OUT (build-image.sh creates it and bind-mounts it)"
  [ -w "$OUT" ] || die "output directory is not writable: $OUT"

  case "$ROOTFS_DIR" in
    "$OUT" | "$OUT"/*)
      usage_error "refusing --rootfs-dir '$ROOTFS_DIR': it is inside --out, which is a case-insensitive APFS bind mount on macOS; keep the rootfs in the case-sensitive filesystem"
      ;;
  esac

  [ -f "$GUEST_DIR/sysemble-vm-agent" ] ||
    die "guest agent not found: $GUEST_DIR/sysemble-vm-agent"
  [ -f "$GUEST_DIR/$AGENT_UNIT" ] ||
    die "guest unit not found: $GUEST_DIR/$AGENT_UNIT"
  [ -f "$GUEST_DIR/virtiofs.conf" ] ||
    die "modules-load drop-in not found: $GUEST_DIR/virtiofs.conf"
  [ -f "$GUEST_DIR/20-wired.network" ] ||
    die "network config not found: $GUEST_DIR/20-wired.network"

  case "$REF" in
    *[[:space:]]*) usage_error "--ref must not contain whitespace: '$REF'" ;;
    -*) usage_error "--ref must not start with '-': '$REF'" ;;
  esac
}

require_root() {
  [ "$(id -u)" -eq 0 ] ||
    die "must run as root (build-image.sh --engine native uses sudo; docker needs --privileged)"
}

require_arm64() {
  local machine=""
  machine=$(uname -m)
  case "$machine" in
    aarch64 | arm64) ;;
    *) die "the VM image is arm64-only: Virtualization.framework on Apple Silicon cannot boot another guest arch (host reports '$machine')" ;;
  esac
}

install_build_deps() {
  export DEBIAN_FRONTEND=noninteractive
  log "installing build dependencies (mmdebstrap, e2fsprogs, systemd for systemctl --root)"
  if ! apt-get update; then
    die "apt-get update failed in the build environment (network required)"
  fi
  if ! apt-get install -y --no-install-recommends \
    ca-certificates \
    coreutils \
    debian-archive-keyring \
    e2fsprogs \
    file \
    gzip \
    mmdebstrap \
    python3 \
    systemd \
    tar \
    util-linux; then
    die "apt-get install failed in the build environment (network required)"
  fi
  # Only clean the apt lists in the disposable container. A native build runs
  # this as root on the host, where deleting /var/lib/apt/lists would slow down
  # the user's next apt call. The native path already installs packages, which
  # is why the README recommends an ephemeral runner/host for it.
  if [ -f /.dockerenv ]; then
    rm -rf /var/lib/apt/lists/*
  fi
}

prepare_rootfs() {
  log "stage 1/5: mmdebstrap --variant=minbase --include=<guest list> trixie $ROOTFS_DIR"
  rm -rf "$ROOTFS_DIR" || die "cannot clear $ROOTFS_DIR"
  mkdir -p "$ROOTFS_DIR" || die "cannot create $ROOTFS_DIR"
  if ! mmdebstrap --variant=minbase --include="$GUEST_INCLUDE" trixie "$ROOTFS_DIR"; then
    die "mmdebstrap failed to build the trixie arm64 rootfs"
  fi
  [ -f "$ROOTFS_DIR/etc/os-release" ] ||
    die "mmdebstrap reported success but $ROOTFS_DIR/etc/os-release is missing"
}

copy_guest_files() {
  log "stage 2/5: installing the guest agent, unit, modules-load and network files"
  install -D -m 0755 "$GUEST_DIR/sysemble-vm-agent" \
    "$ROOTFS_DIR/usr/local/sbin/sysemble-vm-agent" ||
    die "cannot install the guest agent"
  install -D -m 0644 "$GUEST_DIR/$AGENT_UNIT" \
    "$ROOTFS_DIR/etc/systemd/system/$AGENT_UNIT" ||
    die "cannot install $AGENT_UNIT"
  install -D -m 0644 "$GUEST_DIR/virtiofs.conf" \
    "$ROOTFS_DIR/etc/modules-load.d/virtiofs.conf" ||
    die "cannot install the virtiofs modules-load drop-in"
  install -D -m 0644 "$GUEST_DIR/20-wired.network" \
    "$ROOTFS_DIR/etc/systemd/network/20-wired.network" ||
    die "cannot install 20-wired.network"
}

configure_guest() {
  log "stage 3/5: enabling units and configuring DNS/hostname"
  if ! systemctl --root="$ROOTFS_DIR" enable \
    "$AGENT_UNIT" systemd-networkd.service systemd-resolved.service; then
    die "systemctl --root could not enable the guest units"
  fi
  # Optional but very useful when debugging boot from the virtio console: a
  # login prompt on hvc0. It does not affect the job protocol.
  systemctl --root="$ROOTFS_DIR" enable serial-getty@hvc0.service ||
    die "systemctl --root could not enable serial-getty@hvc0.service"

  # systemd-resolved owns DNS at boot; DHCP from systemd-networkd feeds it.
  # Keep a copy of whatever mmdebstrap left behind and point resolv.conf at the
  # resolved stub. FallbackDNS covers a DHCP server that hands out no DNS.
  local resolv="$ROOTFS_DIR/etc/resolv.conf"
  if [ -f "$resolv" ] && [ ! -L "$resolv" ]; then
    cp -a "$resolv" "$ROOTFS_DIR/etc/resolv.conf.sysemble-backup" ||
      die "cannot back up the rootfs resolv.conf"
  fi
  rm -f "$resolv" || die "cannot replace $resolv"
  ln -s ../run/systemd/resolve/stub-resolv.conf "$resolv" ||
    die "cannot symlink $resolv to the resolved stub"
  mkdir -p "$ROOTFS_DIR/etc/systemd/resolved.conf.d" ||
    die "cannot create resolved.conf.d"
  cat >"$ROOTFS_DIR/etc/systemd/resolved.conf.d/10-sysemble-fallback.conf" <<'EOF'
# Sysemble engine VM: DHCP DNS first, public resolver as fallback.
[Resolve]
FallbackDNS=1.1.1.1
EOF

  printf 'sysemble-vm\n' >"$ROOTFS_DIR/etc/hostname" ||
    die "cannot write /etc/hostname"

  # A pre-set machine-id keeps systemd-firstboot from asking questions on the
  # serial console during first boot.
  if [ ! -s "$ROOTFS_DIR/etc/machine-id" ]; then
    od -An -N16 -tx1 /dev/urandom | tr -d ' \n' >"$ROOTFS_DIR/etc/machine-id" ||
      die "cannot create /etc/machine-id"
  fi
}

build_disk() {
  log "stage 4/5: creating sparse $DISK_SIZE ext4 $OUT/disk.img (label $DISK_LABEL)"
  rm -f "$OUT/disk.img" || die "cannot remove the previous $OUT/disk.img"
  truncate -s "$DISK_SIZE" "$OUT/disk.img" || die "cannot create $OUT/disk.img"
  if ! mke2fs -t ext4 -F -L "$DISK_LABEL" -d "$ROOTFS_DIR" "$OUT/disk.img"; then
    die "mke2fs could not populate $OUT/disk.img from $ROOTFS_DIR"
  fi
}

disk_cat() {
  debugfs -R "cat $1" "$OUT/disk.img" 2>/dev/null
}

disk_stat() {
  debugfs -R "stat $1" "$OUT/disk.img" 2>/dev/null
}

# Read the image back through ext4 so the manifest describes a disk that really
# contains the guest files (mmdebstrap/systemctl errors are caught here).
verify_disk() {
  local value=""

  # /etc/os-release is a symlink on Debian; debugfs cat does not follow it, so
  # read the regular /etc/debian_version instead.
  value=$(disk_cat /etc/debian_version) || true
  case "$value" in
    13*) log "diskcheck: OK /etc/debian_version is Debian trixie ($value)" ;;
    *) die "diskcheck failed: /etc/debian_version does not look like Debian trixie" ;;
  esac

  value=$(disk_cat /usr/local/sbin/sysemble-vm-agent) || true
  case "$value" in
    *"sysemble-vm-agent:"*) log "diskcheck: OK /usr/local/sbin/sysemble-vm-agent" ;;
    *) die "diskcheck failed: the guest agent is missing from $OUT/disk.img" ;;
  esac

  value=$(disk_stat "/etc/systemd/system/multi-user.target.wants/$AGENT_UNIT") || true
  case "$value" in
    *"$AGENT_UNIT"*) log "diskcheck: OK $AGENT_UNIT is enabled" ;;
    *) die "diskcheck failed: $AGENT_UNIT is not enabled in $OUT/disk.img" ;;
  esac

  value=$(disk_cat /etc/systemd/network/20-wired.network) || true
  case "$value" in
    *"DHCP=yes"*) log "diskcheck: OK /etc/systemd/network/20-wired.network" ;;
    *) die "diskcheck failed: 20-wired.network is missing from $OUT/disk.img" ;;
  esac

  value=$(disk_cat /etc/modules-load.d/virtiofs.conf) || true
  case "$value" in
    *"virtiofs"*) log "diskcheck: OK /etc/modules-load.d/virtiofs.conf" ;;
    *) die "diskcheck failed: virtiofs.conf is missing from $OUT/disk.img" ;;
  esac

  value=$(disk_stat /etc/resolv.conf) || true
  case "$value" in
    *"stub-resolv.conf"*) log "diskcheck: OK /etc/resolv.conf points at the resolved stub" ;;
    *) die "diskcheck failed: /etc/resolv.conf is not the resolved stub symlink" ;;
  esac
}

export_kernel() {
  local kernel_path=""
  local initrd_path=""
  local release=""
  local kernel_type=""
  local initrd_type=""
  local initrd_size=""

  log "stage 5/5: exporting the guest kernel and initramfs"
  if ! kernel_path=$(ls -1 "$ROOTFS_DIR"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -n 1); then
    kernel_path=""
  fi
  [ -n "$kernel_path" ] ||
    die "no /boot/vmlinuz-* in the rootfs: linux-image-arm64 is missing or the kernel postinst failed"

  release=${kernel_path##*/vmlinuz-}
  [ -n "$release" ] || die "cannot derive the kernel release from '$kernel_path'"
  initrd_path="$ROOTFS_DIR/boot/initrd.img-$release"

  if [ ! -f "$initrd_path" ]; then
    log "initramfs for $release is missing; running update-initramfs in the rootfs"
    chroot "$ROOTFS_DIR" update-initramfs -c -k "$release" ||
      die "update-initramfs failed and no initramfs exists for $release"
  fi
  [ -f "$initrd_path" ] || die "no initramfs found for kernel $release"

  cp -f "$kernel_path" "$OUT/vmlinuz" || die "cannot copy $kernel_path"
  cp -f "$initrd_path" "$OUT/initrd.img" || die "cannot copy $initrd_path"

  kernel_type=$(file -b "$OUT/vmlinuz" || true)
  case "$kernel_type" in
    *ARM64* | *aarch64*) log "kernel: $release ($kernel_type)" ;;
    *) die "the guest kernel is not an arm64 Image (file: $kernel_type)" ;;
  esac

  initrd_type=$(file -b "$OUT/initrd.img" || true)
  initrd_size=$(stat -c %s "$OUT/initrd.img" || true)
  [ -n "$initrd_size" ] && [ "$initrd_size" -gt 1048576 ] ||
    die "initrd.img is suspiciously small (${initrd_size:-0} bytes)"
  case "$initrd_type" in
    *gzip* | *Zstandard* | *XZ* | *LZ4*)
      log "initrd: $initrd_type, $initrd_size bytes"
      ;;
    *cpio*)
      # Debian initramfs-tools concatenates an uncompressed newc cpio (for
      # already-compressed *.zst/*.xz members) with the compressed main cpio;
      # file(1) only describes the first member. The cpio trailer proves the
      # first member is complete and the kernel's initramfs unpacker handles
      # the concatenation.
      if grep -aq 'TRAILER!!!' "$OUT/initrd.img"; then
        log "initrd: concatenated cpio image ($initrd_type, $initrd_size bytes)"
      else
        die "the guest initramfs has no cpio trailer (file: $initrd_type)"
      fi
      ;;
    *)
      die "the guest initramfs is not a recognised cpio image (file: $initrd_type)"
      ;;
  esac

  KERNEL_RELEASE=$release
}

write_manifest() {
  local kernel_sha=""
  local initrd_sha=""
  local disk_sha=""
  local packages=""
  local mmdebstrap_line=""
  local mmdebstrap_version=""
  local epoch=""

  log "collecting manifest evidence"
  kernel_sha=$(sha256sum "$OUT/vmlinuz" | cut -d ' ' -f 1) || die "sha256sum vmlinuz failed"
  initrd_sha=$(sha256sum "$OUT/initrd.img" | cut -d ' ' -f 1) || die "sha256sum initrd.img failed"
  disk_sha=$(sha256sum "$OUT/disk.img" | cut -d ' ' -f 1) || die "sha256sum disk.img failed"

  packages=$(chroot "$ROOTFS_DIR" dpkg-query -W | wc -l | tr -d '[:space:]') ||
    die "cannot count the guest dpkg packages"
  case "$packages" in
    '' | *[!0-9]*) die "unexpected guest package count '$packages'" ;;
  esac
  [ "$packages" -gt 0 ] || die "the guest dpkg database is empty"

  mmdebstrap_line=$(mmdebstrap --version 2>&1) || mmdebstrap_line=""
  mmdebstrap_line=${mmdebstrap_line%%$'\n'*}
  mmdebstrap_version=${mmdebstrap_line##* }
  [ -n "$mmdebstrap_version" ] || die "cannot read the mmdebstrap version"

  if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    epoch=$SOURCE_DATE_EPOCH
  else
    epoch=$(date -u +%s) || die "cannot read the current UTC time"
  fi
  case "$epoch" in
    '' | *[!0-9]*) die "SOURCE_DATE_EPOCH must be a positive integer, got '$epoch'" ;;
  esac

  python3 - "$OUT" "$MANIFEST_NAME" "$VERSION" "$REF" "$KERNEL_RELEASE" \
    "$kernel_sha" "$initrd_sha" "$disk_sha" "$packages" "$mmdebstrap_version" \
    "$epoch" <<'PY'
import datetime
import json
import os
import sys
import tempfile

(out, manifest_name, version, ref, kernel_release, kernel_sha, initrd_sha,
 disk_sha, packages, mmdebstrap_version, epoch) = sys.argv[1:12]

manifest_path = os.path.join(out, manifest_name)
disk_size = os.path.getsize(os.path.join(out, "disk.img"))
if disk_size <= 0:
    raise SystemExit("disk.img is empty")
if not kernel_release.strip():
    raise SystemExit("kernel release is empty")
if len(kernel_sha) != 64 or len(initrd_sha) != 64 or len(disk_sha) != 64:
    raise SystemExit("sha256 digests are not 64 characters")

created = datetime.datetime.fromtimestamp(
    int(epoch), datetime.timezone.utc
).strftime("%Y-%m-%dT%H:%M:%SZ")

manifest = {
    "schema": 1,
    "name": "sysemble-vm",
    "version": version,
    "ref": ref,
    "arch": "arm64",
    "kernel": {
        "path": "vmlinuz",
        "release": kernel_release,
        "sha256": kernel_sha,
    },
    "initrd": {
        "path": "initrd.img",
        "sha256": initrd_sha,
    },
    "disk": {
        "path": "disk.img",
        "sha256": disk_sha,
        "size_bytes": disk_size,
    },
    "guest": {
        "agent_unit": "sysemble-vm-agent.service",
        "minimal_build": "engine/vm/guest/minimal-build.sh",
    },
    "packages": int(packages),
    "mmdebstrap": mmdebstrap_version,
    "created": created,
}

fd, tmp_path = tempfile.mkstemp(
    prefix=".sysemble-vm.", suffix=".json", dir=out
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    # mkstemp creates 0600. A native build runs under sudo, so the host-side
    # verification (and the CI artifact upload) runs as another user: the
    # manifest must be world-readable like the kernel/initrd/disk artifacts.
    os.chmod(tmp_path, 0o644)
    os.replace(tmp_path, manifest_path)
finally:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)

print("vm-image: manifest %s" % manifest_path)
print("vm-image:   version=%s arch=arm64" % version)
print("vm-image:   kernel=%s (%s)" % (kernel_release, kernel_sha[:12]))
print("vm-image:   initrd=%s" % initrd_sha[:12])
print("vm-image:   disk=%s bytes, sha256=%s" % (disk_size, disk_sha[:12]))
print("vm-image:   packages=%s mmdebstrap=%s" % (packages, mmdebstrap_version))
PY
  log "manifest written: $OUT/$MANIFEST_NAME"
}

summary() {
  local elapsed=$((SECONDS - BUILD_START_SECONDS))
  local disk_allocated=""

  disk_allocated=$(du -k "$OUT/disk.img" | cut -f 1) || disk_allocated=""
  log "artifacts in $OUT:"
  ls -lh "$OUT/disk.img" "$OUT/vmlinuz" "$OUT/initrd.img" "$OUT/$MANIFEST_NAME" || true
  log "disk.img logical=$(stat -c %s "$OUT/disk.img") bytes allocated=$(( ${disk_allocated:-0} * 1024 )) bytes (sparse)"
  log "elapsed ${elapsed}s"
  printf 'VM-IMAGE: complete\n'
}

main() {
  parse_args "$@"
  validate
  require_root
  require_arm64
  install_build_deps
  prepare_rootfs
  copy_guest_files
  configure_guest
  build_disk
  verify_disk
  export_kernel
  write_manifest
  summary
  exit 0
}

main "$@"
