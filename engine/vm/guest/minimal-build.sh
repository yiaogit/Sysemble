#!/usr/bin/env bash
# Sysemble VM guest minimal build (P1-e3a).
#
# Contract (frozen): docs/plan/P1-e3-workplan.md sections 2.2 and 2.4.
#
#   minimal-build.sh --plan <plan.json> --out <guest-local dir> --export <dir>
#
# Executed inside the Debian trixie arm64 guest by the job the host writes to
# /export/.sysemble-vm/job.sh:
#
#   stage 1  bash /work/builders/debian/build.sh --plan <plan> --out <out>/dry
#            --dry-run  -> proves the frozen builder runs against the read-only
#            repository share (guest has jq; python3 is not installed)
#   stage 2  mmdebstrap --variant=minbase --include=<guest package list> \
#            trixie <out>/rootfs  (arm64 native)
#   stage 3  tar -C <out>/rootfs -czf <export>/rootfs.tar.gz .  + sha256sum
#   stage 4  write <export>/artifact-vm.json with arch/kernel/rootfs/tar/
#            mmdebstrap/builder evidence
#
# --out MUST be guest-local (the ext4 root disk): the two virtiofs shares are
# APFS directories on the host and APFS is case-insensitive by default. Debian
# packages contain paths that differ only by case (PAM.7.gz vs pam.7.gz), so a
# rootfs built directly on /export fails with ELOOP/EEXIST (P1-e2 evidence; see
# engine/runtime/container-entry.sh). Only top-level artifacts are exported.
#
# Success ends with the single line "VM-BUILD: complete"; every failure prints
# "VM-BUILD: failed: <reason>" and exits non-zero. The agent captures all of
# this in /export/.sysemble-vm/log.
#
# Requires bash 3.2+ (guest trixie ships bash 5; no bash 4-only constructs).

set -Eeuo pipefail

BUILDER="/work/builders/debian/build.sh"

# Frozen guest package list: systemd guest, virtio/ext4 boot, virtiofs, DHCP,
# DNS, and the tools the stages below need (mmdebstrap + keyring for stage 2,
# jq for stage 4, e2fsprogs/zstd for the builder).
GUEST_INCLUDE="systemd-sysv,systemd,udev,kmod,initramfs-tools,linux-image-arm64,systemd-resolved,ca-certificates,mmdebstrap,debian-archive-keyring,curl,jq,rsync,procps,iproute2,netbase,util-linux,bash,coreutils,tar,gzip,zstd,e2fsprogs"

PLAN=""
OUT=""
EXPORT=""
BUILDER_DRY_RUN="pending"

usage() {
  cat <<EOF
Usage: engine/vm/guest/minimal-build.sh --plan <plan.json> --out <dir> --export <dir>

Runs the minimal guest build from docs/plan/P1-e3-workplan.md section 2.4:
a builder --dry-run from the read-only /work share, a mmdebstrap trixie arm64
rootfs in the guest-local --out directory, rootfs.tar.gz + sha256 in --export,
and artifact-vm.json.

Options:
  --plan <file>    plan.json written by the host (usually /export/plan.json)
  --out <dir>      guest-local build directory (must not be under /export or
                   /work; the host shares are case-insensitive APFS)
  --export <dir>   writable virtiofs output directory (usually /export)
  -h, --help       show this help and exit 0

Exit codes: 0 success (prints "VM-BUILD: complete"), 1 build failure,
2 usage error. Failures print "VM-BUILD: failed: <reason>".
EOF
}

log() {
  printf 'minimal-build: %s\n' "$*"
}

fail() {
  printf 'VM-BUILD: failed: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'VM-BUILD: failed: %s\n' "$*" >&2
  usage >&2
  exit 2
}

# set -e would otherwise exit without a VM-BUILD line on an unexpected failure.
on_err() {
  printf 'VM-BUILD: failed: unexpected command failure (status %s) at line %s: %s\n' \
    "$1" "$2" "$3" >&2
  exit 1
}
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plan)
        [ "$#" -ge 2 ] || usage_error "--plan requires a value"
        PLAN=$2
        shift 2
        ;;
      --out)
        [ "$#" -ge 2 ] || usage_error "--out requires a directory"
        OUT=$2
        shift 2
        ;;
      --export)
        [ "$#" -ge 2 ] || usage_error "--export requires a directory"
        EXPORT=$2
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

# realpath -m is GNU coreutils (present in trixie); the fallback keeps the
# literal path when it is missing.
normalize_path() {
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$1"
  else
    printf '%s\n' "$1"
  fi
}

validate() {
  [ -n "$PLAN" ] || usage_error "--plan is required"
  [ -n "$OUT" ] || usage_error "--out is required"
  [ -n "$EXPORT" ] || usage_error "--export is required"

  [ -f "$PLAN" ] || fail "plan file not found: $PLAN (the macOS host writes plan.json before it starts the VM)"
  case "$PLAN" in
    /*) ;;
    *) usage_error "--plan must be an absolute path, got '$PLAN'" ;;
  esac

  case "$EXPORT" in
    /*) ;;
    *) usage_error "--export must be an absolute path, got '$EXPORT'" ;;
  esac
  [ -d "$EXPORT" ] || fail "export directory not found: $EXPORT (is the sysemble-out virtiofs share mounted on /export?)"
  [ -w "$EXPORT" ] || fail "export directory is not writable: $EXPORT"

  case "$OUT" in
    /*) ;;
    *) usage_error "--out must be an absolute guest-local path, got '$OUT'" ;;
  esac
  OUT=$(normalize_path "$OUT") || fail "cannot normalize --out '$OUT'"
  case "$OUT" in
    / | /work | /work/* | /export | /export/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/*)
      usage_error "refusing --out '$OUT': the build must run on the guest-local ext4 disk (the /work and /export virtiofs shares are case-insensitive APFS; a Debian rootfs there fails with ELOOP)"
      ;;
  esac

  [ -d "$OUT" ] || mkdir -p "$OUT" || fail "cannot create --out directory $OUT"
  [ -w "$OUT" ] || fail "--out directory is not writable: $OUT"

  [ -f "$BUILDER" ] || fail "$BUILDER not found (is the read-only sysemble-repo share mounted on /work?)"
}

stage_builder_dry_run() {
  local dry_out="$OUT/dry"

  log "stage 1/4: builder dry-run ($BUILDER --dry-run)"
  rm -rf "$dry_out" || fail "cannot clear $dry_out"
  if ! bash "$BUILDER" --plan "$PLAN" --out "$dry_out" --dry-run; then
    fail "builders/debian/build.sh --dry-run failed (the frozen builder did not accept the plan)"
  fi
  BUILDER_DRY_RUN="pass"
  log "builder dry-run: pass"
}

stage_rootfs() {
  local rootfs="$OUT/rootfs"

  log "stage 2/4: mmdebstrap --variant=minbase trixie rootfs (arm64 native)"
  rm -rf "$rootfs" || fail "cannot clear $rootfs"
  mkdir -p "$rootfs" || fail "cannot create $rootfs"
  if ! mmdebstrap --variant=minbase --include="$GUEST_INCLUDE" trixie "$rootfs"; then
    fail "mmdebstrap could not build the trixie arm64 rootfs (network/DNS or apt mirror failure; see the log above)"
  fi
  [ -f "$rootfs/etc/os-release" ] ||
    fail "mmdebstrap reported success but $rootfs/etc/os-release is missing"
  log "rootfs: $rootfs"
}

stage_export_tar() {
  local tar_path="$EXPORT/rootfs.tar.gz"

  log "stage 3/4: export rootfs.tar.gz + sha256"
  rm -f "$tar_path" "$tar_path.sha256" || fail "cannot remove stale $tar_path"
  if ! tar -C "$OUT/rootfs" -czf "$tar_path" .; then
    fail "tar failed while writing $tar_path"
  fi
  if ! (cd "$EXPORT" && sha256sum rootfs.tar.gz >rootfs.tar.gz.sha256); then
    fail "sha256sum failed for $tar_path"
  fi
  log "exported $tar_path ($(stat -c %s "$tar_path") bytes)"
}

stage_artifact() {
  local created=""
  local kernel_release=""
  local mmdebstrap_line=""
  local mmdebstrap_version=""
  local rootfs_files=""
  local tar_size=""
  local tar_sha=""
  local tmp="$EXPORT/.artifact-vm.json.tmp"

  log "stage 4/4: write artifact-vm.json"
  command -v jq >/dev/null 2>&1 ||
    fail "jq is required to write artifact-vm.json (guest package list regression)"

  kernel_release=$(uname -r) || fail "uname -r failed; cannot record the kernel release"
  [ -n "$kernel_release" ] || fail "uname -r returned an empty kernel release"

  created=$(date -u +%Y-%m-%dT%H:%M:%SZ) || fail "cannot format the UTC timestamp"

  if mmdebstrap_line=$(mmdebstrap --version 2>&1); then
    mmdebstrap_version=${mmdebstrap_line%%$'\n'*}
    mmdebstrap_version=${mmdebstrap_version##* }
  else
    mmdebstrap_version="unknown"
  fi
  [ -n "$mmdebstrap_version" ] || mmdebstrap_version="unknown"

  # Entry count of the exported archive (files + directories + symlinks). The
  # guest package list has no findutils, but tar and wc are both guaranteed.
  rootfs_files=$(tar -tzf "$EXPORT/rootfs.tar.gz" | wc -l | tr -d '[:space:]')
  case "$rootfs_files" in
    '' | *[!0-9]*) fail "cannot count the rootfs entries ('$rootfs_files')" ;;
  esac
  [ "$rootfs_files" -gt 0 ] || fail "the exported rootfs archive is empty"

  tar_size=$(stat -c %s "$EXPORT/rootfs.tar.gz") || fail "cannot stat rootfs.tar.gz"
  case "$tar_size" in
    '' | *[!0-9]*) fail "unexpected rootfs.tar.gz size ('$tar_size')" ;;
  esac
  [ "$tar_size" -gt 0 ] || fail "rootfs.tar.gz is empty"

  tar_sha=$(cut -d ' ' -f 1 "$EXPORT/rootfs.tar.gz.sha256") || fail "cannot read rootfs.tar.gz.sha256"
  [ "${#tar_sha}" -eq 64 ] ||
    fail "rootfs.tar.gz.sha256 does not contain a 64-character digest ('$tar_sha')"
  case "$tar_sha" in
    *[!0-9a-f]*) fail "rootfs.tar.gz.sha256 is not lowercase hex ('$tar_sha')" ;;
  esac

  if ! jq -n \
    --arg arch "arm64" \
    --arg kernel_release "$kernel_release" \
    --argjson rootfs_files "$rootfs_files" \
    --argjson tar_size_bytes "$tar_size" \
    --arg tar_sha256 "$tar_sha" \
    --arg mmdebstrap "$mmdebstrap_version" \
    --arg builder_dry_run "$BUILDER_DRY_RUN" \
    --arg created "$created" \
    --arg plan "$PLAN" \
    --arg guest_out "$OUT" \
    '{
       schema: 1,
       name: "sysemble-vm-build",
       arch: $arch,
       kernel_release: $kernel_release,
       rootfs_files: $rootfs_files,
       tar_path: "rootfs.tar.gz",
       tar_size_bytes: $tar_size_bytes,
       tar_sha256: $tar_sha256,
       mmdebstrap: $mmdebstrap,
       builder_dry_run: $builder_dry_run,
       created: $created,
       plan: $plan,
       out: $guest_out
     }' >"$tmp"; then
    fail "jq failed while writing $tmp"
  fi
  mv -f "$tmp" "$EXPORT/artifact-vm.json" || fail "cannot rename $tmp to artifact-vm.json"
  sync
  log "artifact: $EXPORT/artifact-vm.json"
}

main() {
  parse_args "$@"
  validate

  log "plan=$PLAN out=$OUT export=$EXPORT"
  stage_builder_dry_run
  stage_rootfs
  stage_export_tar
  stage_artifact
  log "kernel_release=$(uname -r) rootfs.tar.gz=$(stat -c %s "$EXPORT/rootfs.tar.gz") bytes"
  printf 'VM-BUILD: complete\n'
  exit 0
}

main "$@"
