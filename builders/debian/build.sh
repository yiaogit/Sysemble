#!/usr/bin/env bash
# Sysemble Debian builder (P0-a + P0-b native build path + P0-c1 GPT/GRUB/UEFI).
#
# Reads a plan.json produced by `sysemble plan --json` and bootstraps a Debian
# rootfs with mmdebstrap, either natively (Linux/root) or inside a
# debian:trixie Docker container. In native mode without --dry-run (or with
# --execute) it then:
#   - creates a GPT disk image (p1 ESP vfat32, p2 root ext4) loop-free,
#   - writes a FAT32 ESP in esp.img, installs GRUB EFI with an embedded
#     grub.cfg, copies the ESP tree with mcopy, and merges it with dd,
#   - converts disk.img to qcow2 with qemu-img, and writes artifact.json.
#
# Contract (frozen):
#   build.sh --plan <plan.json> --out <dir> [--dry-run] [--execute] [--engine docker|native]
#
# Only builders/** is modified by this script at runtime: everything is written
# under --out. The host system, network configuration, and boot configuration
# are never touched.
#
# Requires bash 3.2+ (macOS /bin/bash). Do not use bash 4 features.

set -euo pipefail

# Resolve the directory holding lib.sh without relying on external dirname(1):
# the no-JSON-parser test path must work with an empty PATH.
case "$0" in
  */*) BUILD_DIR=${0%/*} ;;
  *) BUILD_DIR=. ;;
esac
BUILD_DIR=$(cd "$BUILD_DIR" && pwd)

# shellcheck source=builders/debian/lib.sh
. "$BUILD_DIR/lib.sh"

PLAN=""
OUT=""
DRY_RUN=0
EXECUTE=0
ENGINE="native"
BUILD_LOG=""
OUTPUTS_OWNED=0

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --plan)
        if [ "$#" -lt 2 ]; then
          err "--plan requires a value"
          usage >&2
          exit 2
        fi
        PLAN=$2
        shift 2
        ;;
      --plan=*)
        PLAN=${1#--plan=}
        shift
        ;;
      --out)
        if [ "$#" -lt 2 ]; then
          err "--out requires a value"
          usage >&2
          exit 2
        fi
        OUT=$2
        shift 2
        ;;
      --out=*)
        OUT=${1#--out=}
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --execute)
        EXECUTE=1
        shift
        ;;
      --engine)
        if [ "$#" -lt 2 ]; then
          err "--engine requires a value"
          usage >&2
          exit 2
        fi
        ENGINE=$2
        shift 2
        ;;
      --engine=*)
        ENGINE=${1#--engine=}
        shift
        ;;
      --)
        shift
        if [ "$#" -gt 0 ]; then
          err "unexpected argument: $1"
          usage >&2
          exit 2
        fi
        ;;
      -*)
        err "unknown option: $1"
        usage >&2
        exit 2
        ;;
      *)
        err "unexpected argument: $1"
        usage >&2
        exit 2
        ;;
    esac
  done

  if [ "$DRY_RUN" -eq 1 ] && [ "$EXECUTE" -eq 1 ]; then
    err "--dry-run and --execute are mutually exclusive"
    usage >&2
    exit 2
  fi

  case "$ENGINE" in
    native | docker)
      ;;
    *)
      err "--engine must be 'native' or 'docker' (got '$ENGINE')"
      usage >&2
      exit 2
      ;;
  esac

  if [ -z "$PLAN" ]; then
    err "--plan is required"
    usage >&2
    exit 2
  fi
  if [ -z "$OUT" ]; then
    err "--out is required"
    usage >&2
    exit 2
  fi
}

validate_out_arg() {
  case "$OUT" in
    -*)
      err "--out must not start with '-'"
      return 2
      ;;
  esac

  # Reject "", "/", "//", "///": anything made only of slashes would resolve
  # to the filesystem root.
  case "$OUT" in
    *[!/]*) : ;;
    *)
      err "refusing --out '$OUT': it resolves to the filesystem root"
      return 2
      ;;
  esac

  if { [ -e "$OUT" ] || [ -L "$OUT" ]; } && [ ! -d "$OUT" ]; then
    err "--out exists but is not a directory: $OUT"
    return 2
  fi
  return 0
}

validate_plan_arg() {
  case "$PLAN" in
    -*)
      err "--plan must not start with '-'"
      return 2
      ;;
  esac
  if [ ! -f "$PLAN" ]; then
    err "plan file not found: $PLAN"
    return 2
  fi
  if [ ! -r "$PLAN" ]; then
    err "plan file is not readable: $PLAN"
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Output directory handling
# ---------------------------------------------------------------------------

prepare_out() {
  if ! mkdir -p "$OUT"; then
    err "cannot create --out directory: $OUT"
    return 2
  fi

  OUT_ABS=$(cd "$OUT" && pwd -P) || {
    err "cannot resolve --out directory: $OUT"
    return 2
  }

  # Resolve symlinks and "." components before writing anything: --out may
  # have been a symlink to "/".
  case "$OUT_ABS" in
    /)
      err "refusing --out: '$OUT' resolves to the filesystem root"
      return 2
      ;;
  esac

  if [ ! -d "$OUT_ABS" ]; then
    err "--out is not a directory after creation: $OUT_ABS"
    return 2
  fi
  if [ ! -w "$OUT_ABS" ]; then
    err "--out directory is not writable: $OUT_ABS"
    return 2
  fi

  return 0
}

# Atomically write <out>/plan.copy.json. Temp file + rename avoids writing
# through a pre-existing symlink or hardlink (which could modify a host file
# outside --out).
copy_plan() {
  local tmp=""

  if [ -d "$OUT_ABS/plan.copy.json" ]; then
    err "refusing to replace a directory with the plan copy: $OUT_ABS/plan.copy.json"
    return 2
  fi

  tmp=$(mktemp "$OUT_ABS/.plan.copy.json.XXXXXX") || {
    err "cannot create a temporary file under $OUT_ABS"
    return 2
  }
  if ! cp "$PLAN" "$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    err "cannot write the plan copy under $OUT_ABS"
    return 2
  fi
  if ! mv -f "$tmp" "$OUT_ABS/plan.copy.json"; then
    rm -f "$tmp" 2>/dev/null || true
    err "cannot finalize the plan copy: $OUT_ABS/plan.copy.json"
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Build log and failure cleanup (P0-b, extended by P0-c)
#
# Every build-stage message and every external command's stdout/stderr is
# appended to <out>/build.log via tee. The EXIT trap removes only derived
# intermediates (esp.img, a half-written qcow2, the artifact temp file) and
# keeps rootfs/, disk.img, esp/, grub.cfg, and build.log for post-mortem, as
# required by the P0-c workplan §2 and the task's failure-cleanup rule.
# ---------------------------------------------------------------------------

prepare_build_log() {
  BUILD_LOG="$OUT_ABS/build.log"
  if ! : >"$BUILD_LOG"; then
    err "cannot create build log: $BUILD_LOG"
    return 2
  fi
  return 0
}

blog() {
  printf '%s\n' "$*" | tee -a "$BUILD_LOG"
}

blog_err() {
  printf 'build.sh: error: %s\n' "$*" | tee -a "$BUILD_LOG" >&2
}

run_logged() {
  local rc=0
  blog "  \$ $*"
  if "$@" 2>&1 | tee -a "$BUILD_LOG"; then
    return 0
  else
    rc=$?
    return "$rc"
  fi
}

build_exit_trap() {
  local rc=$1

  if [ "$rc" -ne 0 ] && [ "$OUTPUTS_OWNED" -eq 1 ]; then
    # P0-c: disk.img is deliberately kept for diagnosis (it may hold a valid
    # GPT/ext4 even when a later GRUB/mcopy/dd/qemu-img step failed).
    rm -f "$OUT_ABS/esp.img" "$OUT_ABS/disk.qcow2" \
      "$OUT_ABS/.artifact.json.tmp" "$OUT_ABS/.grub.cfg.tmp" 2>/dev/null || true
  fi
  cleanup_tmp
}

install_build_exit_trap() {
  trap 'build_exit_trap $?' EXIT
}

# /etc/hostname content. The plan contract has no hostname field, so P0-b uses
# plan.spec (the spec's meta.name), sanitized to a valid DNS hostname label.
plan_hostname() {
  local host=""

  host=$(
    printf '%s' "${PLAN_SPEC_VALUE:-}" |
      tr '[:upper:]' '[:lower:]' |
      sed -e 's/[^a-z0-9-]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' |
      cut -c1-63
  )
  if [ -z "$host" ]; then
    host="sysemble"
  fi
  printf '%s\n' "$host"
}

# One-line shell command passed to mmdebstrap --customize-hook. mmdebstrap runs
# the hook on the host with the rootfs directory as $1. systemctl enable is
# executed inside a chroot; failure is non-fatal and produces a warning in
# build.log (P0-b workplan risk 2).
make_customize_hook() {
  local host=$1

  printf '%s' "printf '%s\\n' '$host' > \"\$1/etc/hostname\"; if chroot \"\$1\" systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1; then :; else printf 'mmdebstrap customize hook: warning: could not enable serial-getty@ttyS0.service (non-fatal)\\n' >&2; fi"
}

# ---------------------------------------------------------------------------
# Dry run
# ---------------------------------------------------------------------------

print_packages() {
  local i=0

  printf '\nPackages (%d):\n' "${#PLAN_PACKAGES_VALUES[@]}"
  while [ "$i" -lt "${#PLAN_PACKAGES_VALUES[@]}" ]; do
    printf '  - %s\n' "${PLAN_PACKAGES_VALUES[$i]}"
    i=$((i + 1))
  done
}

print_modules_and_warnings() {
  local i=0

  printf '\nModules: '
  if [ "$PLAN_MODULES_TYPE" = "array" ]; then
    printf '%d\n' "${#PLAN_MODULES_VALUES[@]}"
    while [ "$i" -lt "${#PLAN_MODULES_VALUES[@]}" ]; do
      printf '  - %s\n' "${PLAN_MODULES_VALUES[$i]}"
      i=$((i + 1))
    done
  else
    printf '(invalid: %s)\n' "$PLAN_MODULES_TYPE"
  fi

  printf 'Warnings: '
  if [ "$PLAN_WARNINGS_TYPE" = "array" ]; then
    printf '%d\n' "${#PLAN_WARNINGS_VALUES[@]}"
    i=0
    while [ "$i" -lt "${#PLAN_WARNINGS_VALUES[@]}" ]; do
      printf '  ! %s\n' "${PLAN_WARNINGS_VALUES[$i]}"
      i=$((i + 1))
    done
  else
    printf '(invalid: %s)\n' "$PLAN_WARNINGS_TYPE"
  fi
}

do_dry_run() {
  prepare_out || return 2
  copy_plan || return 2

  local spec_text=""
  local pin_text=""

  spec_text=$(display_field "$PLAN_SPEC_TYPE" "$PLAN_SPEC_VALUE" "(not set)")
  pin_text=$(display_field "$PLAN_BASE_PIN_TYPE" "$PLAN_BASE_PIN_VALUE" "unpinned")

  printf 'Sysemble Debian builder - dry run (P0-a)\n'
  printf '  plan:       %s\n' "$PLAN"
  printf '  out:        %s\n' "$OUT_ABS"
  printf '  engine:     %s (not checked in dry-run)\n' "$ENGINE"
  printf '  apiVersion: %s\n' "$PLAN_API_VERSION_VALUE"
  printf '  spec:       %s\n' "$spec_text"
  printf '  base:       %s/%s (pin: %s)\n' \
    "$PLAN_BASE_KIND_VALUE" "$PLAN_BASE_RELEASE_VALUE" "$pin_text"
  printf '  arch:       %s\n' "$PLAN_TARGET_ARCH_VALUE"
  printf '  outputs:    %s\n' "$OUTPUTS_TEXT"

  printf '\nStages (planned):\n'
  printf '  [1/6] validate          plan structure is valid\n'
  printf '  [2/6] fetch base        %s/%s\n' "$PLAN_BASE_KIND_VALUE" "$PLAN_BASE_RELEASE_VALUE"
  printf '  [3/6] bootstrap rootfs  mmdebstrap --variant=minbase\n'
  printf '  [4/6] install packages  %d packages via --include\n' "$PKG_COUNT"
  printf '  [5/6] configure         not implemented in P0-a\n'
  printf '  [6/6] assemble image    not implemented in P0-a (requested: %s)\n' "$OUTPUTS_TEXT"

  print_packages

  printf '\nEstimates (from plan.estimates):\n'
  print_estimate "image_mb" "$PLAN_EST_IMAGE_MB_TYPE" "$PLAN_EST_IMAGE_MB_VALUE" "MB"
  print_estimate "build_minutes" "$PLAN_EST_BUILD_MINUTES_TYPE" "$PLAN_EST_BUILD_MINUTES_VALUE" "min"
  print_estimate "disk_mb" "$PLAN_EST_DISK_MB_TYPE" "$PLAN_EST_DISK_MB_VALUE" "MB"

  print_modules_and_warnings

  printf '\nPlanned command (%s):\n' "$ENGINE"
  if [ "$ENGINE" = "native" ]; then
    printf '  mmdebstrap --variant=minbase --include=<%d packages> %s %s/rootfs\n' \
      "$PKG_COUNT" "$PLAN_BASE_RELEASE_VALUE" "$OUT_ABS"
  else
    printf '  docker run --rm --privileged -v %s:/out debian:trixie \\\n' "$OUT_ABS"
    printf '    bash -c '"'"'apt-get update && apt-get install -y mmdebstrap && mmdebstrap ...'"'"'\n'
  fi

  printf '\nDry run complete: no image was built.\n'
  printf 'Plan copy written to: %s/plan.copy.json\n' "$OUT_ABS"
  return 0
}

# ---------------------------------------------------------------------------
# Build helpers
# ---------------------------------------------------------------------------

make_pkg_csv() {
  local i=0
  local csv=""

  while [ "$i" -lt "${#PLAN_PACKAGES_VALUES[@]}" ]; do
    if [ -z "$csv" ]; then
      csv=${PLAN_PACKAGES_VALUES[$i]}
    else
      csv="$csv,${PLAN_PACKAGES_VALUES[$i]}"
    fi
    i=$((i + 1))
  done
  printf '%s' "$csv"
}

finish_rootfs_only() {
  local rootfs=$1

  info "[build] stage 5/6: configure - not implemented in P0-a (skipped)"
  info "[build] stage 6/6: assemble GPT/GRUB/UEFI image - not supported by the docker engine (skipped)"
  warn "docker engine stops after the rootfs; P0-c GPT/GRUB/UEFI disk assembly is native-only and unverified for docker"
  info "rootfs ready: $rootfs"
}

build_native() {
  local rootfs="$OUT_ABS/rootfs"
  local raw="$OUT_ABS/disk.img"
  local qcow="$OUT_ABS/disk.qcow2"
  local esp_dir="$OUT_ABS/esp"
  local esp_img="$OUT_ABS/esp.img"
  local grub_cfg="$OUT_ABS/grub.cfg"
  local grub_staged="$esp_dir/boot/grub/grub.cfg"
  local grub_efi="$esp_dir/EFI/BOOT/BOOTX64.EFI"
  local pkg_csv=""
  local hostname=""
  local hook=""
  local kernel=""
  local initrd=""
  local kernel_name=""
  local initrd_name=""
  local rootfs_mb=0
  local disk_mb=0
  local root_part_mb=0
  local root_fs_blocks=0
  local esp_bytes=0

  # P0-a rule: never overwrite an existing rootfs. The disk outputs are also
  # refused so a stale image can never be paired with a fresh rootfs.
  if [ -e "$rootfs" ] || [ -L "$rootfs" ]; then
    blog_err "refusing to overwrite existing path: $rootfs"
    return 6
  fi
  if [ -e "$raw" ] || [ -L "$raw" ]; then
    blog_err "refusing to overwrite existing image: $raw"
    return 6
  fi
  if [ -e "$qcow" ] || [ -L "$qcow" ]; then
    blog_err "refusing to overwrite existing image: $qcow"
    return 6
  fi

  pkg_csv=$(make_pkg_csv)
  if [ -z "$pkg_csv" ]; then
    blog_err "package list is empty; refusing to build"
    return 6
  fi

  hostname=$(plan_hostname)
  hook=$(make_customize_hook "$hostname")

  # esp/, esp.img, and grub.cfg are derived P0-c intermediates. They can only
  # survive a previous interrupted/failed attempt here, because rootfs/ and the
  # disk images above are refused when they already exist. Removing them keeps
  # a retry from mixing a stale ESP with a fresh disk.img.
  if [ -e "$esp_dir" ] || [ -L "$esp_dir" ] ||
    [ -e "$esp_img" ] || [ -L "$esp_img" ] ||
    [ -e "$grub_cfg" ] || [ -L "$grub_cfg" ]; then
    blog "[build] removing stale P0-c staging outputs from a previous attempt"
    if ! rm -rf "$esp_dir" "$esp_img" "$grub_cfg"; then
      blog_err "cannot remove stale staging outputs under $OUT_ABS"
      return 6
    fi
  fi
  rm -f "$OUT_ABS/.grub.cfg.tmp" "$OUT_ABS/.artifact.json.tmp" 2>/dev/null || true

  # From here on, derived outputs belong to this build and the EXIT trap may
  # remove the ESP image, a partial qcow2, and temp manifests.
  OUTPUTS_OWNED=1

  blog "[build] stage 1/6: validate - plan is valid"
  blog "[build] stage 2/6: fetch base - $PLAN_BASE_KIND_VALUE/$PLAN_BASE_RELEASE_VALUE"
  blog "[build] stage 3/6: bootstrap rootfs - $rootfs"
  blog "[build] stage 4/6: install packages - $PKG_COUNT packages via --include"
  blog "[build] customize: hostname=$hostname, enable serial-getty@ttyS0.service (failure is non-fatal)"

  export DEBIAN_FRONTEND=noninteractive
  if ! run_logged mmdebstrap --variant=minbase --include="$pkg_csv" \
    --customize-hook="$hook" "$PLAN_BASE_RELEASE_VALUE" "$rootfs"; then
    blog_err "mmdebstrap failed; partial rootfs (if any) and build.log are kept"
    return 6
  fi
  if [ ! -d "$rootfs" ]; then
    blog_err "mmdebstrap reported success but $rootfs is missing"
    return 6
  fi

  kernel=$(find_boot_image "$rootfs" vmlinuz) || {
    blog_err "no kernel found: expected $rootfs/boot/vmlinuz-* after mmdebstrap"
    return 6
  }
  initrd=$(find_boot_image "$rootfs" initrd.img) || {
    blog_err "no initrd found: expected $rootfs/boot/initrd.img-* after mmdebstrap"
    return 6
  }
  kernel_name=${kernel##*/}
  initrd_name=${initrd##*/}
  blog "[build] boot: kernel=$kernel_name, initrd=$initrd_name"

  rootfs_mb=$(rootfs_size_mb "$rootfs") || {
    blog_err "cannot measure rootfs size: $rootfs"
    return 6
  }
  case "$rootfs_mb" in
    '' | *[!0-9]*)
      blog_err "invalid rootfs size: '$rootfs_mb'"
      return 6
      ;;
  esac
  disk_mb=$(compute_disk_size_mb "$rootfs_mb") || {
    blog_err "cannot compute disk size from rootfs size ${rootfs_mb} MB"
    return 6
  }
  root_part_mb=$((disk_mb - ESP_SIZE_MB))
  root_fs_blocks=$(compute_root_fs_blocks "$disk_mb") || {
    blog_err "cannot compute the root filesystem size for a ${disk_mb} MB disk"
    return 6
  }

  blog "[build] stage 5/6: assemble GPT disk image - rootfs ${rootfs_mb} MB, disk ${disk_mb} MB"
  blog "[build] partitions: p1 esp ${ESP_SIZE_MB} MB (vfat32, start 1 MiB), p2 root ${root_part_mb} MB (ext4, start ${ROOT_START_MB} MiB)"
  blog "[build] root fs: ${root_fs_blocks} x 4 KiB blocks (explicit size keeps ext4 inside p2/GPT)"

  if ! run_logged truncate -s "${disk_mb}M" "$raw"; then
    blog_err "truncate failed: $raw"
    return 6
  fi
  if ! run_logged sgdisk -Z "$raw"; then
    blog_err "sgdisk -Z failed; disk.img and build.log are kept for diagnosis"
    return 6
  fi
  if ! run_logged sgdisk -n 1:2048:+512M -t 1:ef00 -n 2:0:0 -t 2:8300 "$raw"; then
    blog_err "sgdisk partition creation failed; disk.img and build.log are kept for diagnosis"
    return 6
  fi
  # Loop-free ext4: write the filesystem at the byte offset of partition 2.
  # The explicit block count is required: without it mke2fs sizes the FS to
  # end-of-file, which is larger than GPT p2 (the last 33 sectors hold the
  # backup GPT) and the kernel would refuse to mount it ("bad geometry").
  if ! run_logged mkfs.ext4 -F -b 4096 -E "offset=$ROOT_OFFSET_BYTES" \
    -d "$rootfs" -L SYMBLE "$raw" "$root_fs_blocks"; then
    blog_err "mkfs.ext4 failed; disk.img and build.log are kept for diagnosis"
    return 6
  fi

  blog "[build] esp: FAT32 image, GRUB EFI (embedded grub.cfg), mcopy"
  if ! run_logged mkfs.vfat -F 32 -C -n ESP "$esp_img" "$ESP_IMAGE_KB"; then
    blog_err "mkfs.vfat failed; disk.img and build.log are kept for diagnosis"
    return 6
  fi
  if ! mkdir -p "$esp_dir/boot/grub" "$esp_dir/EFI/BOOT"; then
    blog_err "cannot create the ESP staging tree: $esp_dir"
    return 6
  fi
  if ! grub_cfg_text "$kernel_name" "$initrd_name" \
    >"$OUT_ABS/.grub.cfg.tmp" 2>"$TMP_DIR/grub.err"; then
    if [ -s "$TMP_DIR/grub.err" ]; then
      cat "$TMP_DIR/grub.err" | tee -a "$BUILD_LOG" >&2
    fi
    rm -f "$OUT_ABS/.grub.cfg.tmp" 2>/dev/null || true
    blog_err "cannot render grub.cfg for kernel=$kernel_name initrd=$initrd_name"
    return 6
  fi
  if ! mv -f "$OUT_ABS/.grub.cfg.tmp" "$grub_cfg"; then
    blog_err "cannot write grub.cfg: $grub_cfg"
    return 6
  fi
  if ! cp "$grub_cfg" "$grub_staged"; then
    blog_err "cannot stage grub.cfg under $esp_dir"
    return 6
  fi
  if ! run_logged grub-mkstandalone -O x86_64-efi -o "$grub_efi" \
    --modules="$GRUB_MODULES" \
    "boot/grub/grub.cfg=$grub_staged"; then
    blog_err "grub-mkstandalone failed; disk.img, esp/ and build.log are kept for diagnosis"
    return 6
  fi
  if [ ! -s "$grub_efi" ]; then
    blog_err "grub-mkstandalone reported success but $grub_efi is missing or empty"
    return 6
  fi
  if ! run_logged mcopy -i "$esp_img" -s "$esp_dir/EFI" "::/"; then
    blog_err "mcopy failed to populate the ESP; disk.img and build.log are kept for diagnosis"
    return 6
  fi
  if [ ! -f "$esp_img" ]; then
    blog_err "mkfs.vfat reported success but $esp_img is missing"
    return 6
  fi
  esp_bytes=$(wc -c <"$esp_img" | tr -d '[:space:]') || esp_bytes=""
  case "$esp_bytes" in
    '' | *[!0-9]*)
      blog_err "cannot determine the size of the ESP image: $esp_img"
      return 6
      ;;
  esac
  if [ "$esp_bytes" -ne "$((ESP_SIZE_MB * 1024 * 1024))" ]; then
    blog_err "esp.img is ${esp_bytes} bytes, not the ${ESP_SIZE_MB} MiB ESP partition; refusing to dd over partition 2"
    return 6
  fi
  # Merge the FAT32 ESP at its GPT partition offset (1 MiB). The GPT itself
  # lives in the first MiB, so it is not overwritten; conv=notrunc keeps dd
  # from truncating the ext4 partition that lives after the ESP.
  if ! run_logged dd if="$esp_img" of="$raw" bs=1M seek=1 conv=notrunc; then
    blog_err "dd failed to merge the ESP into disk.img; disk.img and build.log are kept for diagnosis"
    return 6
  fi
  if ! rm -f "$esp_img"; then
    blog "[build] warning: could not remove the intermediate ESP image: $esp_img"
  fi

  if ! run_logged qemu-img convert -O qcow2 "$raw" "$qcow"; then
    blog_err "qemu-img convert failed; the partial qcow2 is removed, disk.img and build.log are kept"
    return 6
  fi

  blog "[build] stage 6/6: write artifact manifest"
  if ! artifact_json "$OUT_ABS" "$PLAN_SPEC_VALUE" \
    "$PLAN_BASE_RELEASE_VALUE" "$PLAN_BASE_PIN_VALUE" \
    "$PLAN_TARGET_ARCH_VALUE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${PLAN_PACKAGES_VALUES[@]}" >"$OUT_ABS/.artifact.json.tmp" 2>"$TMP_DIR/artifact.err"; then
    if [ -s "$TMP_DIR/artifact.err" ]; then
      cat "$TMP_DIR/artifact.err" | tee -a "$BUILD_LOG" >&2
    fi
    rm -f "$OUT_ABS/.artifact.json.tmp" 2>/dev/null || true
    blog_err "artifact.json generation failed"
    return 6
  fi
  if ! mv -f "$OUT_ABS/.artifact.json.tmp" "$OUT_ABS/artifact.json"; then
    blog_err "cannot finalize artifact.json"
    return 6
  fi

  OUTPUTS_OWNED=0

  blog ""
  blog "[build] complete (mode: uefi)"
  blog "  rootfs:   $rootfs"
  blog "  raw:      $raw (${disk_mb} MB: GPT, p1 esp ${ESP_SIZE_MB} MB, p2 root ${root_part_mb} MB)"
  blog "  qcow2:    $qcow"
  blog "  grub:     $grub_efi (config: $grub_cfg)"
  blog "  artifact: $OUT_ABS/artifact.json"
  blog "  log:      $BUILD_LOG"
  return 0
}

IFS= read -r -d '' DOCKER_INNER <<'INNER' || true
set -euo pipefail
release=$1
packages=$2
export DEBIAN_FRONTEND=noninteractive

echo "[container] installing mmdebstrap ..."
apt-get update
apt-get install -y --no-install-recommends mmdebstrap ca-certificates debian-archive-keyring

echo "[container] bootstrapping Debian $release into /out/rootfs ..."
mmdebstrap --variant=minbase --include="$packages" "$release" /out/rootfs

echo "[container] rootfs ready: /out/rootfs"
INNER

build_docker() {
  local rootfs="$OUT_ABS/rootfs"
  local pkg_csv=""

  case "$OUT_ABS" in
    *:*)
      err "docker engine cannot bind-mount a path containing ':': $OUT_ABS"
      return 6
      ;;
  esac

  if [ -e "$rootfs" ] || [ -L "$rootfs" ]; then
    err "refusing to overwrite existing path: $rootfs"
    return 6
  fi

  pkg_csv=$(make_pkg_csv)
  if [ -z "$pkg_csv" ]; then
    err "package list is empty; refusing to build"
    return 6
  fi

  info "[build] stage 1/6: validate - plan is valid"
  info "[build] stage 2/6: fetch base - docker image debian:trixie"
  info "[build] stage 3/6: bootstrap rootfs - mmdebstrap inside the container"
  info "[build] stage 4/6: install packages - $PKG_COUNT packages via --include"

  # --privileged is required by mmdebstrap inside Docker (mount/chroot).
  # Only <out> is bind-mounted; the host filesystem is not exposed and the
  # container is removed afterwards.
  if ! docker run --rm --privileged -v "$OUT_ABS:/out" debian:trixie \
    bash -c "$DOCKER_INNER" sysemble-builder \
    "$PLAN_BASE_RELEASE_VALUE" "$pkg_csv"; then
    err "docker build failed; no complete rootfs was produced"
    return 6
  fi
  if [ ! -d "$rootfs" ]; then
    err "docker build reported success but $rootfs is missing"
    return 6
  fi

  finish_rootfs_only "$rootfs"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"

  validate_out_arg || exit 2
  validate_plan_arg || exit 2

  if ! detect_json_backend; then
    exit 5
  fi

  make_tmpdir || exit 2
  load_plan_records || exit 1
  validate_plan || exit 1

  if [ "$DRY_RUN" -eq 1 ]; then
    do_dry_run || exit $?
    exit 0
  fi

  if [ "$ENGINE" = "native" ]; then
    native_preflight || exit 3
    if [ "$PLAN_SPEC_TYPE" != "string" ] || [ -z "$PLAN_SPEC_VALUE" ]; then
      err "plan: plan.spec is required for a real build (artifact.json requires it)"
      exit 1
    fi
    prepare_out || exit 2
    copy_plan || exit 2
    prepare_build_log || exit 2
    install_build_exit_trap
    build_native || exit 6
  else
    if [ "$EXECUTE" -eq 1 ]; then
      err "P0-c --execute is native-only: docker mode does not assemble GPT/GRUB/UEFI disk images or artifact.json (unverified)"
      exit 2
    fi
    docker_preflight || exit 4
    prepare_out || exit 2
    copy_plan || exit 2
    build_docker || exit 6
  fi

  exit 0
}

main "$@"
