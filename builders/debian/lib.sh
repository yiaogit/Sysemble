#!/usr/bin/env bash
# Sysemble Debian builder - shared helpers for build.sh
# (P0-a + P0-b + P0-c + P0-d1 + P0-d2).
#
# This file is sourced by build.sh. It is written for bash 3.2 (the /bin/bash
# shipped by macOS) and must not use bash 4 features (mapfile, nameref, ...).
#
# It owns:
#   - JSON access (jq preferred, python3 fallback) and the record protocol
#   - plan validation
#   - engine preflight checks (native / docker)
#   - disk sizing, GRUB config rendering, and artifact.json generation helpers
#     (P0-b kernel mode + P0-c GPT/GRUB/UEFI extensions)
#   - P0-d1 desktop inference from plan.packages (display manager -> graphical
#     boot, memory, cmdline, and the artifact desktop object)
#   - P0-d2 live ISO mode selection, live GRUB rendering, runtime-package
#     deduplication, and the boot.mode="iso" artifact helper
#   - output helpers / usage text
#
# It is safe to source this file without running a build: it only defines
# functions and constants. In particular the artifact helpers are pure
# functions so builders/debian/tests/ can call them against fixtures.

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------

API_VERSION="sysemble/plan/v1"

EXIT_PLAN=1
EXIT_USAGE=2
EXIT_NATIVE=3
EXIT_DOCKER=4
EXIT_JSON=5
EXIT_BUILD=6

# ---------------------------------------------------------------------------
# P0-c disk layout (frozen by docs/plan/P0-c-workplan.md §2)
#
#   disk.img (GPT)
#     p1  1 MiB   +512 MiB  ESP   vfat32  label ESP
#     p2  513 MiB  rest      root  ext4    label SYMBLE
#
# The build is loop-free: the ext4 filesystem is written into disk.img at a
# byte offset, the FAT32 file system is built in a separate esp.img and then
# merged with dd. These constants are shared by build.sh and the tests.
# ---------------------------------------------------------------------------

DISK_MIN_MB=4096
ESP_SIZE_MB=512
# p2 starts one 1 MiB alignment gap after the end of the 512 MiB ESP.
ROOT_START_MB=513
ROOT_OFFSET_BYTES=$((ROOT_START_MB * 1024 * 1024))
# mkfs.vfat size argument is in 1 KiB blocks.
ESP_IMAGE_KB=$((ESP_SIZE_MB * 1024))
GRUB_EFI_REL="esp/EFI/BOOT/BOOTX64.EFI"
GRUB_CONFIG_REL="grub.cfg"
GRUB_MENU_TITLE="Sysemble"
GRUB_MODULES="part_gpt part_msdos fat ext2 normal linux search search_fs_uuid configfile serial terminal echo test"

# ---------------------------------------------------------------------------
# P0-d2 live ISO layout (frozen by docs/plan/P0-d2-workplan.md §2/§3)
#
#   <out>/live.iso
#   <out>/iso/live/vmlinuz
#   <out>/iso/live/initrd.img
#   <out>/iso/live/filesystem.squashfs
#   <out>/iso/boot/grub/efi.img
#
# The EFI system image is an 8 MiB FAT filesystem holding
# EFI/BOOT/BOOTX64.EFI (grub-mkstandalone with the embedded live grub.cfg).
# xorriso puts it in the ISO tree at boot/grub/efi.img and registers it as the
# El Torito EFI boot image. The ISO is UEFI-only; BIOS boot is out of scope.
# ---------------------------------------------------------------------------

ISO_ARTIFACT_NAME="live.iso"
ISO_DIR_NAME="iso"
ISO_LABEL="SYMBLE"
ISO_EFI_IMG_NAME="efi.img"
# mkfs.vfat size argument is in 1 KiB blocks: 8192 KiB = 8 MiB.
ISO_EFI_IMG_KB=8192
ISO_GRUB_MENU_TITLE="Sysemble Live"
# Frozen module list. iso9660 and search_fs_file are required to locate
# /live/vmlinuz on the ISO; part_gpt/part_msdos/fat keep the standalone binary
# usable on other media without rebuilding it.
ISO_GRUB_MODULES="part_gpt part_msdos fat iso9660 normal linux search search_fs_file configfile serial terminal echo test"
ISO_BOOT_CMDLINE="boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1"
ISO_BOOT_CMDLINE_GRAPHICAL="boot=live live-media-path=/live console=ttyS0 systemd.unit=graphical.target systemd.journald.forward_to_console=1"
ISO_BOOT_MEMORY_MB_DEFAULT=1024
ISO_BOOT_MEMORY_MB_GRAPHICAL=2048
# Builder-added runtime packages for a live ISO. mmdebstrap installs no
# Recommends, so a plain plan does not pull them in. artifact.packages keeps
# the plan list; these only reach mmdebstrap --include.
ISO_RUNTIME_PACKAGES=(live-boot live-boot-initramfs-tools)

# ---------------------------------------------------------------------------
# P0-d3 unattended installer (frozen by docs/plan/P0-d3-workplan.md §2)
#
# `build.sh --installer` is valid only for an ISO-only plan. The live rootfs
# gets the installer script/unit baked in by the customize hook, the ISO GRUB
# cmdline gains sysemble.install=<device>, and the artifact records
# boot.mode="install" + boot.install_device. The installer itself partitions
# the guest's /dev/vda; no disk is built by build.sh in this mode.
# ---------------------------------------------------------------------------

INSTALLER_DIR_NAME="installer"
INSTALLER_SCRIPT_NAME="sysemble-install.sh"
INSTALLER_UNIT_NAME="sysemble-install.service"
INSTALLER_SCRIPT_INSTALL_PATH="/usr/local/sbin/sysemble-install"
INSTALLER_UNIT_INSTALL_PATH="/etc/systemd/system/sysemble-install.service"
INSTALLER_WANTS_LINK_PATH="/etc/systemd/system/multi-user.target.wants/sysemble-install.service"
INSTALLER_DEVICE_DEFAULT="/dev/vda"
INSTALLER_KERNEL_PARAM="sysemble.install"
# P0-e1: the TUI ISO does not pre-select a disk. Its cmdline marker makes the
# same installer script start the serial wizard; the artifact records
# boot.install_tui=true and no install_device.
INSTALLER_TUI_KERNEL_PARAM="sysemble.install.tui"
INSTALLER_TUI_MARKER="sysemble.install.tui=1"
# Packages the installer needs inside the live rootfs (and therefore inside the
# installed system after rsync): rsync for the copy, grub-efi-amd64(+bin) for
# the self-contained grub-mkstandalone EFI binary (grub-common, which provides
# the tool, is pulled in as a dependency), dosfstools for mkfs.vfat, gdisk for
# sgdisk, e2fsprogs for mkfs.ext4/blkid. Deduplicated against plan.packages.
INSTALLER_RUNTIME_PACKAGES=(rsync grub-efi-amd64 grub-efi-amd64-bin dosfstools gdisk e2fsprogs)

# docker info is given this long before it is treated as unavailable, so the
# script never hangs on a wedged daemon.
DOCKER_INFO_TIMEOUT=20

JSON_BACKEND=""
TMP_DIR=""
OUT_ABS=""

# ---------------------------------------------------------------------------
# Plan records (filled by parse_plan_records / validate_plan)
# ---------------------------------------------------------------------------

PLAN_API_VERSION_TYPE="missing"
PLAN_API_VERSION_VALUE=""
PLAN_SPEC_TYPE="missing"
PLAN_SPEC_VALUE=""
PLAN_BASE_KIND_TYPE="missing"
PLAN_BASE_KIND_VALUE=""
PLAN_BASE_RELEASE_TYPE="missing"
PLAN_BASE_RELEASE_VALUE=""
PLAN_BASE_PIN_TYPE="missing"
PLAN_BASE_PIN_VALUE=""
PLAN_TARGET_ARCH_TYPE="missing"
PLAN_TARGET_ARCH_VALUE=""

PLAN_OUTPUTS_TYPE="missing"
PLAN_OUTPUTS_VALUES=()
PLAN_OUTPUTS_ELEM_TYPES=()

PLAN_PACKAGES_TYPE="missing"
PLAN_PACKAGES_VALUES=()
PLAN_PACKAGES_ELEM_TYPES=()

PLAN_MODULES_TYPE="missing"
PLAN_MODULES_VALUES=()

PLAN_EST_IMAGE_MB_TYPE="missing"
PLAN_EST_IMAGE_MB_VALUE=""
PLAN_EST_BUILD_MINUTES_TYPE="missing"
PLAN_EST_BUILD_MINUTES_VALUE=""
PLAN_EST_DISK_MB_TYPE="missing"
PLAN_EST_DISK_MB_VALUE=""

PLAN_WARNINGS_TYPE="missing"
PLAN_WARNINGS_VALUES=()

PLAN_ERRORS=0
PKG_COUNT=0
OUTPUTS_TEXT=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

info() {
  printf '%s\n' "$*"
}

warn() {
  printf 'build.sh: warning: %s\n' "$*" >&2
}

err() {
  printf 'build.sh: error: %s\n' "$*" >&2
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

IFS= read -r -d '' USAGE_TEXT <<'USAGE' || true
Sysemble Debian builder (P0-d3) - build bootable Debian disk images, live ISOs, and installer ISOs from plan.json

Usage:
  builders/debian/build.sh --plan <plan.json> --out <dir> [--dry-run] [--execute]
                           [--engine docker|native] [--installer | --installer-tui]

Options:
  --plan <path>      plan.json produced by `sysemble plan --json`
  --out <dir>        output directory; created if missing
  --dry-run          validate the plan, print stages/packages/estimates, and
                     write only <out>/plan.copy.json
  --execute          explicit alias for the default build mode: build the
                     rootfs plus the outputs requested by plan.target.outputs
                     (live ISO and/or GPT disk images) and artifact.json.
                     Mutually exclusive with --dry-run. The CI contract passes
                     this flag.
  --engine <name>    native (default) or docker
  --installer        P0-d3: build an unattended installer ISO. Requires an
                     ISO-only plan (target.outputs contains "iso" and no
                     qcow2/raw; anything else exits 2). The live rootfs gets
                     /usr/local/sbin/sysemble-install plus its systemd unit,
                     the ISO cmdline gains sysemble.install=/dev/vda, the
                     --include list adds the installer packages, and the
                     artifact uses boot.mode="install" with install_device.
  --installer-tui    P0-e1: build a TUI installer ISO (ISO-only plans only).
                     Uses the same installer script, unit, and packages as
                     --installer, but the ISO cmdline is
                     sysemble.install.tui=1 and the artifact records
                     boot.mode="install", boot.install_tui=true, and no
                     install_device. Mutually exclusive with --installer.
  -h, --help         show this help and exit 0

Outputs (native --execute), selected by plan.target.outputs:
  <out>/rootfs/        mmdebstrap rootfs
  <out>/live.iso       UEFI El Torito live ISO (when outputs contains "iso")
  <out>/iso/           ISO tree: live/{vmlinuz,initrd.img,filesystem.squashfs},
                       boot/grub/efi.img (kept for diagnosis)
  <out>/esp/           ESP staging tree (EFI/BOOT/BOOTX64.EFI and, for a disk
                       build, boot/grub/grub.cfg)
  <out>/grub.cfg       disk GRUB config, or the live ISO config in iso-only mode
  <out>/disk.img       raw GPT image: p1 ESP (vfat32) + p2 root (ext4)
  <out>/disk.qcow2     qcow2 conversion of disk.img
  <out>/artifact.json  sysemble/artifact/v1 manifest (boot.mode = "iso",
                       "install", or "uefi")
  <out>/build.log      full build output (tee)

  Disk mode builds disk.img/disk.qcow2. ISO-only mode skips the disk pipeline
  entirely: it runs mksquashfs, grub-mkstandalone, mkfs.vfat, mcopy and xorriso.
  An iso+disk plan builds both. <out>/esp.img and <out>/efi.img are temporary
  FAT images and are removed on success.

Engines:
  native   requires Linux, euid 0, and mmdebstrap, mkfs.vfat, mcopy, and
           grub-mkstandalone on PATH. A disk build also requires mkfs.ext4,
           qemu-img, sgdisk, and dd. A live ISO build also requires mksquashfs
           and xorriso. ISO-only plans do not require the disk-only tools.
  docker   runs mmdebstrap in a debian:trixie container with <out> mounted at
           /out; requires a working Docker daemon. Docker mode still stops after
           the rootfs: disk/ISO assembly and artifact.json are native-only and
           have not been verified in docker mode, so --execute with
           --engine docker is rejected (exit 2). --dry-run does not check the
           engine, so it works on hosts without Linux/Docker.

Exit codes:
  0  success (dry run, or a complete native image build)
  1  invalid plan (malformed JSON or failed plan validation), or plan.spec is
     missing for a real native build (artifact.json requires it)
  2  usage or I/O error (including an unsafe --out)
  3  native engine unavailable (not Linux, not root, or a tool required by the
     requested outputs is missing)
  4  docker engine unavailable (no docker CLI or no daemon)
  5  no JSON parser available (install jq or python3)
  6  a build step failed, <out>/rootfs or an output image already exists, or
     the rootfs has no bootable kernel/initrd

P0-d2 scope: target.outputs containing "iso" builds a UEFI-only live ISO with
live-boot/live-media-path; when no qcow2/raw output is requested the disk pipeline is
skipped and the manifest omits partitions. The ISO rootfs additionally gets
live-boot and live-boot-initramfs-tools via --include (artifact.packages keeps
the plan package list). A plan whose packages include gdm3/sddm/lightdm still
gets the P0-d1 desktop inference and 2048 MB. The Calamares GUI installer,
secure boot, BIOS boot, persistence, and cross-architecture builds are out of
scope. An artifact without boot.mode still means the P0-b direct-kernel mode.

P0-d3 scope: --installer (ISO-only plans) bakes the headless
/usr/local/sbin/sysemble-install + sysemble-install.service into the live
rootfs, adds rsync/grub-efi-amd64/grub-efi-amd64-bin/dosfstools/gdisk/e2fsprogs
to --include, appends sysemble.install=/dev/vda to the ISO cmdline, and emits
boot.mode="install" / boot.install_device="/dev/vda" (images stays live.iso).
P0-e1 adds --installer-tui: the same script/unit/packages, an ISO cmdline with
sysemble.install.tui=1 (no install_device), and boot.install_tui=true in the
artifact. The installer wizard is serial/stdio only; the Calamares GUI
installer remains out of scope (P0-e2).
USAGE

usage() {
  printf '%s' "$USAGE_TEXT"
}

# ---------------------------------------------------------------------------
# JSON extraction
#
# Both backends emit the same tab-separated record stream consumed by
# parse_plan_records:
#
#   <key>\t<type>\t<value>\n
#
# Scalar keys appear once. Array keys appear as "<key>\tarray\t" followed by
# one "<key>.elem\t<type>\t<value>" line per element. Values are sanitized
# (control characters replaced with spaces) so a plan cannot break the record
# format. The shell only consumes well-formed records; nothing is evaluated.
# ---------------------------------------------------------------------------

IFS= read -r -d '' JQ_EXTRACT <<'JQ' || true
(if type != "object" then error("plan must be a JSON object") else . end) as $root |
def has_path($p):
  if ($p | length) == 0 then true
  else
    ($p[0]) as $head |
    if (type == "object") and (has($head)) then (.[$head] | has_path($p[1:]))
    else false end
  end;
def clean: tostring | gsub("[\u0000-\u001f\u007f]"; " ");
def kind:
  if . == null then "null"
  elif type == "boolean" then "boolean"
  elif type == "number" then "number"
  elif type == "string" then "string"
  elif type == "array" then "array"
  elif type == "object" then "object"
  else "unknown" end;
def scalar($k; $p):
  if ($root | has_path($p)) then
    ($root | getpath($p)) as $v |
    "\($k)\t\($v|kind)\t\($v|clean)"
  else "\($k)\tmissing\t" end;
def list_of($k; $p; f):
  if ($root | has_path($p)) then
    ($root | getpath($p)) as $v |
    if ($v|type) == "array" then
      "\($k)\tarray\t",
      ($v[] | "\($k).elem\t\(kind)\t\(f|clean)")
    else "\($k)\t\($v|kind)\t\($v|clean)" end
  else "\($k)\tmissing\t" end;
scalar("apiVersion"; ["apiVersion"]),
scalar("spec"; ["spec"]),
scalar("base.kind"; ["base", "kind"]),
scalar("base.release"; ["base", "release"]),
scalar("base.pin"; ["base", "pin"]),
scalar("target.arch"; ["target", "arch"]),
list_of("target.outputs"; ["target", "outputs"]; .),
list_of("packages"; ["packages"]; .),
list_of("modules"; ["modules"]; if type == "object" then (((if (has("id") and (.id != null)) then (.id|tostring) else "?" end)) + "@" + ((if (has("version") and (.version != null)) then (.version|tostring) else "?" end))) else . end),
scalar("estimates.image_mb"; ["estimates", "image_mb"]),
scalar("estimates.build_minutes"; ["estimates", "build_minutes"]),
scalar("estimates.disk_mb"; ["estimates", "disk_mb"]),
list_of("warnings"; ["warnings"]; if type == "object" then (((if (has("code") and (.code != null)) then (.code|tostring) else "?" end)) + ": " + ((if (has("message") and (.message != null)) then (.message|tostring) else "" end))) else . end)
JQ

IFS= read -r -d '' PY_EXTRACT <<'PY' || true
import json
import sys

MISSING = object()


def reject_constant(value):
    raise ValueError("invalid JSON constant: %s" % value)


def main(argv):
    path = argv[1]
    try:
        with open(path, "r", encoding="utf-8") as fh:
            root = json.load(fh, parse_constant=reject_constant)
    except OSError as exc:
        sys.stderr.write("cannot read plan: %s\n" % exc)
        return 3
    except ValueError as exc:
        sys.stderr.write("invalid JSON: %s\n" % exc)
        return 3
    if not isinstance(root, dict):
        sys.stderr.write("plan must be a JSON object\n")
        return 3

    def get(keys):
        cur = root
        for key in keys:
            if not isinstance(cur, dict) or key not in cur:
                return MISSING
            cur = cur[key]
        return cur

    def kind(value):
        if value is MISSING:
            return "missing"
        if value is None:
            return "null"
        if isinstance(value, bool):
            return "boolean"
        if isinstance(value, (int, float)):
            return "number"
        if isinstance(value, str):
            return "string"
        if isinstance(value, list):
            return "array"
        if isinstance(value, dict):
            return "object"
        return "unknown"

    def fmt(value):
        if value is MISSING:
            return ""
        if isinstance(value, str):
            return value
        if isinstance(value, bool):
            return "true" if value else "false"
        if isinstance(value, (int, float)):
            return str(value)
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

    def clean(value):
        return "".join(
            " " if (ord(ch) < 32 or ord(ch) == 127) else ch for ch in value
        )

    def emit(key, value_kind, value):
        sys.stdout.write("%s\t%s\t%s\n" % (key, value_kind, clean(value)))

    def scalar(key, keys):
        value = get(keys)
        emit(key, kind(value), fmt(value))

    def list_of(key, keys, formatter):
        value = get(keys)
        value_kind = kind(value)
        if value_kind == "array":
            emit(key, "array", "")
            for element in value:
                emit(key + ".elem", kind(element), formatter(element))
        else:
            emit(key, value_kind, fmt(value))

    def module_fmt(value):
        if isinstance(value, dict):
            module_id = value.get("id", "?")
            version = value.get("version", "?")
            if module_id is None:
                module_id = "?"
            if version is None:
                version = "?"
            return "%s@%s" % (fmt(module_id), fmt(version))
        return fmt(value)

    def warning_fmt(value):
        if isinstance(value, dict):
            code = value.get("code", "?")
            message = value.get("message", "")
            if code is None:
                code = "?"
            if message is None:
                message = ""
            return "%s: %s" % (fmt(code), fmt(message))
        return fmt(value)

    scalar("apiVersion", ["apiVersion"])
    scalar("spec", ["spec"])
    scalar("base.kind", ["base", "kind"])
    scalar("base.release", ["base", "release"])
    scalar("base.pin", ["base", "pin"])
    scalar("target.arch", ["target", "arch"])
    list_of("target.outputs", ["target", "outputs"], fmt)
    list_of("packages", ["packages"], fmt)
    list_of("modules", ["modules"], module_fmt)
    scalar("estimates.image_mb", ["estimates", "image_mb"])
    scalar("estimates.build_minutes", ["estimates", "build_minutes"])
    scalar("estimates.disk_mb", ["estimates", "disk_mb"])
    list_of("warnings", ["warnings"], warning_fmt)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

detect_json_backend() {
  if command -v jq >/dev/null 2>&1; then
    JSON_BACKEND="jq"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    JSON_BACKEND="python3"
    return 0
  fi
  err "no JSON parser available: install jq or python3 (neither was found on PATH)"
  return 5
}

json_extract_jq() {
  jq -r "$JQ_EXTRACT" "$1"
}

json_extract_python() {
  PYTHONIOENCODING=utf-8 python3 -c "$PY_EXTRACT" "$1"
}

# ---------------------------------------------------------------------------
# Temporary directory / cleanup
# ---------------------------------------------------------------------------

make_tmpdir() {
  local base
  base=${TMPDIR:-/tmp}
  while [ "${base%/}" != "$base" ] && [ "$base" != "/" ]; do
    base=${base%/}
  done
  TMP_DIR=$(mktemp -d "$base/sysemble-build.XXXXXX") || {
    err "cannot create a temporary directory under '$base'"
    return 2
  }
  trap cleanup_tmp EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  return 0
}

cleanup_tmp() {
  if [ -n "${TMP_DIR:-}" ]; then
    case "$TMP_DIR" in
      */sysemble-build.*)
        rm -rf "$TMP_DIR" 2>/dev/null || true
        ;;
      *)
        warn "not cleaning unexpected temporary path: $TMP_DIR"
        ;;
    esac
    TMP_DIR=""
  fi
}

# ---------------------------------------------------------------------------
# Plan loading and validation
# ---------------------------------------------------------------------------

load_plan_records() {
  local records="$TMP_DIR/plan.records"
  local errfile="$TMP_DIR/plan.records.err"
  local rc=0

  if [ "$JSON_BACKEND" = "jq" ]; then
    json_extract_jq "$PLAN" >"$records" 2>"$errfile" || rc=$?
  else
    json_extract_python "$PLAN" >"$records" 2>"$errfile" || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    err "failed to parse plan JSON: $PLAN"
    if [ -s "$errfile" ]; then
      awk 'NR <= 5 { print "  " $0 }' "$errfile" >&2 || true
    fi
    return 1
  fi

  parse_plan_records "$records"
}

parse_plan_records() {
  local records=$1
  local key="" kind="" value="" idx=0

  PLAN_API_VERSION_TYPE="missing"
  PLAN_API_VERSION_VALUE=""
  PLAN_SPEC_TYPE="missing"
  PLAN_SPEC_VALUE=""
  PLAN_BASE_KIND_TYPE="missing"
  PLAN_BASE_KIND_VALUE=""
  PLAN_BASE_RELEASE_TYPE="missing"
  PLAN_BASE_RELEASE_VALUE=""
  PLAN_BASE_PIN_TYPE="missing"
  PLAN_BASE_PIN_VALUE=""
  PLAN_TARGET_ARCH_TYPE="missing"
  PLAN_TARGET_ARCH_VALUE=""
  PLAN_OUTPUTS_TYPE="missing"
  PLAN_OUTPUTS_VALUES=()
  PLAN_OUTPUTS_ELEM_TYPES=()
  PLAN_PACKAGES_TYPE="missing"
  PLAN_PACKAGES_VALUES=()
  PLAN_PACKAGES_ELEM_TYPES=()
  PLAN_MODULES_TYPE="missing"
  PLAN_MODULES_VALUES=()
  PLAN_EST_IMAGE_MB_TYPE="missing"
  PLAN_EST_IMAGE_MB_VALUE=""
  PLAN_EST_BUILD_MINUTES_TYPE="missing"
  PLAN_EST_BUILD_MINUTES_VALUE=""
  PLAN_EST_DISK_MB_TYPE="missing"
  PLAN_EST_DISK_MB_VALUE=""
  PLAN_WARNINGS_TYPE="missing"
  PLAN_WARNINGS_VALUES=()

  while IFS=$'\t' read -r key kind value; do
    [ -n "$key" ] || continue
    case "$key" in
      apiVersion)
        PLAN_API_VERSION_TYPE=$kind
        PLAN_API_VERSION_VALUE=$value
        ;;
      spec)
        PLAN_SPEC_TYPE=$kind
        PLAN_SPEC_VALUE=$value
        ;;
      base.kind)
        PLAN_BASE_KIND_TYPE=$kind
        PLAN_BASE_KIND_VALUE=$value
        ;;
      base.release)
        PLAN_BASE_RELEASE_TYPE=$kind
        PLAN_BASE_RELEASE_VALUE=$value
        ;;
      base.pin)
        PLAN_BASE_PIN_TYPE=$kind
        PLAN_BASE_PIN_VALUE=$value
        ;;
      target.arch)
        PLAN_TARGET_ARCH_TYPE=$kind
        PLAN_TARGET_ARCH_VALUE=$value
        ;;
      target.outputs)
        PLAN_OUTPUTS_TYPE=$kind
        ;;
      target.outputs.elem)
        idx=${#PLAN_OUTPUTS_VALUES[@]}
        PLAN_OUTPUTS_VALUES[$idx]=$value
        PLAN_OUTPUTS_ELEM_TYPES[$idx]=$kind
        ;;
      packages)
        PLAN_PACKAGES_TYPE=$kind
        ;;
      packages.elem)
        idx=${#PLAN_PACKAGES_VALUES[@]}
        PLAN_PACKAGES_VALUES[$idx]=$value
        PLAN_PACKAGES_ELEM_TYPES[$idx]=$kind
        ;;
      modules)
        PLAN_MODULES_TYPE=$kind
        ;;
      modules.elem)
        idx=${#PLAN_MODULES_VALUES[@]}
        PLAN_MODULES_VALUES[$idx]=$value
        ;;
      estimates.image_mb)
        PLAN_EST_IMAGE_MB_TYPE=$kind
        PLAN_EST_IMAGE_MB_VALUE=$value
        ;;
      estimates.build_minutes)
        PLAN_EST_BUILD_MINUTES_TYPE=$kind
        PLAN_EST_BUILD_MINUTES_VALUE=$value
        ;;
      estimates.disk_mb)
        PLAN_EST_DISK_MB_TYPE=$kind
        PLAN_EST_DISK_MB_VALUE=$value
        ;;
      warnings)
        PLAN_WARNINGS_TYPE=$kind
        ;;
      warnings.elem)
        idx=${#PLAN_WARNINGS_VALUES[@]}
        PLAN_WARNINGS_VALUES[$idx]=$value
        ;;
      *)
        : # unknown record keys are ignored on purpose (forward compatible)
        ;;
    esac
  done <"$records"

  return 0
}

validation_error() {
  err "plan: $*"
  PLAN_ERRORS=$((PLAN_ERRORS + 1))
}

require_string() {
  local label=$1
  local kind=$2
  local value=$3

  case "$kind" in
    missing)
      validation_error "$label is required (missing)"
      return 1
      ;;
    string)
      ;;
    *)
      validation_error "$label must be a string (got $kind)"
      return 1
      ;;
  esac

  if [ -z "$value" ]; then
    validation_error "$label must not be empty"
    return 1
  fi
  return 0
}

validate_target_outputs() {
  local i=0
  local kind="" value=""

  if [ "$PLAN_OUTPUTS_TYPE" != "array" ]; then
    validation_error "target.outputs must be a non-empty array (got $PLAN_OUTPUTS_TYPE)"
    return 0
  fi
  if [ "${#PLAN_OUTPUTS_VALUES[@]}" -eq 0 ]; then
    validation_error "target.outputs must contain at least one output"
    return 0
  fi

  while [ "$i" -lt "${#PLAN_OUTPUTS_VALUES[@]}" ]; do
    kind=${PLAN_OUTPUTS_ELEM_TYPES[$i]}
    value=${PLAN_OUTPUTS_VALUES[$i]}
    if [ "$kind" != "string" ]; then
      validation_error "target.outputs[$i] must be a string (got $kind)"
    elif [ -z "$value" ]; then
      validation_error "target.outputs[$i] must not be empty"
    else
      case "$value" in
        [a-z0-9]*)
          case "$value" in
            *[!a-z0-9._-]*)
              validation_error "target.outputs[$i] contains unsupported characters: '$value'"
              ;;
          esac
          ;;
        *)
          validation_error "target.outputs[$i] must start with a lowercase letter or digit: '$value'"
          ;;
      esac
    fi
    i=$((i + 1))
  done
  return 0
}

validate_packages() {
  local i=0
  local kind="" value=""

  if [ "$PLAN_PACKAGES_TYPE" != "array" ]; then
    validation_error "packages must be a non-empty array (got $PLAN_PACKAGES_TYPE)"
    return 0
  fi
  if [ "${#PLAN_PACKAGES_VALUES[@]}" -eq 0 ]; then
    validation_error "packages must not be empty"
    return 0
  fi

  while [ "$i" -lt "${#PLAN_PACKAGES_VALUES[@]}" ]; do
    kind=${PLAN_PACKAGES_ELEM_TYPES[$i]}
    value=${PLAN_PACKAGES_VALUES[$i]}
    if [ "$kind" != "string" ]; then
      validation_error "packages[$i] must be a string (got $kind)"
    elif [ -z "$value" ]; then
      validation_error "packages[$i] must not be empty"
    else
      case "$value" in
        [a-z0-9]*)
          case "$value" in
            *[!a-z0-9+.:-]*)
              validation_error "packages[$i] is not a valid Debian package name: '$value'"
              ;;
          esac
          ;;
        *)
          validation_error "packages[$i] is not a valid Debian package name: '$value'"
          ;;
      esac
    fi
    i=$((i + 1))
  done
  return 0
}

validate_plan() {
  PLAN_ERRORS=0

  if require_string "apiVersion" "$PLAN_API_VERSION_TYPE" "$PLAN_API_VERSION_VALUE"; then
    if [ "$PLAN_API_VERSION_VALUE" != "$API_VERSION" ]; then
      validation_error "apiVersion must be '$API_VERSION' (got '$PLAN_API_VERSION_VALUE')"
    fi
  fi

  if require_string "base.kind" "$PLAN_BASE_KIND_TYPE" "$PLAN_BASE_KIND_VALUE"; then
    if [ "$PLAN_BASE_KIND_VALUE" != "debian" ]; then
      validation_error "base.kind must be 'debian' for builders/debian (got '$PLAN_BASE_KIND_VALUE')"
    fi
  fi

  if require_string "base.release" "$PLAN_BASE_RELEASE_TYPE" "$PLAN_BASE_RELEASE_VALUE"; then
    case "$PLAN_BASE_RELEASE_VALUE" in
      [A-Za-z0-9]*)
        case "$PLAN_BASE_RELEASE_VALUE" in
          *[!A-Za-z0-9._-]*)
            validation_error "base.release contains characters unsafe for mmdebstrap: '$PLAN_BASE_RELEASE_VALUE'"
            ;;
        esac
        ;;
      *)
        validation_error "base.release must start with a letter or digit: '$PLAN_BASE_RELEASE_VALUE'"
        ;;
    esac
  fi

  if require_string "target.arch" "$PLAN_TARGET_ARCH_TYPE" "$PLAN_TARGET_ARCH_VALUE"; then
    case "$PLAN_TARGET_ARCH_VALUE" in
      x86_64 | aarch64)
        ;;
      *)
        validation_error "target.arch must be 'x86_64' or 'aarch64' (got '$PLAN_TARGET_ARCH_VALUE')"
        ;;
    esac
  fi

  validate_target_outputs
  validate_packages

  if [ "$PLAN_ERRORS" -ne 0 ]; then
    err "plan validation failed with $PLAN_ERRORS error(s): $PLAN"
    return 1
  fi

  PKG_COUNT=${#PLAN_PACKAGES_VALUES[@]}
  OUTPUTS_TEXT=$(join_values ", " "${PLAN_OUTPUTS_VALUES[@]}")
  return 0
}

# ---------------------------------------------------------------------------
# Small display helpers
# ---------------------------------------------------------------------------

join_values() {
  local sep=$1
  shift
  local out="" item

  for item in "$@"; do
    if [ -z "$out" ]; then
      out=$item
    else
      out="$out$sep$item"
    fi
  done
  printf '%s' "$out"
}

display_field() {
  local kind=$1
  local value=$2
  local fallback=$3

  case "$kind" in
    string)
      if [ -n "$value" ]; then
        printf '%s' "$value"
      else
        printf '(empty)'
      fi
      ;;
    missing)
      printf '%s' "$fallback"
      ;;
    *)
      printf '(%s)' "$kind"
      ;;
  esac
}

print_estimate() {
  local label=$1
  local kind=$2
  local value=$3
  local unit=$4

  case "$kind" in
    number | string)
      if [ -n "$value" ]; then
        printf '  %-14s %s %s\n' "$label:" "$value" "$unit"
      else
        printf '  %-14s (empty)\n' "$label:"
      fi
      ;;
    missing)
      printf '  %-14s (not provided)\n' "$label:"
      ;;
    *)
      printf '  %-14s (invalid: %s)\n' "$label:" "$kind"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Artifact manifest helpers (P0-b)
#
# These functions are pure (arguments in, stdout/stderr out, no global state)
# so tests can source lib.sh and call them directly without running build.sh.
# artifact_json() deliberately fails when a required input is missing instead
# of guessing: build.sh maps that failure to exit 6.
# ---------------------------------------------------------------------------

ARTIFACT_API_VERSION="sysemble/artifact/v1"
ARTIFACT_BUILDER_NAME="build.sh"
ARTIFACT_BUILDER_VERSION="0.1.0"
# P0-b direct-kernel mode (kept for artifact v1 backward compatibility).
ARTIFACT_BOOT_CMDLINE_KERNEL="console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target"
# P0-c UEFI mode: the root filesystem is GPT partition 2 of the virtio disk.
ARTIFACT_BOOT_CMDLINE_UEFI="root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=multi-user.target"
# P0-d1 graphical boot: selected when plan.packages names a display manager.
# journald forwarding keeps LightDM/Xorg messages on the serial console so the
# boot-check desktop assertions can see them.
ARTIFACT_BOOT_CMDLINE_UEFI_GRAPHICAL="root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=graphical.target systemd.journald.forward_to_console=1"
ARTIFACT_BOOT_MEMORY_MB_DEFAULT=1024
ARTIFACT_BOOT_MEMORY_MB_GRAPHICAL=2048
# P0-d2 live ISO: boot.mode="iso", boot.iso=live.iso, images[] format "iso".
# The live system finds its root filesystem through live-boot/live-media-path; no
# disk/partition information is part of an ISO-only manifest.
ARTIFACT_ISO_MODE="iso"
ARTIFACT_ISO_IMAGE_FORMAT="iso"
ARTIFACT_ISO_BOOT_MEMORY_MB_DEFAULT=$ISO_BOOT_MEMORY_MB_DEFAULT
ARTIFACT_ISO_BOOT_MEMORY_MB_GRAPHICAL=$ISO_BOOT_MEMORY_MB_GRAPHICAL
ARTIFACT_BOOT_CMDLINE_ISO=$ISO_BOOT_CMDLINE
ARTIFACT_BOOT_CMDLINE_ISO_GRAPHICAL=$ISO_BOOT_CMDLINE_GRAPHICAL
# A display manager without a known session package still boots graphically;
# this is the artifact desktop.session value used in that case.
ARTIFACT_DESKTOP_SESSION_FALLBACK="unknown"
# Backward-compatible alias for the current UEFI cmdline.
ARTIFACT_BOOT_CMDLINE=$ARTIFACT_BOOT_CMDLINE_UEFI

# ---------------------------------------------------------------------------
# P0-d1 desktop inference (pure)
#
# The plan contract has no desktop field; the builder infers it from
# plan.packages so the core/spec schema stays frozen:
#
#   gdm3          -> gdm        (highest display-manager priority)
#   sddm          -> sddm
#   lightdm       -> lightdm
#   plasma-desktop -> plasma     (highest session priority)
#   gnome-shell   -> gnome
#   xfce4         -> xfce
#
# Only the display manager decides graphical mode; the session only fills the
# artifact desktop.session field.
# ---------------------------------------------------------------------------

package_in_list() {
  local needle=""
  local package=""

  if [ "$#" -lt 1 ]; then
    return 1
  fi
  needle=$1
  shift
  for package in "$@"; do
    if [ "$package" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

# Print gdm, sddm, or lightdm for the highest-priority display manager found in
# the package arguments. Return 1 (printing nothing) when no DM is present.
detect_display_manager() {
  if package_in_list gdm3 "$@"; then
    printf 'gdm\n'
    return 0
  fi
  if package_in_list sddm "$@"; then
    printf 'sddm\n'
    return 0
  fi
  if package_in_list lightdm "$@"; then
    printf 'lightdm\n'
    return 0
  fi
  return 1
}

# Print plasma, gnome, or xfce for the highest-priority session package found in
# the package arguments. A DM without a recognized session prints "unknown".
detect_desktop_session() {
  if package_in_list plasma-desktop "$@"; then
    printf 'plasma\n'
  elif package_in_list gnome-shell "$@"; then
    printf 'gnome\n'
  elif package_in_list xfce4 "$@"; then
    printf 'xfce\n'
  else
    printf '%s\n' "$ARTIFACT_DESKTOP_SESSION_FALLBACK"
  fi
  return 0
}

# Which build stages a plan asks for (P0-d2):
#   "iso"       target.outputs contains iso and no qcow2/raw: ISO only.
#   "iso-disk"  target.outputs contains iso plus qcow2/raw: both are built.
#   "disk"      no iso (the frozen P0-c/P0-d1 behavior, also the safe default
#               when called without plan records, as the tests do).
#
# The plan contract allows other output names (uki/pxe); like P0-c this builder
# treats anything without iso as the disk path. Prints one word on stdout.
plan_build_mode() {
  local want_iso=0
  local want_disk=0

  if [ "${#PLAN_OUTPUTS_VALUES[@]}" -gt 0 ]; then
    if package_in_list iso "${PLAN_OUTPUTS_VALUES[@]}"; then
      want_iso=1
    fi
    if package_in_list qcow2 "${PLAN_OUTPUTS_VALUES[@]}" ||
      package_in_list raw "${PLAN_OUTPUTS_VALUES[@]}"; then
      want_disk=1
    fi
  fi

  if [ "$want_iso" -eq 1 ] && [ "$want_disk" -eq 1 ]; then
    printf 'iso-disk\n'
  elif [ "$want_iso" -eq 1 ]; then
    printf 'iso\n'
  else
    printf 'disk\n'
  fi
}

# Print the builder-added runtime package list for a plan. <iso> is 1/0,
# <graphical> is 1/0 (P0-d1 desktop inference), and <installer> is 1/0 (P0-d3).
# Packages already named by the plan or by an earlier group are skipped, so a
# plan that already names live-boot or e2fsprogs does not pass duplicates to
# mmdebstrap. Runs in a subshell by design.
runtime_packages_for() {
  local iso=$1
  local graphical=$2
  local installer=${3:-0}
  local extras_csv=""
  local package=""

  if [ "$graphical" -eq 1 ]; then
    for package in "${GRAPHICAL_RUNTIME_PACKAGES[@]}"; do
      if ! package_in_list "$package" "${PLAN_PACKAGES_VALUES[@]}"; then
        case ",$extras_csv," in
          *",$package,"*) ;;
          *)
            if [ -z "$extras_csv" ]; then
              extras_csv=$package
            else
              extras_csv="$extras_csv,$package"
            fi
            ;;
        esac
      fi
    done
  fi
  if [ "$iso" -eq 1 ]; then
    for package in "${ISO_RUNTIME_PACKAGES[@]}"; do
      if ! package_in_list "$package" "${PLAN_PACKAGES_VALUES[@]}"; then
        case ",$extras_csv," in
          *",$package,"*) ;;
          *)
            if [ -z "$extras_csv" ]; then
              extras_csv=$package
            else
              extras_csv="$extras_csv,$package"
            fi
            ;;
        esac
      fi
    done
  fi
  if [ "$installer" -eq 1 ]; then
    for package in "${INSTALLER_RUNTIME_PACKAGES[@]}"; do
      if ! package_in_list "$package" "${PLAN_PACKAGES_VALUES[@]}"; then
        case ",$extras_csv," in
          *",$package,"*) ;;
          *)
            if [ -z "$extras_csv" ]; then
              extras_csv=$package
            else
              extras_csv="$extras_csv,$package"
            fi
            ;;
        esac
      fi
    done
  fi

  if [ -n "$extras_csv" ]; then
    printf '%s\n' "$extras_csv"
  fi
}

# Print the builder-added runtime package count for a plan (see
# runtime_packages_for); used in build.log and the dry run.
runtime_package_count_for() {
  local iso=$1
  local graphical=$2
  local installer=${3:-0}
  local csv=""

  csv=$(runtime_packages_for "$iso" "$graphical" "$installer")
  if [ -z "$csv" ]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$(printf '%s' "$csv" | awk -F, '{print NF}')"
}

# Emit the P0-d2 live ISO GRUB configuration on stdout. <kernel_name> and
# <initrd_name> are the versioned basenames found in rootfs/boot; the ISO tree
# stores them as /live/vmlinuz and /live/initrd.img (P0-d2 workplan §2/§3), so
# the source versions are recorded as comments for diagnosis while the frozen
# boot lines use the stable live paths. The optional third argument is the
# P0-d1 desktop flag (1 = graphical.target), the optional fourth argument is
# the P0-d3 installer flag (1 = installer ISO), and the optional fifth argument
# is the P0-e1 TUI flag (1 = sysemble.install.tui=1 instead of a preselected
# sysemble.install=<device>).
iso_grub_cfg_text() {
  local kernel_name=$1
  local initrd_name=$2
  local graphical=${3:-0}
  local installer=${4:-0}
  local install_tui=${5:-0}
  local cmdline=$ISO_BOOT_CMDLINE

  case "$graphical" in
    0) ;;
    1) cmdline=$ISO_BOOT_CMDLINE_GRAPHICAL ;;
    *)
      err "iso_grub_cfg_text: graphical flag must be 0 or 1 (got '$graphical')"
      return 2
      ;;
  esac
  case "$install_tui" in
    0 | 1) ;;
    *)
      err "iso_grub_cfg_text: TUI installer flag must be 0 or 1 (got '$install_tui')"
      return 2
      ;;
  esac
  case "$installer" in
    0)
      if [ "$install_tui" -eq 1 ]; then
        err "iso_grub_cfg_text: TUI installer flag requires the installer flag"
        return 2
      fi
      ;;
    1)
      if [ "$install_tui" -eq 1 ]; then
        cmdline="$cmdline $INSTALLER_TUI_MARKER"
      else
        cmdline="$cmdline $INSTALLER_KERNEL_PARAM=$INSTALLER_DEVICE_DEFAULT"
      fi
      ;;
    *)
      err "iso_grub_cfg_text: installer flag must be 0 or 1 (got '$installer')"
      return 2
      ;;
  esac

  case "$kernel_name" in
    '')
      err "iso_grub_cfg_text: kernel name is empty"
      return 2
      ;;
    */*)
      err "iso_grub_cfg_text: kernel name must be a basename (got '$kernel_name')"
      return 2
      ;;
  esac
  case "$initrd_name" in
    '')
      err "iso_grub_cfg_text: initrd name is empty"
      return 2
      ;;
    */*)
      err "iso_grub_cfg_text: initrd name must be a basename (got '$initrd_name')"
      return 2
      ;;
  esac

  printf '# P0-d2 live ISO: source kernel=%s initrd=%s\n' "$kernel_name" "$initrd_name"
  printf 'set timeout=3\n'
  printf 'serial --unit=0 --speed=115200\n'
  printf 'terminal_input serial\n'
  printf 'terminal_output serial\n'
  printf 'menuentry "%s" {\n' "$ISO_GRUB_MENU_TITLE"
  printf '  search --no-floppy --file --set=root /live/vmlinuz\n'
  printf '  linux /live/vmlinuz %s\n' "$cmdline"
  printf '  initrd /live/initrd.img\n'
  printf '}\n'
}

# Packages the builder adds to a graphical build beyond plan.packages:
#   xserver-xorg   xfce4/lightdm only *Recommend* the X server and mmdebstrap
#                  installs no Recommends, so Xorg would otherwise be absent;
#   procps         provides pgrep, which the boot evidence unit polls. procps
#                  is Priority:important, so --variant=minbase omits it;
#   accountsservice provides org.freedesktop.Accounts, which LightDM uses for
#                  the greeter user list (only a Suggests in lightdm).
# No-DM disk builds keep the frozen P0-c package list unchanged; ISO builds
# separately add ISO_RUNTIME_PACKAGES.
GRAPHICAL_RUNTIME_PACKAGES=(xserver-xorg procps accountsservice)

# Debian process name for an artifact display_manager value. gdm3 is the
# package/process name for the "gdm" display manager.
desktop_manager_process_name() {
  case "$1" in
    gdm)
      printf 'gdm3\n'
      ;;
    lightdm | sddm)
      printf '%s\n' "$1"
      ;;
    *)
      err "unknown display manager: '$1'"
      return 2
      ;;
  esac
}

# Emit the P0-d1 graphical boot evidence unit on stdout.
#
# LightDM redirects Xorg's stdout to /var/log/lightdm/x-0.log, so journald
# console forwarding alone does not guarantee an "Xorg" line on the serial
# console. This oneshot unit deliberately writes the boot-check marker words
# (Xorg plus the real display-manager process name) to /dev/ttyS0. Each marker
# is polled for up to 60 seconds because graphical.target can be reached before
# LightDM has spawned the greeter/Xorg session.
boot_evidence_service_text() {
  local display_manager=$1
  local process=""

  process=$(desktop_manager_process_name "$display_manager") || return 2

  printf '[Unit]\n'
  printf 'Description=Sysemble boot evidence markers\n'
  printf 'After=graphical.target\n'
  printf '\n'
  printf '[Service]\n'
  printf 'Type=oneshot\n'
  printf "ExecStart=/bin/sh -c 'i=0; while [ \$\$i -lt 60 ]; do if pgrep -x Xorg >/dev/null 2>&1; then echo \"SYMBLE: Xorg ready\" > /dev/ttyS0; break; fi; i=\$\$((i+1)); sleep 1; done; i=0; while [ \$\$i -lt 60 ]; do if pgrep -x lightdm >/dev/null 2>&1 || pgrep -x sddm >/dev/null 2>&1 || pgrep -x gdm3 >/dev/null 2>&1; then echo \"SYMBLE: %s ready\" > /dev/ttyS0; break; fi; i=\$\$((i+1)); sleep 1; done; true'\n" "$process"
  printf 'TimeoutStartSec=90\n'
  printf '\n'
  printf '[Install]\n'
  printf 'WantedBy=graphical.target\n'
}

# Emit the frozen P0-c GRUB configuration on stdout. <kernel_name> and
# <initrd_name> are basenames found under rootfs/boot (for example
# vmlinuz-6.12.3-amd64). The optional third argument selects the P0-d1 desktop
# cmdline: "1" for graphical.target, "0"/omitted for the P0-c multi-user
# cmdline. build.sh embeds this text into BOOTX64.EFI with grub-mkstandalone
# and keeps a copy at <out>/grub.cfg.
grub_cfg_text() {
  local kernel_name=$1
  local initrd_name=$2
  local graphical=${3:-0}
  local cmdline=$ARTIFACT_BOOT_CMDLINE_UEFI

  case "$graphical" in
    0) ;;
    1) cmdline=$ARTIFACT_BOOT_CMDLINE_UEFI_GRAPHICAL ;;
    *)
      err "grub_cfg_text: graphical flag must be 0 or 1 (got '$graphical')"
      return 2
      ;;
  esac

  case "$kernel_name" in
    '')
      err "grub_cfg_text: kernel name is empty"
      return 2
      ;;
    */*)
      err "grub_cfg_text: kernel name must be a basename (got '$kernel_name')"
      return 2
      ;;
  esac
  case "$initrd_name" in
    '')
      err "grub_cfg_text: initrd name is empty"
      return 2
      ;;
    */*)
      err "grub_cfg_text: initrd name must be a basename (got '$initrd_name')"
      return 2
      ;;
  esac

  printf 'set timeout=3\n'
  printf 'serial --unit=0 --speed=115200\n'
  printf 'terminal_input serial\n'
  printf 'terminal_output serial\n'
  printf 'menuentry "%s" {\n' "$GRUB_MENU_TITLE"
  printf '  set root=(hd0,gpt2)\n'
  printf '  linux /boot/%s %s\n' "$kernel_name" "$cmdline"
  printf '  initrd /boot/%s\n' "$initrd_name"
  printf '}\n'
}

# Escape a string for a JSON string body. Plan records are already stripped of
# control characters by the JSON extractors, so backslash and quote escaping
# is sufficient here.
json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_quote() {
  local value=$1
  printf '"%s"' "$(printf '%s' "$value" | json_escape)"
}

# Print the SHA-256 of a regular file. Supports GNU coreutils, macOS shasum,
# and openssl so the same code works on the CI runner and on the dev host.
sha256_file() {
  local file=$1
  local digest=""

  if [ ! -f "$file" ]; then
    err "cannot hash missing file: $file"
    return 1
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum <"$file" 2>/dev/null | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 <"$file" 2>/dev/null | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(openssl dgst -sha256 <"$file" 2>/dev/null | awk '{print $NF}')
  else
    err "no SHA-256 tool available: install coreutils/shasum or openssl"
    return 1
  fi

  if [ "${#digest}" -ne 64 ]; then
    err "unexpected SHA-256 output for $file"
    return 1
  fi
  case "$digest" in
    *[!0-9a-f]*)
      err "unexpected SHA-256 output for $file: $digest"
      return 1
      ;;
  esac
  printf '%s\n' "$digest"
}

# Ceiling of the file size in MiB.
file_size_mb() {
  local file=$1
  local bytes=""

  if [ ! -f "$file" ]; then
    err "not a regular file: $file"
    return 1
  fi
  bytes=$(wc -c <"$file" | tr -d '[:space:]')
  case "$bytes" in
    '' | *[!0-9]*)
      err "cannot determine size of $file"
      return 1
      ;;
  esac
  printf '%s\n' $(((bytes + 1048575) / 1048576))
}

# Ceiling of the rootfs disk usage in MiB (du -sk reports 1 KiB blocks).
rootfs_size_mb() {
  local rootfs=$1
  local kb=""

  if [ ! -d "$rootfs" ]; then
    err "rootfs directory not found: $rootfs"
    return 1
  fi
  kb=$(du -sk "$rootfs" 2>/dev/null | awk 'NR == 1 {print $1}')
  case "$kb" in
    '' | *[!0-9]*)
      err "cannot determine rootfs size: $rootfs"
      return 1
      ;;
  esac
  printf '%s\n' $(((kb + 1023) / 1024))
}

# P0-c disk sizing (frozen):
#   size_mb = max(4096, ceil((rootfs_mb * 1.6 + 1024) / 256) * 256)
#
# Integer arithmetic only (bash 3.2). The ceiling is applied once to the real
# value: ceil((8 * rootfs_mb + 5120) / 1280) * 256, because
#   rootfs_mb * 1.6 + 1024 = (8 * rootfs_mb + 5120) / 5
#   / 256                  = (8 * rootfs_mb + 5120) / 1280
compute_disk_size_mb() {
  local rootfs_mb=$1
  local size=0

  case "$rootfs_mb" in
    '' | *[!0-9]*)
      err "rootfs_mb must be a non-negative integer (got '$rootfs_mb')"
      return 2
      ;;
  esac

  # ceil((rootfs_mb * 8 / 5 + 1024) / 256) * 256
  size=$((((rootfs_mb * 8) + 5120 + 1279) / 1280 * 256))
  if [ "$size" -lt "$DISK_MIN_MB" ]; then
    size=$DISK_MIN_MB
  fi
  printf '%s\n' "$size"
}

# Number of 4096-byte ext4 blocks for the root partition.
#
# P0-c writes ext4 into disk.img at ROOT_OFFSET_BYTES with -E offset= without
# giving mke2fs an explicit size. mke2fs then sizes the filesystem to
# "end-of-file - offset" (and prints "Warning: offset specified without an
# explicit file system size"). That is slightly LARGER than GPT partition 2,
# because p2 ends 33-34 sectors before the end of the disk to leave room for
# the backup GPT, and the kernel refuses to mount such an image:
#   "bad geometry: block count N exceeds size of device (M blocks)".
#
# Passing `-b 4096` plus an explicit block count keeps ext4 inside p2 and also
# avoids overwriting the backup GPT. We reserve one extra MiB before the end of
# the disk for safety, so one MiB is 256 blocks at 4096 bytes per block.
compute_root_fs_blocks() {
  local disk_mb=$1
  local blocks=0

  case "$disk_mb" in
    '' | *[!0-9]*)
      err "disk_mb must be a non-negative integer (got '$disk_mb')"
      return 2
      ;;
  esac

  blocks=$(((disk_mb - ROOT_START_MB - 1) * 256))
  if [ "$blocks" -le 0 ]; then
    err "disk_mb ${disk_mb} MB is too small for the P0-c layout"
    return 2
  fi
  printf '%s\n' "$blocks"
}

# Pick the highest-versioned file matching <rootfs>/boot/<prefix>-* using
# `sort -V`. Prints the absolute path; returns 1 when no candidate exists.
find_boot_image() {
  local rootfs=$1
  local prefix=$2
  local candidate=""

  if [ ! -d "$rootfs/boot" ]; then
    return 1
  fi
  candidate=$(
    find "$rootfs/boot" -maxdepth 1 \( -type f -o -type l \) \
      -name "$prefix-*" -print 2>/dev/null | sort -V | tail -n 1
  )
  if [ -z "$candidate" ]; then
    return 1
  fi
  printf '%s\n' "$candidate"
}

# Emit a sysemble/artifact/v1 manifest on stdout.
#
# Usage:
#   artifact_json <out_dir> <spec> <release> <pin> <arch> <created_at> \
#                 [package ...]
#
# <out_dir> must contain rootfs/, disk.img, and disk.qcow2 with a kernel and an
# initrd under rootfs/boot/. When <out_dir> also contains the P0-c GRUB outputs
# (grub.cfg and esp/EFI/BOOT/BOOTX64.EFI) the manifest is extended with
# boot.mode="uefi", boot.disk, boot.grub, and the two partitions. A package list
# naming a display manager additionally selects the P0-d1 graphical boot
# (boot.graphical=true, boot.memory_mb=2048, graphical.target cmdline) and adds
# the top-level desktop object. Without the GRUB outputs the historical P0-b
# direct-kernel shape is emitted unchanged (boot.mode absent, which consumers
# must treat as "kernel"). The function never writes files; build.sh writes its
# stdout atomically to <out>/artifact.json.
artifact_json() {
  local out=""
  local spec=""
  local release=""
  local pin=""
  local arch=""
  local created_at=""
  local rootfs=""
  local raw=""
  local qcow=""
  local esp_efi=""
  local grub_cfg=""
  local uefi=0
  local have_efi=0
  local have_cfg=0
  local cmdline=""
  local desktop_dm=""
  local desktop_session=""
  local graphical=0
  local graphical_json="false"
  local memory_mb=$ARTIFACT_BOOT_MEMORY_MB_DEFAULT
  local root_part_mb=""
  local rootfs_mb=""
  local raw_mb=""
  local qcow_mb=""
  local raw_sha=""
  local qcow_sha=""
  local kernel=""
  local initrd=""
  local kernel_rel=""
  local initrd_rel=""
  local pin_json="null"
  local sep=""

  if [ "$#" -lt 6 ]; then
    err "artifact_json: expected at least 6 arguments"
    return 2
  fi
  out=$1
  spec=$2
  release=$3
  pin=$4
  arch=$5
  created_at=$6
  shift 6

  rootfs="$out/rootfs"
  raw="$out/disk.img"
  qcow="$out/disk.qcow2"
  esp_efi="$out/$GRUB_EFI_REL"
  grub_cfg="$out/$GRUB_CONFIG_REL"

  if [ ! -d "$rootfs" ]; then
    err "artifact: rootfs directory is missing: $rootfs"
    return 1
  fi
  if [ ! -f "$raw" ]; then
    err "artifact: raw disk image is missing: $raw"
    return 1
  fi
  if [ ! -f "$qcow" ]; then
    err "artifact: qcow2 image is missing: $qcow"
    return 1
  fi

  # The two P0-c outputs are written together. Seeing only one means a partial
  # assembly, so refuse to guess a boot mode.
  if [ -e "$esp_efi" ] || [ -L "$esp_efi" ]; then
    have_efi=1
  fi
  if [ -e "$grub_cfg" ] || [ -L "$grub_cfg" ]; then
    have_cfg=1
  fi
  if [ "$have_efi" -eq 1 ] && [ "$have_cfg" -eq 1 ]; then
    if [ ! -f "$esp_efi" ] || [ ! -s "$esp_efi" ] ||
      [ ! -f "$grub_cfg" ] || [ ! -s "$grub_cfg" ]; then
      err "artifact: UEFI outputs are incomplete: $GRUB_EFI_REL and $GRUB_CONFIG_REL must be non-empty regular files"
      return 1
    fi
    uefi=1
  elif [ "$have_efi" -eq 1 ] || [ "$have_cfg" -eq 1 ]; then
    err "artifact: incomplete UEFI outputs: expected both $GRUB_EFI_REL and $GRUB_CONFIG_REL"
    return 1
  fi

  kernel=$(find_boot_image "$rootfs" vmlinuz) || {
    err "artifact: no kernel found in $rootfs/boot (expected vmlinuz-*)"
    return 1
  }
  initrd=$(find_boot_image "$rootfs" initrd.img) || {
    err "artifact: no initrd found in $rootfs/boot (expected initrd.img-*)"
    return 1
  }
  kernel_rel="rootfs/boot/${kernel##*/}"
  initrd_rel="rootfs/boot/${initrd##*/}"

  rootfs_mb=$(rootfs_size_mb "$rootfs") || return 1
  raw_mb=$(file_size_mb "$raw") || return 1
  qcow_mb=$(file_size_mb "$qcow") || return 1
  raw_sha=$(sha256_file "$raw") || return 1
  qcow_sha=$(sha256_file "$qcow") || return 1

  if [ "$uefi" -eq 1 ]; then
    if [ "$raw_mb" -le "$ESP_SIZE_MB" ]; then
      err "artifact: raw image is too small for a ${ESP_SIZE_MB} MB ESP (got ${raw_mb} MB)"
      return 1
    fi
    cmdline=$ARTIFACT_BOOT_CMDLINE_UEFI
    # P0-d1: only a display manager turns on graphical boot. The session package
    # supplies desktop.session but does not change the boot target by itself.
    if desktop_dm=$(detect_display_manager "$@"); then
      desktop_session=$(detect_desktop_session "$@")
      graphical=1
      graphical_json="true"
      memory_mb=$ARTIFACT_BOOT_MEMORY_MB_GRAPHICAL
      cmdline=$ARTIFACT_BOOT_CMDLINE_UEFI_GRAPHICAL
    else
      desktop_dm=""
      desktop_session=""
      graphical=0
      graphical_json="false"
      memory_mb=$ARTIFACT_BOOT_MEMORY_MB_DEFAULT
    fi
    # The frozen P0-c artifact sample reports root = disk_mb - 512: the 1 MiB
    # alignment gap between the GPT start and the ESP is not charged to a role.
    root_part_mb=$((raw_mb - ESP_SIZE_MB))
  else
    cmdline=$ARTIFACT_BOOT_CMDLINE_KERNEL
  fi

  if [ -n "$pin" ]; then
    pin_json=$(json_quote "$pin")
  fi

  printf '{\n'
  printf '  "apiVersion": %s,\n' "$(json_quote "$ARTIFACT_API_VERSION")"
  printf '  "createdAt": %s,\n' "$(json_quote "$created_at")"
  printf '  "spec": %s,\n' "$(json_quote "$spec")"
  printf '  "base": {"kind": "debian", "release": %s, "pin": %s},\n' \
    "$(json_quote "$release")" "$pin_json"
  printf '  "arch": %s,\n' "$(json_quote "$arch")"
  printf '  "packages": ['
  for pkg in "$@"; do
    printf '%s%s' "$sep" "$(json_quote "$pkg")"
    sep=", "
  done
  printf '],\n'
  printf '  "rootfs": {"path": "rootfs", "size_mb": %s},\n' "$rootfs_mb"
  printf '  "images": [\n'
  printf '    {"path": "disk.img", "format": "raw", "size_mb": %s, "sha256": %s},\n' \
    "$raw_mb" "$(json_quote "$raw_sha")"
  printf '    {"path": "disk.qcow2", "format": "qcow2", "size_mb": %s, "sha256": %s}\n' \
    "$qcow_mb" "$(json_quote "$qcow_sha")"
  printf '  ],\n'
  if [ "$uefi" -eq 1 ] && [ "$graphical" -eq 1 ]; then
    printf '  "desktop": {"session": %s, "display_manager": %s},\n' \
      "$(json_quote "$desktop_session")" "$(json_quote "$desktop_dm")"
  fi
  printf '  "boot": {\n'
  if [ "$uefi" -eq 1 ]; then
    printf '    "mode": "uefi",\n'
    printf '    "disk": "disk.img",\n'
  fi
  printf '    "kernel": %s,\n' "$(json_quote "$kernel_rel")"
  printf '    "initrd": %s,\n' "$(json_quote "$initrd_rel")"
  if [ "$uefi" -eq 1 ]; then
    printf '    "graphical": %s,\n' "$graphical_json"
    printf '    "memory_mb": %s,\n' "$memory_mb"
    printf '    "cmdline": %s,\n' "$(json_quote "$cmdline")"
    printf '    "grub": {"efi": %s, "config": %s}\n' \
      "$(json_quote "$GRUB_EFI_REL")" "$(json_quote "$GRUB_CONFIG_REL")"
  else
    printf '    "cmdline": %s\n' "$(json_quote "$cmdline")"
  fi
  printf '  },\n'
  if [ "$uefi" -eq 1 ]; then
    printf '  "partitions": [\n'
    printf '    {"index": 1, "role": "esp", "size_mb": %s, "fs": "vfat32"},\n' \
      "$ESP_SIZE_MB"
    printf '    {"index": 2, "role": "root", "size_mb": %s, "fs": "ext4"}\n' \
      "$root_part_mb"
    printf '  ],\n'
  fi
  printf '  "builder": {"name": %s, "version": %s}\n' \
    "$(json_quote "$ARTIFACT_BUILDER_NAME")" "$(json_quote "$ARTIFACT_BUILDER_VERSION")"
  printf '}\n'
  return 0
}

# Emit a sysemble/artifact/v1 manifest for a live ISO build on stdout.
#
# Usage:
#   artifact_iso_json <out_dir> <spec> <release> <pin> <arch> <created_at> \
#                     <include_disk 0|1> [package ...]
#   artifact_install_json <out_dir> <spec> <release> <pin> <arch> <created_at> \
#                     [package ...]
#   artifact_install_tui_json <out_dir> <spec> <release> <pin> <arch> \
#                     <created_at> [package ...]
#
# <out_dir> must contain rootfs/ and live.iso. When <include_disk> is 1 the
# out dir must also contain disk.img and disk.qcow2 (an iso+disk plan); the
# manifest then records those images and the P0-c partitions as well. The boot
# object is mode="iso" (the ISO carries its own kernel, initrd, and grub.cfg),
# and a package list naming a display manager selects the P0-d1 graphical
# cmdline + desktop object + 2048 MB, exactly like the UEFI manifest.
#
# artifact_install_json is the P0-d3 installer variant: boot.mode="install",
# boot.install_device="/dev/vda", the frozen ISO cmdline plus
# sysemble.install=/dev/vda, and memory_mb=1024. artifact_install_tui_json is
# the P0-e1 variant: boot.mode="install", boot.install_tui=true, no
# install_device, and sysemble.install.tui=1 appended to the frozen ISO
# cmdline. Both are always headless and ISO-only (images stays exactly
# [live.iso]); an iso+disk build is rejected. The functions never write files;
# build.sh writes stdout atomically to <out>/artifact.json.
artifact_iso_json_common() {
  local boot_mode=$1
  local install_device=$2
  shift 2
  local out=""
  local spec=""
  local release=""
  local pin=""
  local arch=""
  local created_at=""
  local include_disk=""
  local rootfs=""
  local iso=""
  local raw=""
  local qcow=""
  local desktop_dm=""
  local desktop_session=""
  local graphical=0
  local graphical_json="false"
  local memory_mb=$ARTIFACT_ISO_BOOT_MEMORY_MB_DEFAULT
  local cmdline=$ARTIFACT_BOOT_CMDLINE_ISO
  local root_part_mb=""
  local rootfs_mb=""
  local raw_mb=""
  local qcow_mb=""
  local iso_mb=""
  local raw_sha=""
  local qcow_sha=""
  local iso_sha=""
  local pin_json="null"
  local sep=""

  case "$boot_mode" in
    iso)
      if [ -n "$install_device" ]; then
        err "artifact: iso mode must not carry an install device"
        return 2
      fi
      ;;
    install)
      case "$install_device" in
        /dev/*) : ;;
        *)
          err "artifact: install mode requires a /dev install device (got '$install_device')"
          return 2
          ;;
      esac
      ;;
    install-tui)
      # P0-e1: the TUI wizard has no preselected disk, so an install device is
      # a contract violation rather than an ignored field.
      if [ -n "$install_device" ]; then
        err "artifact: install-tui mode must not carry an install device"
        return 2
      fi
      ;;
    *)
      err "artifact: boot mode must be 'iso', 'install', or 'install-tui' (got '$boot_mode')"
      return 2
      ;;
  esac

  if [ "$#" -lt 7 ]; then
    err "artifact: expected at least 7 arguments after the boot mode"
    return 2
  fi
  out=$1
  spec=$2
  release=$3
  pin=$4
  arch=$5
  created_at=$6
  include_disk=$7
  shift 7

  case "$include_disk" in
    0 | 1) ;;
    *)
      err "artifact: include_disk must be 0 or 1 (got '$include_disk')"
      return 2
      ;;
  esac
  if [ "$boot_mode" != "iso" ] && [ "$include_disk" -eq 1 ]; then
    err "artifact: installer modes are ISO-only; include_disk must be 0"
    return 2
  fi

  rootfs="$out/rootfs"
  iso="$out/$ISO_ARTIFACT_NAME"
  raw="$out/disk.img"
  qcow="$out/disk.qcow2"

  if [ ! -d "$rootfs" ]; then
    err "artifact: rootfs directory is missing: $rootfs"
    return 1
  fi
  if [ ! -f "$iso" ]; then
    err "artifact: live ISO is missing: $iso"
    return 1
  fi
  if [ ! -s "$iso" ]; then
    err "artifact: live ISO is empty: $iso"
    return 1
  fi

  rootfs_mb=$(rootfs_size_mb "$rootfs") || return 1
  iso_mb=$(file_size_mb "$iso") || return 1
  iso_sha=$(sha256_file "$iso") || return 1

  if [ "$include_disk" -eq 1 ]; then
    if [ ! -f "$raw" ]; then
      err "artifact: raw disk image is missing: $raw"
      return 1
    fi
    if [ ! -f "$qcow" ]; then
      err "artifact: qcow2 image is missing: $qcow"
      return 1
    fi
    raw_mb=$(file_size_mb "$raw") || return 1
    qcow_mb=$(file_size_mb "$qcow") || return 1
    raw_sha=$(sha256_file "$raw") || return 1
    qcow_sha=$(sha256_file "$qcow") || return 1
    if [ "$raw_mb" -le "$ESP_SIZE_MB" ]; then
      err "artifact: raw image is too small for a ${ESP_SIZE_MB} MB ESP (got ${raw_mb} MB)"
      return 1
    fi
    root_part_mb=$((raw_mb - ESP_SIZE_MB))
  fi

  # P0-d3/P0-e1 installer modes are always headless and ISO-only:
  # boot.mode="install" (unattended, with install_device) or "install-tui"
  # (wizard, with sysemble.install.tui=1 and no install_device); both use the
  # frozen multi-user live cmdline and 1024 MB. P0-d1 desktop inference is
  # reused unchanged for plain ISO builds. Only a display manager turns on
  # graphical boot; a session package alone does not.
  if [ "$boot_mode" = "install" ]; then
    desktop_dm=""
    desktop_session=""
    graphical=0
    graphical_json="false"
    memory_mb=$ARTIFACT_ISO_BOOT_MEMORY_MB_DEFAULT
    cmdline="$ARTIFACT_BOOT_CMDLINE_ISO $INSTALLER_KERNEL_PARAM=$install_device"
  elif [ "$boot_mode" = "install-tui" ]; then
    desktop_dm=""
    desktop_session=""
    graphical=0
    graphical_json="false"
    memory_mb=$ARTIFACT_ISO_BOOT_MEMORY_MB_DEFAULT
    cmdline="$ARTIFACT_BOOT_CMDLINE_ISO $INSTALLER_TUI_MARKER"
  elif desktop_dm=$(detect_display_manager "$@"); then
    desktop_session=$(detect_desktop_session "$@")
    graphical=1
    graphical_json="true"
    memory_mb=$ARTIFACT_ISO_BOOT_MEMORY_MB_GRAPHICAL
    cmdline=$ARTIFACT_BOOT_CMDLINE_ISO_GRAPHICAL
  else
    desktop_dm=""
    desktop_session=""
    graphical=0
    graphical_json="false"
    memory_mb=$ARTIFACT_ISO_BOOT_MEMORY_MB_DEFAULT
    cmdline=$ARTIFACT_BOOT_CMDLINE_ISO
  fi

  if [ -n "$pin" ]; then
    pin_json=$(json_quote "$pin")
  fi

  printf '{\n'
  printf '  "apiVersion": %s,\n' "$(json_quote "$ARTIFACT_API_VERSION")"
  printf '  "createdAt": %s,\n' "$(json_quote "$created_at")"
  printf '  "spec": %s,\n' "$(json_quote "$spec")"
  printf '  "base": {"kind": "debian", "release": %s, "pin": %s},\n' \
    "$(json_quote "$release")" "$pin_json"
  printf '  "arch": %s,\n' "$(json_quote "$arch")"
  printf '  "packages": ['
  for pkg in "$@"; do
    printf '%s%s' "$sep" "$(json_quote "$pkg")"
    sep=", "
  done
  printf '],\n'
  printf '  "rootfs": {"path": "rootfs", "size_mb": %s},\n' "$rootfs_mb"
  printf '  "images": [\n'
  printf '    {"path": %s, "format": %s, "size_mb": %s, "sha256": %s}' \
    "$(json_quote "$ISO_ARTIFACT_NAME")" "$(json_quote "$ARTIFACT_ISO_IMAGE_FORMAT")" \
    "$iso_mb" "$(json_quote "$iso_sha")"
  if [ "$include_disk" -eq 1 ]; then
    printf ',\n'
    printf '    {"path": "disk.img", "format": "raw", "size_mb": %s, "sha256": %s},\n' \
      "$raw_mb" "$(json_quote "$raw_sha")"
    printf '    {"path": "disk.qcow2", "format": "qcow2", "size_mb": %s, "sha256": %s}\n' \
      "$qcow_mb" "$(json_quote "$qcow_sha")"
  else
    printf '\n'
  fi
  printf '  ],\n'
  if [ "$graphical" -eq 1 ]; then
    printf '  "desktop": {"session": %s, "display_manager": %s},\n' \
      "$(json_quote "$desktop_session")" "$(json_quote "$desktop_dm")"
  fi
  printf '  "boot": {\n'
  if [ "$boot_mode" = "install-tui" ]; then
    # The artifact contract keeps boot.mode="install" for both installer
    # variants; install_tui distinguishes the wizard.
    printf '    "mode": "install",\n'
  else
    printf '    "mode": %s,\n' "$(json_quote "$boot_mode")"
  fi
  printf '    "iso": %s,\n' "$(json_quote "$ISO_ARTIFACT_NAME")"
  if [ "$boot_mode" = "install" ]; then
    printf '    "install_device": %s,\n' "$(json_quote "$install_device")"
  fi
  if [ "$boot_mode" = "install-tui" ]; then
    printf '    "install_tui": true,\n'
  fi
  if [ "$graphical" -eq 1 ]; then
    printf '    "graphical": true,\n'
  fi
  printf '    "cmdline": %s,\n' "$(json_quote "$cmdline")"
  printf '    "memory_mb": %s\n' "$memory_mb"
  printf '  },\n'
  if [ "$include_disk" -eq 1 ]; then
    printf '  "partitions": [\n'
    printf '    {"index": 1, "role": "esp", "size_mb": %s, "fs": "vfat32"},\n' \
      "$ESP_SIZE_MB"
    printf '    {"index": 2, "role": "root", "size_mb": %s, "fs": "ext4"}\n' \
      "$root_part_mb"
    printf '  ],\n'
  fi
  printf '  "builder": {"name": %s, "version": %s}\n' \
    "$(json_quote "$ARTIFACT_BUILDER_NAME")" "$(json_quote "$ARTIFACT_BUILDER_VERSION")"
  printf '}\n'
  return 0
}

# P0-d2 wrapper: a plain live ISO artifact (boot.mode="iso").
artifact_iso_json() {
  artifact_iso_json_common iso "" "$@"
}

# P0-d3 wrapper: the headless installer ISO artifact (boot.mode="install").
# The include_disk position of the common helper is pinned to 0 because an
# installer build is ISO-only; the caller passes the six metadata arguments
# followed by the plan package list.
artifact_install_json() {
  if [ "$#" -lt 6 ]; then
    err "artifact_install_json: expected at least 6 arguments"
    return 2
  fi
  local out=$1
  local spec=$2
  local release=$3
  local pin=$4
  local arch=$5
  local created_at=$6

  shift 6
  artifact_iso_json_common install "$INSTALLER_DEVICE_DEFAULT" \
    "$out" "$spec" "$release" "$pin" "$arch" "$created_at" 0 "$@"
}

# P0-e1 wrapper: the TUI installer ISO artifact (boot.mode="install",
# boot.install_tui=true, no install_device). The install path is selected at
# runtime by the wizard, so the artifact deliberately has no install_device.
artifact_install_tui_json() {
  if [ "$#" -lt 6 ]; then
    err "artifact_install_tui_json: expected at least 6 arguments"
    return 2
  fi
  local out=$1
  local spec=$2
  local release=$3
  local pin=$4
  local arch=$5
  local created_at=$6

  shift 6
  artifact_iso_json_common install-tui "" \
    "$out" "$spec" "$release" "$pin" "$arch" "$created_at" 0 "$@"
}

# ---------------------------------------------------------------------------
# Engine preflight
# ---------------------------------------------------------------------------

native_preflight() {
  local failed=0
  local host_os=""
  local euid=""
  local mode=""
  local want_iso=0
  local want_disk=0

  # P0-d2: only require the toolchain the plan actually uses. An ISO-only plan
  # never runs sgdisk/mkfs.ext4/qemu-img/dd; it needs squashfs-tools + xorriso
  # in addition to the shared mkfs.vfat/mcopy/grub-mkstandalone set.
  mode=$(plan_build_mode)
  case "$mode" in
    iso)
      want_iso=1
      ;;
    iso-disk)
      want_iso=1
      want_disk=1
      ;;
    *)
      want_disk=1
      ;;
  esac

  host_os=$(uname -s 2>/dev/null || true)
  [ -n "$host_os" ] || host_os="unknown"
  if [ "$host_os" != "Linux" ]; then
    err "native engine requires Linux; this host reports '$host_os' (use --engine docker on macOS/Windows)"
    failed=1
  fi

  euid=$(id -u 2>/dev/null || true)
  [ -n "$euid" ] || euid="unknown"
  if [ "$euid" != "0" ]; then
    err "native engine requires root (euid 0); current euid is '$euid'"
    failed=1
  fi

  if ! command -v mmdebstrap >/dev/null 2>&1; then
    err "native engine requires 'mmdebstrap' on PATH; it was not found"
    failed=1
  fi

  # Shared UEFI boot-image toolchain (disk ESP and live efi.img).
  if ! command -v mkfs.vfat >/dev/null 2>&1; then
    err "native engine requires 'mkfs.vfat' on PATH (dosfstools) to create the FAT ESP/efi.img; it was not found"
    failed=1
  fi

  if ! command -v mcopy >/dev/null 2>&1; then
    err "native engine requires 'mcopy' on PATH (mtools) to populate the ESP/efi.img; it was not found"
    failed=1
  fi

  if ! command -v grub-mkstandalone >/dev/null 2>&1; then
    err "native engine requires 'grub-mkstandalone' on PATH (grub-efi-amd64-bin) to build BOOTX64.EFI; it was not found"
    failed=1
  fi

  if [ "$want_iso" -eq 1 ]; then
    if ! command -v mksquashfs >/dev/null 2>&1; then
      err "native engine requires 'mksquashfs' on PATH (squashfs-tools) to build live/filesystem.squashfs; it was not found"
      failed=1
    fi
    if ! command -v xorriso >/dev/null 2>&1; then
      err "native engine requires 'xorriso' on PATH (xorriso) to build the UEFI El Torito ISO; it was not found"
      failed=1
    fi
  fi

  if [ "$want_disk" -eq 1 ]; then
    if ! command -v mkfs.ext4 >/dev/null 2>&1; then
      err "native engine requires 'mkfs.ext4' on PATH (e2fsprogs); it was not found"
      failed=1
    fi

    if ! command -v qemu-img >/dev/null 2>&1; then
      err "native engine requires 'qemu-img' on PATH (qemu-utils); it was not found"
      failed=1
    fi

    # P0-c1 GPT + GRUB/UEFI toolchain. Every missing tool is reported, then the
    # caller exits 3.
    if ! command -v sgdisk >/dev/null 2>&1; then
      err "native engine requires 'sgdisk' on PATH (gdisk) to write the GPT partition table; it was not found"
      failed=1
    fi

    if ! command -v dd >/dev/null 2>&1; then
      err "native engine requires 'dd' on PATH (coreutils) to merge the ESP into disk.img; it was not found"
      failed=1
    fi
  fi

  return "$failed"
}

docker_preflight() {
  if ! command -v docker >/dev/null 2>&1; then
    err "docker engine requires the 'docker' CLI on PATH; it was not found"
    return 1
  fi

  local info_file="$TMP_DIR/docker-info.txt"
  local rc=0
  local dpid=0
  local wpid=0

  docker info >"$info_file" 2>&1 &
  dpid=$!
  (sleep "$DOCKER_INFO_TIMEOUT"; kill -TERM "$dpid" 2>/dev/null || true) &
  wpid=$!

  wait "$dpid" || rc=$?
  kill -TERM "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true

  if [ "$rc" -ne 0 ]; then
    err "docker daemon is not available (docker info failed or timed out after ${DOCKER_INFO_TIMEOUT}s)"
    if [ -s "$info_file" ]; then
      awk '
        /^Server:/ { in_server = 1; found = 1 }
        in_server { print "  " $0 }
        !in_server && NR <= 5 { fallback = fallback "  " $0 "\n" }
        END { if (!found) printf "%s", fallback }
      ' "$info_file" >&2 || true
    fi
    return 1
  fi
  return 0
}
