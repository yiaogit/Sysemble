#!/usr/bin/env bash
# Sysemble Debian builder - shared helpers for build.sh (P0-a + P0-b + P0-c).
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
Sysemble Debian builder (P0-c) - build a bootable Debian UEFI disk image from plan.json

Usage:
  builders/debian/build.sh --plan <plan.json> --out <dir> [--dry-run] [--execute] [--engine docker|native]

Options:
  --plan <path>      plan.json produced by `sysemble plan --json`
  --out <dir>        output directory; created if missing
  --dry-run          validate the plan, print stages/packages/estimates, and
                     write only <out>/plan.copy.json
  --execute          explicit alias for the default build mode: build the
                     rootfs, GPT disk images, and artifact.json. Mutually
                     exclusive with --dry-run. The CI contract passes this flag.
  --engine <name>    native (default) or docker
  -h, --help         show this help and exit 0

Outputs (native --execute):
  <out>/rootfs/        mmdebstrap rootfs
  <out>/disk.img       raw GPT image: p1 ESP (vfat32) + p2 root (ext4)
  <out>/disk.qcow2     qcow2 conversion of disk.img
  <out>/esp/           ESP staging tree (EFI/BOOT/BOOTX64.EFI, boot/grub/grub.cfg)
  <out>/grub.cfg       GRUB config embedded into BOOTX64.EFI
  <out>/artifact.json  sysemble/artifact/v1 manifest (boot.mode = "uefi")
  <out>/build.log      full build output (tee)

  <out>/esp.img is a temporary FAT32 image and is removed on success.

Engines:
  native   requires Linux, euid 0, and mmdebstrap, mkfs.ext4, qemu-img,
           sgdisk, mkfs.vfat, mcopy, grub-mkstandalone, and dd on PATH;
           builds rootfs, disk.img (GPT + ESP + GRUB EFI), disk.qcow2, and
           artifact.json.
  docker   runs mmdebstrap in a debian:trixie container with <out> mounted at
           /out; requires a working Docker daemon. Docker mode still stops after
           the rootfs: P0-c disk/artifact assembly is native-only and has not
           been verified in docker mode, so --execute with --engine docker is
           rejected (exit 2). --dry-run does not check the engine, so it works
           on hosts without Linux/Docker.

Exit codes:
  0  success (dry run, or a complete native image build)
  1  invalid plan (malformed JSON or failed plan validation), or plan.spec is
     missing for a real native build (artifact.json requires it)
  2  usage or I/O error (including an unsafe --out)
  3  native engine unavailable (not Linux, not root, or a required tool is
     missing: mmdebstrap, mkfs.ext4, qemu-img, sgdisk, mkfs.vfat, mcopy,
     grub-mkstandalone, dd)
  4  docker engine unavailable (no docker CLI or no daemon)
  5  no JSON parser available (install jq or python3)
  6  a build step failed, <out>/rootfs or an output image already exists, or
     the rootfs has no bootable kernel/initrd

P0-c1 scope: GPT partition table, FAT32 ESP, GRUB EFI (embedded config), and
UEFI artifact extensions. Installers, desktops, ISO/squashfs, secure boot, and
cross-architecture builds are out of scope. An artifact without boot.mode still
means the P0-b direct-kernel mode.
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
# Backward-compatible alias for the current UEFI cmdline.
ARTIFACT_BOOT_CMDLINE=$ARTIFACT_BOOT_CMDLINE_UEFI

# Emit the frozen P0-c GRUB configuration on stdout. <kernel_name> and
# <initrd_name> are basenames found under rootfs/boot (for example
# vmlinuz-6.12.3-amd64). build.sh embeds this text into BOOTX64.EFI with
# grub-mkstandalone and keeps a copy at <out>/grub.cfg.
grub_cfg_text() {
  local kernel_name=$1
  local initrd_name=$2

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
  printf '  linux /boot/%s %s\n' "$kernel_name" "$ARTIFACT_BOOT_CMDLINE_UEFI"
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
# boot.mode="uefi", boot.disk, boot.grub, and the two partitions. Without those
# outputs the historical P0-b direct-kernel shape is emitted (boot.mode absent,
# which consumers must treat as "kernel"). The function never writes files;
# build.sh writes its stdout atomically to <out>/artifact.json.
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
  printf '  "boot": {\n'
  if [ "$uefi" -eq 1 ]; then
    printf '    "mode": "uefi",\n'
    printf '    "disk": "disk.img",\n'
  fi
  printf '    "kernel": %s,\n' "$(json_quote "$kernel_rel")"
  printf '    "initrd": %s,\n' "$(json_quote "$initrd_rel")"
  if [ "$uefi" -eq 1 ]; then
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

# ---------------------------------------------------------------------------
# Engine preflight
# ---------------------------------------------------------------------------

native_preflight() {
  local failed=0
  local host_os=""
  local euid=""

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

  if ! command -v mkfs.vfat >/dev/null 2>&1; then
    err "native engine requires 'mkfs.vfat' on PATH (dosfstools) to create the FAT32 ESP; it was not found"
    failed=1
  fi

  if ! command -v mcopy >/dev/null 2>&1; then
    err "native engine requires 'mcopy' on PATH (mtools) to populate the ESP; it was not found"
    failed=1
  fi

  if ! command -v grub-mkstandalone >/dev/null 2>&1; then
    err "native engine requires 'grub-mkstandalone' on PATH (grub-efi-amd64-bin) to build BOOTX64.EFI; it was not found"
    failed=1
  fi

  if ! command -v dd >/dev/null 2>&1; then
    err "native engine requires 'dd' on PATH (coreutils) to merge the ESP into disk.img; it was not found"
    failed=1
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
