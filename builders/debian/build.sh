#!/usr/bin/env bash
# Sysemble Debian builder (P0-a + P0-b native build path + P0-c1 GPT/GRUB/UEFI
# + P0-d1 desktop boot + P0-d2 live ISO + P0-d3 unattended installer ISO).
#
# Reads a plan.json produced by `sysemble plan --json` and bootstraps a Debian
# rootfs with mmdebstrap, either natively (Linux/root) or inside a
# debian:trixie Docker container. In native mode without --dry-run (or with
# --execute) it then builds the outputs requested by plan.target.outputs:
#   - iso-only: mksquashfs rootfs -> iso/live/filesystem.squashfs, copies the
#     highest kernel/initrd to iso/live/, builds an 8 MiB FAT efi.img with
#     grub-mkstandalone (embedded live grub.cfg) + mcopy, and packs a UEFI
#     El Torito ISO with xorriso. No disk/partition/GRUB-disk work is done.
#   - iso + qcow2/raw: both the ISO and the P0-c/d1 GPT/UEFI disk image.
#   - qcow2/raw only: the frozen P0-c/d1 disk pipeline.
#
# P0-d1: when plan.packages names a display manager (gdm3/sddm/lightdm) the
# kernel cmdline targets graphical.target (plus journald console forwarding),
# the artifact records the inferred desktop and memory_mb=2048; otherwise the
# frozen multi-user cmdline and memory_mb=1024 are kept.
#
# P0-d2: a live ISO build adds live-boot and live-boot-initramfs-tools to
# --include (deduplicated; artifact.packages keeps the plan list) and records
# boot.mode="iso" / boot.iso="live.iso" in artifact.json. An ISO-only manifest
# omits partitions.
#
# P0-d3: --installer (ISO-only plans) bakes the headless
# /usr/local/sbin/sysemble-install + sysemble-install.service into the live
# rootfs via the customize hook, adds
# rsync/grub-efi-amd64/grub-efi-amd64-bin/dosfstools/gdisk/e2fsprogs to
# --include, appends sysemble.install=/dev/vda to the ISO cmdline, and records
# boot.mode="install" + boot.install_device="/dev/vda". Images stays live.iso;
# the installer partitions the guest disk itself.
#
# P0-e1: --installer-tui (ISO-only plans) uses the same script/unit/packages
# but appends sysemble.install.tui=1 to the ISO cmdline and records
# boot.mode="install" + boot.install_tui=true with NO install_device. The
# shared installer script starts its serial wizard for that cmdline marker.
#
# Contract (frozen):
#   build.sh --plan <plan.json> --out <dir> [--dry-run] [--execute]
#            [--engine docker|native] [--installer | --installer-tui]
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

# P0-d3 installer sources baked into the live rootfs by the customize hook.
INSTALLER_SRC_DIR="$BUILD_DIR/$INSTALLER_DIR_NAME"
INSTALLER_SCRIPT_SRC="$INSTALLER_SRC_DIR/$INSTALLER_SCRIPT_NAME"
INSTALLER_UNIT_SRC="$INSTALLER_SRC_DIR/$INSTALLER_UNIT_NAME"

PLAN=""
OUT=""
DRY_RUN=0
EXECUTE=0
ENGINE="native"
INSTALLER=0
INSTALLER_TUI=0
BUILD_LOG=""
OUTPUTS_OWNED=0
DISK_OUTPUTS_OWNED=0
ISO_OUTPUTS_OWNED=0

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
      --installer)
        INSTALLER=1
        shift
        ;;
      --installer-tui)
        INSTALLER_TUI=1
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

  if [ "$INSTALLER" -eq 1 ] && [ "$INSTALLER_TUI" -eq 1 ]; then
    err "--installer and --installer-tui are mutually exclusive"
    usage >&2
    exit 2
  fi
  # --installer-tui is an installer variant: the shared script/unit/packages
  # path is exactly the P0-d3 one, and INSTALLER_TUI only changes the ISO
  # cmdline and the artifact boot object.
  if [ "$INSTALLER_TUI" -eq 1 ]; then
    INSTALLER=1
  fi

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

# P0-d3: --installer only makes sense for a pure live ISO build. Reject it
# before touching --out so a disk-only plan can never produce a half-built
# installer artifact.
validate_installer_mode() {
  local mode=""

  if [ "$INSTALLER" -eq 0 ]; then
    return 0
  fi
  mode=$(plan_build_mode)
  if [ "$mode" != "iso" ]; then
    if [ "$INSTALLER_TUI" -eq 1 ]; then
      err "--installer-tui requires an ISO-only plan (target.outputs contains 'iso' and no qcow2/raw); this plan is '$mode'"
    else
      err "--installer requires an ISO-only plan (target.outputs contains 'iso' and no qcow2/raw); this plan is '$mode'"
    fi
    return 2
  fi
  return 0
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
    # P0-c/P0-d2: disk.img and the iso/ tree are deliberately kept for
    # diagnosis (they may hold a valid GPT/ext4 or a complete squashfs even
    # when a later GRUB/mcopy/dd/qemu-img/xorriso step failed). Half-written
    # final images and temporary FAT files that belong to this build's mode
    # are removed; unrelated pre-existing outputs are left alone.
    if [ "$DISK_OUTPUTS_OWNED" -eq 1 ]; then
      rm -f "$OUT_ABS/esp.img" "$OUT_ABS/disk.qcow2" \
        "$OUT_ABS/.grub.cfg.tmp" 2>/dev/null || true
    fi
    if [ "$ISO_OUTPUTS_OWNED" -eq 1 ]; then
      rm -f "$OUT_ABS/efi.img" "$OUT_ABS/live.iso" \
        "$OUT_ABS/.iso-grub.cfg.tmp" 2>/dev/null || true
    fi
    rm -f "$OUT_ABS/.artifact.json.tmp" 2>/dev/null || true
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

# Shell fragment for the P0-d1 graphical boot evidence unit. Kept separate so
# the base (no-DM) hook stays byte-identical to P0-c. The fragment is appended
# to the --customize-hook command and runs on the host with the rootfs as $1.
make_boot_evidence_hook_fragment() {
  local display_manager=$1
  local unit=""

  unit=$(boot_evidence_service_text "$display_manager") || return 1

  printf '; mkdir -p "$1/etc/systemd/system"\n'
  printf "cat >\"\$1/etc/systemd/system/sysemble-boot-evidence.service\" <<'SYMBLE_EVIDENCE'\n"
  printf '%s\n' "$unit"
  printf 'SYMBLE_EVIDENCE\n'
  printf 'mkdir -p "$1/etc/systemd/system/graphical.target.wants"\n'
  printf 'ln -sfn ../sysemble-boot-evidence.service "$1/etc/systemd/system/graphical.target.wants/sysemble-boot-evidence.service"\n'
  printf 'chroot "$1" systemctl enable sysemble-boot-evidence.service >/dev/null 2>&1 || true\n'
}

# P0-d2: after all packages are configured, regenerate the initramfs so the
# live-boot hook installed by live-boot-initramfs-tools is definitely part of
# initrd.img. Debian postinst triggers normally do this already, but an
# explicit update removes that ordering dependency. mmdebstrap runs the hook
# on the host with the rootfs as $1, so the command runs inside the chroot and
# a failure fails the build (exit 6) instead of producing a non-live initrd.
make_iso_initramfs_hook_fragment() {
  printf '; printf "mmdebstrap customize hook: update-initramfs for live-boot\\n"; chroot "$1" update-initramfs -u -k all'
}

# P0-d3: copy the frozen installer script (0755) and systemd unit into the
# live rootfs and enable the unit through multi-user.target.wants. The script
# and unit are embedded verbatim as quoted heredocs, so the hook does not
# depend on the source tree being readable when mmdebstrap runs it.
make_installer_hook_fragment() {
  local script=$1
  local unit=$2

  printf '; mkdir -p "$1/usr/local/sbin" "$1/etc/systemd/system/multi-user.target.wants"\n'
  printf "cat >\"\$1%s\" <<'SYMBLE_INSTALL_SCRIPT'\n" "$INSTALLER_SCRIPT_INSTALL_PATH"
  cat "$script"
  printf 'SYMBLE_INSTALL_SCRIPT\n'
  printf 'chmod 0755 "$1%s"\n' "$INSTALLER_SCRIPT_INSTALL_PATH"
  printf "cat >\"\$1%s\" <<'SYMBLE_INSTALL_UNIT'\n" "$INSTALLER_UNIT_INSTALL_PATH"
  cat "$unit"
  printf 'SYMBLE_INSTALL_UNIT\n'
  printf 'ln -sfn ../%s "$1%s"\n' "$INSTALLER_UNIT_NAME" "$INSTALLER_WANTS_LINK_PATH"
}

# P0-e1: the shared P0-d3 unit is gated on
# "ConditionKernelCommandLine=sysemble.install". systemd matches a single-word
# condition against a cmdline word or the left-hand side of an assignment, so
# that condition does not match "sysemble.install.tui=1". Keep the unit file
# byte-identical (the unattended contract) and add a drop-in that resets the
# condition list and ORs both installer markers through triggering conditions.
make_installer_tui_hook_fragment() {
  printf '; mkdir -p "$1/etc/systemd/system/%s.d"\n' "$INSTALLER_UNIT_NAME"
  printf "cat >\"\$1/etc/systemd/system/%s.d/tui-cmdline.conf\" <<'SYMBLE_INSTALL_TUI_DROPIN'\n" "$INSTALLER_UNIT_NAME"
  printf '[Unit]\n'
  printf 'ConditionKernelCommandLine=\n'
  printf 'ConditionKernelCommandLine=|%s\n' "$INSTALLER_KERNEL_PARAM"
  printf 'ConditionKernelCommandLine=|%s\n' "$INSTALLER_TUI_KERNEL_PARAM"
  printf 'SYMBLE_INSTALL_TUI_DROPIN\n'
}

# Shell command passed to mmdebstrap --customize-hook. mmdebstrap runs the hook
# on the host with the rootfs directory as $1. systemctl enable is executed
# inside a chroot; failure is non-fatal and produces a warning in build.log
# (P0-b workplan risk 2). A desktop plan also installs and enables the P0-d1
# boot evidence oneshot; an ISO plan regenerates the initramfs for live-boot;
# an installer ISO bakes in the P0-d3 script/unit (plus the P0-e1 drop-in for
# the TUI cmdline marker).
make_customize_hook() {
  local host=$1
  local display_manager=${2:-}
  local iso=${3:-0}
  local installer=${4:-0}
  local installer_tui=${5:-0}
  local evidence=""
  local install_fragment=""
  local tui_fragment=""
  local initramfs=""

  if [ -n "$display_manager" ]; then
    evidence=$(make_boot_evidence_hook_fragment "$display_manager") || return 1
  fi
  if [ "$installer" -eq 1 ]; then
    install_fragment=$(make_installer_hook_fragment "$INSTALLER_SCRIPT_SRC" "$INSTALLER_UNIT_SRC") || return 1
    if [ "$installer_tui" -eq 1 ]; then
      tui_fragment=$(make_installer_tui_hook_fragment) || return 1
    fi
  fi
  if [ "$iso" -eq 1 ]; then
    initramfs=$(make_iso_initramfs_hook_fragment) || return 1
  fi

  printf '%s' "printf '%s\\n' '$host' > \"\$1/etc/hostname\"; if chroot \"\$1\" systemctl enable serial-getty@ttyS0.service >/dev/null 2>&1; then :; else printf 'mmdebstrap customize hook: warning: could not enable serial-getty@ttyS0.service (non-fatal)\\n' >&2; fi${evidence}${install_fragment}${tui_fragment}${initramfs}"
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
  local mode=""
  local iso=0
  local disk=0
  local desktop=""
  local desktop_on=0
  local runtime_csv=""
  local runtime_count=0

  mode=$(plan_build_mode)
  case "$mode" in
    iso) iso=1 ;;
    iso-disk) iso=1; disk=1 ;;
    *) disk=1 ;;
  esac
  if desktop=$(detect_display_manager "${PLAN_PACKAGES_VALUES[@]}"); then
    desktop_on=1
  else
    desktop=""
    desktop_on=0
  fi
  if [ "$INSTALLER" -eq 1 ]; then
    desktop=""
    desktop_on=0
  fi
  if [ "$iso" -eq 1 ]; then
    runtime_csv=$(runtime_packages_for 1 "$desktop_on" "$INSTALLER")
    runtime_count=$(runtime_package_count_for 1 "$desktop_on" "$INSTALLER")
  fi

  spec_text=$(display_field "$PLAN_SPEC_TYPE" "$PLAN_SPEC_VALUE" "(not set)")
  pin_text=$(display_field "$PLAN_BASE_PIN_TYPE" "$PLAN_BASE_PIN_VALUE" "unpinned")

  printf 'Sysemble Debian builder - dry run (P0-d3/P0-e1)\n'
  printf '  plan:       %s\n' "$PLAN"
  printf '  out:        %s\n' "$OUT_ABS"
  printf '  engine:     %s (not checked in dry-run)\n' "$ENGINE"
  printf '  apiVersion: %s\n' "$PLAN_API_VERSION_VALUE"
  printf '  spec:       %s\n' "$spec_text"
  printf '  base:       %s/%s (pin: %s)\n' \
    "$PLAN_BASE_KIND_VALUE" "$PLAN_BASE_RELEASE_VALUE" "$pin_text"
  printf '  arch:       %s\n' "$PLAN_TARGET_ARCH_VALUE"
  printf '  outputs:    %s\n' "$OUTPUTS_TEXT"
  printf '  build mode: %s\n' "$mode"
  if [ "$INSTALLER" -eq 1 ]; then
    if [ "$INSTALLER_TUI" -eq 1 ]; then
      printf '  installer:  enabled (ISO-only TUI wizard, memory_mb=%s)\n' \
        "$ISO_BOOT_MEMORY_MB_DEFAULT"
    else
      printf '  installer:  enabled (ISO-only, install_device=%s, memory_mb=%s)\n' \
        "$INSTALLER_DEVICE_DEFAULT" "$ISO_BOOT_MEMORY_MB_DEFAULT"
    fi
    printf '  installer:  script=%s unit=%s\n' \
      "$INSTALLER_SCRIPT_INSTALL_PATH" "$INSTALLER_UNIT_INSTALL_PATH"
  fi

  printf '\nStages (planned):\n'
  printf '  [1/6] validate          plan structure is valid\n'
  printf '  [2/6] fetch base        %s/%s\n' "$PLAN_BASE_KIND_VALUE" "$PLAN_BASE_RELEASE_VALUE"
  printf '  [3/6] bootstrap rootfs  mmdebstrap --variant=minbase\n'
  # Keep this line byte-compatible with the P0-a acceptance check even when
  # the plan also asks for an ISO; the builder-added runtime packages are
  # listed separately below.
  printf '  [4/6] install packages  %d packages via --include\n' "$PKG_COUNT"
  printf '  [5/6] configure         not implemented in P0-a\n'
  if [ "$iso" -eq 1 ] && [ "$disk" -eq 0 ]; then
    printf '  [6/6] assemble image    live ISO: mksquashfs + grub-mkstandalone + xorriso (requested: %s)\n' "$OUTPUTS_TEXT"
  elif [ "$iso" -eq 1 ]; then
    printf '  [6/6] assemble image    live ISO + GPT disk image (requested: %s)\n' "$OUTPUTS_TEXT"
  else
    printf '  [6/6] assemble image    not implemented in P0-a (requested: %s)\n' "$OUTPUTS_TEXT"
  fi

  print_packages
  if [ "$iso" -eq 1 ]; then
    if [ -n "$runtime_csv" ]; then
      printf 'Runtime packages (builder-added, deduplicated): %s\n' "$runtime_csv"
    else
      printf 'Runtime packages (builder-added, deduplicated): (none)\n'
    fi
  fi

  printf '\nEstimates (from plan.estimates):\n'
  print_estimate "image_mb" "$PLAN_EST_IMAGE_MB_TYPE" "$PLAN_EST_IMAGE_MB_VALUE" "MB"
  print_estimate "build_minutes" "$PLAN_EST_BUILD_MINUTES_TYPE" "$PLAN_EST_BUILD_MINUTES_VALUE" "min"
  print_estimate "disk_mb" "$PLAN_EST_DISK_MB_TYPE" "$PLAN_EST_DISK_MB_VALUE" "MB"

  print_modules_and_warnings

  printf '\nPlanned command (%s):\n' "$ENGINE"
  if [ "$ENGINE" = "native" ]; then
    printf '  mmdebstrap --variant=minbase --include=<%d packages> %s %s/rootfs\n' \
      "$PKG_COUNT" "$PLAN_BASE_RELEASE_VALUE" "$OUT_ABS"
    if [ "$iso" -eq 1 ]; then
      printf '  mksquashfs %s/rootfs %s/iso/live/filesystem.squashfs -comp zstd -noappend\n' \
        "$OUT_ABS" "$OUT_ABS"
      printf '  grub-mkstandalone -O x86_64-efi -o %s/esp/EFI/BOOT/BOOTX64.EFI --modules=<live> ...\n' "$OUT_ABS"
      printf '  mkfs.vfat -C -n EFI %s/efi.img 8192 && mcopy -i %s/efi.img -s %s/esp/EFI ::/\n' \
        "$OUT_ABS" "$OUT_ABS" "$OUT_ABS"
      printf '  xorriso -as mkisofs -R -J -joliet-long -V SYMBLE -o %s/live.iso ... %s/iso\n' \
        "$OUT_ABS" "$OUT_ABS"
    fi
    if [ "$INSTALLER" -eq 1 ]; then
      printf '  customize hook: install %s (0755) + %s + multi-user.target.wants symlink\n' \
        "$INSTALLER_SCRIPT_INSTALL_PATH" "$INSTALLER_UNIT_INSTALL_PATH"
      if [ "$INSTALLER_TUI" -eq 1 ]; then
        printf '  ISO cmdline: %s %s\n' "$ISO_BOOT_CMDLINE" "$INSTALLER_TUI_MARKER"
        printf '  installer unit drop-in: %s.d/tui-cmdline.conf (sysemble.install OR sysemble.install.tui)\n' \
          "$INSTALLER_UNIT_NAME"
        printf '  artifact: boot.mode=install, boot.install_tui=true, no install_device, memory_mb=%s\n' \
          "$ISO_BOOT_MEMORY_MB_DEFAULT"
      else
        printf '  ISO cmdline: %s %s=%s\n' \
          "$ISO_BOOT_CMDLINE" "$INSTALLER_KERNEL_PARAM" "$INSTALLER_DEVICE_DEFAULT"
        printf '  artifact: boot.mode=install, boot.install_device=%s, memory_mb=%s\n' \
          "$INSTALLER_DEVICE_DEFAULT" "$ISO_BOOT_MEMORY_MB_DEFAULT"
      fi
    fi
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
  info "[build] stage 6/6: assemble image - not supported by the docker engine (skipped; requested: $OUTPUTS_TEXT)"
  warn "docker engine stops after the rootfs; native disk/ISO assembly is unverified for docker"
  info "rootfs ready: $rootfs"
}

# ---------------------------------------------------------------------------
# P0-d2 live ISO stage (frozen steps in docs/plan/P0-d2-workplan.md §3)
# ---------------------------------------------------------------------------

# Build live.iso from a complete rootfs. <kernel>/<initrd> are the versioned
# files found under rootfs/boot; they are copied to the stable live paths
# /live/vmlinuz and /live/initrd.img inside the ISO tree. <iso_cfg>, <iso_esp>,
# and <iso_efi> are the GRUB config, ESP staging tree, and intermediate FAT
# image (iso-only uses <out>/grub.cfg, <out>/esp, <out>/efi.img; an iso+disk
# plan uses a private <out>/iso-staging tree so it cannot clobber the disk
# build). <installer> is the P0-d3 flag: 1 appends the installer parameter to
# the live cmdline. <installer_tui> is the P0-e1 flag: 1 selects the
# sysemble.install.tui=1 marker instead of sysemble.install=<device>. Returns
# 0 on success, 6 on any failed step; the caller's EXIT trap removes a
# half-written live.iso/efi.img and keeps rootfs/, iso/, and logs.
build_iso_image() {
  local rootfs=$1
  local kernel=$2
  local initrd=$3
  local graphical=$4
  local iso_cfg=$5
  local iso_esp=$6
  local iso_efi=$7
  local iso_dir=$8
  local installer=${9:-0}
  local installer_tui=${10:-0}
  local iso_live="$iso_dir/live"
  local iso_boot="$iso_dir/boot/grub"
  local kernel_name=${kernel##*/}
  local initrd_name=${initrd##*/}
  local grub_efi="$iso_esp/EFI/BOOT/BOOTX64.EFI"
  local iso_out="$OUT_ABS/$ISO_ARTIFACT_NAME"

  blog "[build] stage 5/6: assemble live ISO - rootfs ${rootfs##*/}, kernel $kernel_name"
  blog "[build] iso tree: $iso_dir (live/filesystem.squashfs, live/vmlinuz, live/initrd.img, boot/grub/efi.img)"
  blog "[build] iso grub: menuentry \"$ISO_GRUB_MENU_TITLE\", search /live/vmlinuz, boot=live live-media-path=/live"
  if [ "$installer" -eq 1 ]; then
    if [ "$installer_tui" -eq 1 ]; then
      blog "[build] iso grub: installer TUI cmdline adds $INSTALLER_TUI_MARKER"
    else
      blog "[build] iso grub: installer cmdline adds $INSTALLER_KERNEL_PARAM=$INSTALLER_DEVICE_DEFAULT"
    fi
  fi

  if ! mkdir -p "$iso_live" "$iso_boot" "$iso_esp/EFI/BOOT"; then
    blog_err "cannot create the ISO staging tree under $OUT_ABS"
    return 6
  fi

  if ! run_logged mksquashfs "$rootfs" "$iso_live/filesystem.squashfs" -comp zstd -noappend; then
    blog_err "mksquashfs failed; rootfs/, the iso/ tree, and build.log are kept for diagnosis"
    return 6
  fi
  if [ ! -s "$iso_live/filesystem.squashfs" ]; then
    blog_err "mksquashfs reported success but filesystem.squashfs is missing or empty"
    return 6
  fi

  if ! cp "$kernel" "$iso_live/vmlinuz"; then
    blog_err "cannot copy the kernel to $iso_live/vmlinuz"
    return 6
  fi
  if ! cp "$initrd" "$iso_live/initrd.img"; then
    blog_err "cannot copy the initrd to $iso_live/initrd.img"
    return 6
  fi

  if ! iso_grub_cfg_text "$kernel_name" "$initrd_name" "$graphical" "$installer" "$installer_tui" \
    >"$OUT_ABS/.iso-grub.cfg.tmp" 2>"$TMP_DIR/grub.err"; then
    if [ -s "$TMP_DIR/grub.err" ]; then
      cat "$TMP_DIR/grub.err" | tee -a "$BUILD_LOG" >&2
    fi
    rm -f "$OUT_ABS/.iso-grub.cfg.tmp" 2>/dev/null || true
    blog_err "cannot render the live ISO grub.cfg for kernel=$kernel_name initrd=$initrd_name"
    return 6
  fi
  if ! mv -f "$OUT_ABS/.iso-grub.cfg.tmp" "$iso_cfg"; then
    blog_err "cannot write the live ISO grub.cfg: $iso_cfg"
    return 6
  fi

  if ! run_logged grub-mkstandalone -O x86_64-efi -o "$grub_efi" \
    --modules="$ISO_GRUB_MODULES" \
    "boot/grub/grub.cfg=$iso_cfg"; then
    blog_err "grub-mkstandalone failed; the iso/ tree and build.log are kept for diagnosis"
    return 6
  fi
  if [ ! -s "$grub_efi" ]; then
    blog_err "grub-mkstandalone reported success but $grub_efi is missing or empty"
    return 6
  fi

  if ! run_logged mkfs.vfat -C -n EFI "$iso_efi" "$ISO_EFI_IMG_KB"; then
    blog_err "mkfs.vfat failed to create the live efi.img"
    return 6
  fi
  if ! run_logged mcopy -i "$iso_efi" -s "$iso_esp/EFI" "::/"; then
    blog_err "mcopy failed to populate the live efi.img"
    return 6
  fi
  if [ ! -s "$iso_efi" ]; then
    blog_err "mkfs.vfat reported success but $iso_efi is missing"
    return 6
  fi
  if ! cp "$iso_efi" "$iso_boot/efi.img"; then
    blog_err "cannot stage the EFI boot image at $iso_boot/efi.img"
    return 6
  fi

  if ! run_logged xorriso -as mkisofs -R -J -joliet-long -V "$ISO_LABEL" \
    -o "$iso_out" -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
    -isohybrid-gpt-basdat "$iso_dir"; then
    blog_err "xorriso failed; the iso/ tree and build.log are kept for diagnosis"
    return 6
  fi
  if [ ! -s "$iso_out" ]; then
    blog_err "xorriso reported success but $iso_out is missing or empty"
    return 6
  fi

  # efi.img is an intermediate copied into the ISO tree; the workplan's
  # diagnostic tree only keeps iso/boot/grub/efi.img.
  if ! rm -f "$iso_efi"; then
    blog "[build] warning: could not remove the intermediate EFI image: $iso_efi"
  fi
  blog "[build] iso: $iso_out, live tree staged under $iso_dir"
  return 0
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
  local iso_dir="$OUT_ABS/$ISO_DIR_NAME"
  local iso_staging="$OUT_ABS/iso-staging"
  local iso_efi="$OUT_ABS/$ISO_EFI_IMG_NAME"
  local iso_cfg=""
  local iso_esp=""
  local pkg_csv=""
  local hostname=""
  local hook=""
  local kernel=""
  local initrd=""
  local kernel_name=""
  local initrd_name=""
  local graphical=0
  local desktop_dm=""
  local desktop_session=""
  local include_csv=""
  local runtime_csv=""
  local runtime_count=0
  local rootfs_mb=0
  local disk_mb=0
  local root_part_mb=0
  local root_fs_blocks=0
  local esp_bytes=0
  local mode=""
  local iso=0
  local disk=0
  local stale=0
  local artifact_fail=0

  # P0-d2: choose the requested stages from plan.target.outputs. An ISO-only
  # plan must never touch sgdisk/mkfs.ext4/qemu-img/dd; a disk plan keeps the
  # frozen P0-c/P0-d1 pipeline.
  mode=$(plan_build_mode)
  case "$mode" in
    iso)
      iso=1
      ;;
    iso-disk)
      iso=1
      disk=1
      ;;
    *)
      disk=1
      ;;
  esac
  if [ "$disk" -eq 1 ]; then
    DISK_OUTPUTS_OWNED=1
  fi
  if [ "$iso" -eq 1 ]; then
    ISO_OUTPUTS_OWNED=1
  fi
  if [ "$iso" -eq 1 ] && [ "$disk" -eq 1 ]; then
    iso_cfg="$iso_staging/grub.cfg"
    iso_esp="$iso_staging/esp"
  else
    iso_cfg="$grub_cfg"
    iso_esp="$esp_dir"
  fi

  # P0-a rule: never overwrite an existing rootfs. Output images requested by
  # this plan are refused too, so a stale image can never be paired with a
  # fresh rootfs.
  if [ -e "$rootfs" ] || [ -L "$rootfs" ]; then
    blog_err "refusing to overwrite existing path: $rootfs"
    return 6
  fi
  if [ "$disk" -eq 1 ]; then
    if [ -e "$raw" ] || [ -L "$raw" ]; then
      blog_err "refusing to overwrite existing image: $raw"
      return 6
    fi
    if [ -e "$qcow" ] || [ -L "$qcow" ]; then
      blog_err "refusing to overwrite existing image: $qcow"
      return 6
    fi
  fi
  if [ "$iso" -eq 1 ]; then
    if [ -e "$OUT_ABS/$ISO_ARTIFACT_NAME" ] || [ -L "$OUT_ABS/$ISO_ARTIFACT_NAME" ]; then
      blog_err "refusing to overwrite existing image: $OUT_ABS/$ISO_ARTIFACT_NAME"
      return 6
    fi
  fi

  pkg_csv=$(make_pkg_csv)
  if [ -z "$pkg_csv" ]; then
    blog_err "package list is empty; refusing to build"
    return 6
  fi

  # P0-d1: infer the desktop from plan.packages (the plan contract is frozen).
  # The same pure helpers run again inside the artifact helpers, so build.log,
  # grub.cfg, and artifact.json always agree.
  if desktop_dm=$(detect_display_manager "${PLAN_PACKAGES_VALUES[@]}"); then
    desktop_session=$(detect_desktop_session "${PLAN_PACKAGES_VALUES[@]}")
    graphical=1
  else
    desktop_dm=""
    desktop_session=""
    graphical=0
  fi

  # P0-d3 is a headless installer: even if the plan names a display manager,
  # the installer ISO boots to multi-user and the artifact stays 1024 MB /
  # non-graphical. The DM packages remain in the rootfs if the plan asked for
  # them; only the boot target, desktop runtime packages, and boot-evidence
  # unit are suppressed.
  if [ "$INSTALLER" -eq 1 ] && [ "$graphical" -eq 1 ]; then
    blog "[build] installer: forcing headless multi-user boot (plan display manager '$desktop_dm' is not started)"
    graphical=0
    desktop_dm=""
    desktop_session=""
  fi

  # Builder-added runtime packages, deduplicated against the plan:
  #   - desktop: xserver-xorg/procps/accountsservice (P0-d1, unchanged);
  #   - live ISO: live-boot/live-boot-initramfs-tools (mmdebstrap installs no
  #     Recommends, so the plan alone does not pull them in);
  #   - installer: rsync/grub-efi-amd64(+bin)/dosfstools/gdisk/e2fsprogs
  #     (P0-d3; the guest runs sgdisk/mkfs/rsync/grub-mkstandalone).
  # artifact.packages stays the plan package list.
  runtime_csv=$(runtime_packages_for "$iso" "$graphical" "$INSTALLER")
  runtime_count=$(runtime_package_count_for "$iso" "$graphical" "$INSTALLER")
  include_csv=$pkg_csv
  if [ -n "$runtime_csv" ]; then
    include_csv="$pkg_csv,$runtime_csv"
  fi

  if [ "$INSTALLER" -eq 1 ]; then
    if [ ! -f "$INSTALLER_SCRIPT_SRC" ] || [ ! -r "$INSTALLER_SCRIPT_SRC" ] ||
      [ ! -s "$INSTALLER_SCRIPT_SRC" ]; then
      blog_err "installer script is missing or empty: $INSTALLER_SCRIPT_SRC"
      return 6
    fi
    if [ ! -f "$INSTALLER_UNIT_SRC" ] || [ ! -r "$INSTALLER_UNIT_SRC" ] ||
      [ ! -s "$INSTALLER_UNIT_SRC" ]; then
      blog_err "installer unit is missing or empty: $INSTALLER_UNIT_SRC"
      return 6
    fi
  fi

  hostname=$(plan_hostname)
  if ! hook=$(make_customize_hook "$hostname" "$desktop_dm" "$iso" "$INSTALLER" "$INSTALLER_TUI"); then
    blog_err "cannot build the mmdebstrap customize hook for display_manager='$desktop_dm'"
    return 6
  fi

  # esp/, esp.img, grub.cfg, efi.img, and iso/ are derived staging outputs.
  # They can only survive a previous interrupted/failed attempt here, because
  # rootfs/ and the final images above are refused when they already exist.
  if [ "$disk" -eq 1 ] &&
    { [ -e "$esp_dir" ] || [ -L "$esp_dir" ] ||
      [ -e "$esp_img" ] || [ -L "$esp_img" ] ||
      [ -e "$grub_cfg" ] || [ -L "$grub_cfg" ]; }; then
    blog "[build] removing stale P0-c staging outputs from a previous attempt"
    if ! rm -rf "$esp_dir" "$esp_img" "$grub_cfg"; then
      blog_err "cannot remove stale staging outputs under $OUT_ABS"
      return 6
    fi
    stale=1
  fi
  if [ "$iso" -eq 1 ] &&
    { [ -e "$iso_dir" ] || [ -L "$iso_dir" ] ||
      [ -e "$iso_efi" ] || [ -L "$iso_efi" ] ||
      [ -e "$iso_staging" ] || [ -L "$iso_staging" ] ||
      { [ "$disk" -eq 0 ] && { [ -e "$esp_dir" ] || [ -L "$esp_dir" ] || [ -e "$grub_cfg" ] || [ -L "$grub_cfg" ]; }; }; }; then
    if [ "$stale" -eq 0 ]; then
      blog "[build] removing stale live ISO staging outputs from a previous attempt"
    fi
    if ! rm -rf "$iso_dir" "$iso_efi" "$iso_staging" "$OUT_ABS/.iso-grub.cfg.tmp"; then
      blog_err "cannot remove stale ISO staging outputs under $OUT_ABS"
      return 6
    fi
    if [ "$disk" -eq 0 ]; then
      if ! rm -rf "$esp_dir" "$grub_cfg"; then
        blog_err "cannot remove stale ISO staging outputs under $OUT_ABS"
        return 6
      fi
    fi
  fi
  rm -f "$OUT_ABS/.grub.cfg.tmp" "$OUT_ABS/.artifact.json.tmp" 2>/dev/null || true

  # From here on, derived outputs belong to this build and the EXIT trap may
  # remove the ESP image, a partial qcow2/live.iso, efi.img, and temp manifests.
  OUTPUTS_OWNED=1

  blog "[build] stage 1/6: validate - plan is valid"
  blog "[build] stage 2/6: fetch base - $PLAN_BASE_KIND_VALUE/$PLAN_BASE_RELEASE_VALUE"
  blog "[build] stage 3/6: bootstrap rootfs - $rootfs"
  if [ "$iso" -eq 1 ]; then
    blog "[build] stage 4/6: install packages - $PKG_COUNT plan + $runtime_count runtime packages via --include"
  elif [ "$graphical" -eq 1 ]; then
    blog "[build] stage 4/6: install packages - $PKG_COUNT plan + $runtime_count desktop runtime packages via --include"
  else
    blog "[build] stage 4/6: install packages - $PKG_COUNT packages via --include"
  fi
  if [ "$graphical" -eq 1 ]; then
    blog "[build] desktop: session=$desktop_session, display_manager=$desktop_dm (graphical boot, ${ARTIFACT_BOOT_MEMORY_MB_GRAPHICAL} MB)"
    blog "[build] desktop runtime: add ${GRAPHICAL_RUNTIME_PACKAGES[*]} to --include (Xorg + pgrep + Accounts)"
    blog "[build] boot evidence: install /etc/systemd/system/sysemble-boot-evidence.service (enabled for graphical.target)"
  else
    blog "[build] desktop: none detected (multi-user boot, ${ARTIFACT_BOOT_MEMORY_MB_DEFAULT} MB)"
  fi
  if [ "$iso" -eq 1 ]; then
    blog "[build] live ISO runtime: add ${runtime_csv:-none} to --include (deduplicated against plan.packages)"
    blog "[build] live ISO: regenerate the initramfs in the customize hook so the live-boot hook is included"
  fi
  if [ "$INSTALLER" -eq 1 ]; then
    if [ "$INSTALLER_TUI" -eq 1 ]; then
      blog "[build] installer: ISO-only TUI wizard, no preselected disk (memory ${ISO_BOOT_MEMORY_MB_DEFAULT} MB)"
      blog "[build] installer cmdline: $INSTALLER_TUI_MARKER"
    else
      blog "[build] installer: ISO-only unattended install to $INSTALLER_DEVICE_DEFAULT (memory ${ISO_BOOT_MEMORY_MB_DEFAULT} MB)"
      blog "[build] installer cmdline: $INSTALLER_KERNEL_PARAM=$INSTALLER_DEVICE_DEFAULT"
    fi
    blog "[build] installer hook: $INSTALLER_SCRIPT_INSTALL_PATH (0755), $INSTALLER_UNIT_INSTALL_PATH, multi-user.target.wants link"
    if [ "$INSTALLER_TUI" -eq 1 ]; then
      blog "[build] installer unit drop-in: $INSTALLER_UNIT_NAME.d/tui-cmdline.conf (sysemble.install OR sysemble.install.tui)"
    fi
  fi
  blog "[build] customize: hostname=$hostname, enable serial-getty@ttyS0.service (failure is non-fatal)"

  export DEBIAN_FRONTEND=noninteractive
  if ! run_logged mmdebstrap --variant=minbase --include="$include_csv" \
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
  if [ "$disk" -eq 1 ]; then
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
  if ! grub_cfg_text "$kernel_name" "$initrd_name" "$graphical" \
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

  fi

  if [ "$iso" -eq 1 ]; then
    if ! build_iso_image "$rootfs" "$kernel" "$initrd" "$graphical" \
      "$iso_cfg" "$iso_esp" "$iso_efi" "$iso_dir" "$INSTALLER" "$INSTALLER_TUI"; then
      return 6
    fi
  fi

  blog "[build] stage 6/6: write artifact manifest"
  artifact_fail=0
  if [ "$iso" -eq 1 ]; then
    if [ "$INSTALLER" -eq 1 ]; then
      if [ "$INSTALLER_TUI" -eq 1 ]; then
        if ! artifact_install_tui_json "$OUT_ABS" "$PLAN_SPEC_VALUE" \
          "$PLAN_BASE_RELEASE_VALUE" "$PLAN_BASE_PIN_VALUE" \
          "$PLAN_TARGET_ARCH_VALUE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          "${PLAN_PACKAGES_VALUES[@]}" >"$OUT_ABS/.artifact.json.tmp" 2>"$TMP_DIR/artifact.err"; then
          artifact_fail=1
        fi
      elif ! artifact_install_json "$OUT_ABS" "$PLAN_SPEC_VALUE" \
        "$PLAN_BASE_RELEASE_VALUE" "$PLAN_BASE_PIN_VALUE" \
        "$PLAN_TARGET_ARCH_VALUE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${PLAN_PACKAGES_VALUES[@]}" >"$OUT_ABS/.artifact.json.tmp" 2>"$TMP_DIR/artifact.err"; then
        artifact_fail=1
      fi
    elif ! artifact_iso_json "$OUT_ABS" "$PLAN_SPEC_VALUE" \
      "$PLAN_BASE_RELEASE_VALUE" "$PLAN_BASE_PIN_VALUE" \
      "$PLAN_TARGET_ARCH_VALUE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$disk" "${PLAN_PACKAGES_VALUES[@]}" >"$OUT_ABS/.artifact.json.tmp" 2>"$TMP_DIR/artifact.err"; then
      artifact_fail=1
    fi
  elif ! artifact_json "$OUT_ABS" "$PLAN_SPEC_VALUE" \
    "$PLAN_BASE_RELEASE_VALUE" "$PLAN_BASE_PIN_VALUE" \
    "$PLAN_TARGET_ARCH_VALUE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${PLAN_PACKAGES_VALUES[@]}" >"$OUT_ABS/.artifact.json.tmp" 2>"$TMP_DIR/artifact.err"; then
    artifact_fail=1
  fi
  if [ "$artifact_fail" -eq 1 ]; then
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
  if [ "$iso" -eq 1 ] && [ "$disk" -eq 1 ]; then
    blog "[build] complete (mode: uefi+iso)"
  elif [ "$iso" -eq 1 ] && [ "$INSTALLER" -eq 1 ]; then
    blog "[build] complete (mode: install)"
  elif [ "$iso" -eq 1 ]; then
    blog "[build] complete (mode: iso)"
  else
    blog "[build] complete (mode: uefi)"
  fi
  blog "  rootfs:   $rootfs"
  if [ "$disk" -eq 1 ]; then
    blog "  raw:      $raw (${disk_mb} MB: GPT, p1 esp ${ESP_SIZE_MB} MB, p2 root ${root_part_mb} MB)"
    blog "  qcow2:    $qcow"
    blog "  grub:     $grub_efi (config: $grub_cfg)"
  fi
  if [ "$iso" -eq 1 ]; then
    blog "  iso:      $OUT_ABS/$ISO_ARTIFACT_NAME (UEFI El Torito)"
    blog "  iso tree: $iso_dir (live/vmlinuz, live/initrd.img, live/filesystem.squashfs, boot/grub/efi.img)"
    blog "  iso cfg:  $iso_cfg"
  fi
  if [ "$INSTALLER" -eq 1 ]; then
    if [ "$INSTALLER_TUI" -eq 1 ]; then
      blog "  installer: $INSTALLER_SCRIPT_INSTALL_PATH + $INSTALLER_UNIT_INSTALL_PATH (TUI wizard, no preselected disk)"
    else
      blog "  installer: $INSTALLER_SCRIPT_INSTALL_PATH + $INSTALLER_UNIT_INSTALL_PATH (install_device $INSTALLER_DEVICE_DEFAULT)"
    fi
  fi
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
  local mode=""
  local iso=0
  local graphical=0
  local runtime_csv=""

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

  # Match the native rootfs content when the plan asks for an ISO or a desktop:
  # docker mode still stops after the rootfs, but the packages it installs
  # should be the same ones the native pipeline would use.
  mode=$(plan_build_mode)
  case "$mode" in
    iso | iso-disk) iso=1 ;;
  esac
  if detect_display_manager "${PLAN_PACKAGES_VALUES[@]}" >/dev/null 2>&1; then
    graphical=1
  fi
  if [ "$INSTALLER" -eq 1 ]; then
    graphical=0
  fi
  runtime_csv=$(runtime_packages_for "$iso" "$graphical" "$INSTALLER")
  if [ -n "$runtime_csv" ]; then
    pkg_csv="$pkg_csv,$runtime_csv"
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
  validate_installer_mode || exit 2

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
