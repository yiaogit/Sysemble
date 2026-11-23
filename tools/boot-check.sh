#!/usr/bin/env bash
# Sysemble boot-check (P0-b kernel + P0-c UEFI + P0-d1 graphical).
#
# Boots a built disk image with QEMU and proves that the serial console reaches
# a kernel, systemd, and a login prompt. With --log-from it runs the same
# assertions against an existing log, so the assertion logic is testable on a
# host without QEMU.
#
# Contract (frozen):
#   tools/boot-check.sh --artifact <artifact.json> [--timeout 300] [--json]
#                       [--log-from <file>] [--qemu <binary>]
#                       [--firmware <OVMF_CODE.fd>]
#
# Two boot modes are selected by artifact.boot.mode:
#
#   kernel (default)  QEMU starts the kernel directly with -kernel/-initrd and
#                     the raw image as a virtio drive (P0-b behavior).
#   uefi              QEMU boots OVMF from pflash, which loads GRUB from the GPT
#                     ESP on artifact.boot.disk. The kernel, initrd, and cmdline
#                     live inside the disk and are not passed to QEMU.
#
# In UEFI mode artifact.boot.graphical=true selects the desktop image: QEMU
# additionally gets -vga virtio and three desktop assertions (display manager,
# Xorg, graphical target) follow the usual five. artifact.boot.memory_mb
# overrides QEMU -m in every mode (default 1024). boot.graphical is ignored in
# kernel mode, which keeps the P0-b assertion set at three.
#
# Artifact paths (boot.kernel, boot.initrd, boot.disk, images[].path) are
# resolved relative to the directory holding artifact.json. Boot-check writes
# <artifact dir>/boot.log and <artifact dir>/boot-evidence.json plus a temporary
# directory under $TMPDIR. In UEFI mode the OVMF VARS template is copied to a
# temporary file inside that $TMPDIR work directory (QEMU needs a writable copy)
# and deleted on exit; nothing is ever written to the caller's working
# directory. QEMU opens the target disk read-write because the cmdline mounts
# the root filesystem rw, so the disk must be writable by the user running
# boot-check. The host, network, and boot configuration are never modified; no
# sudo is used.
#
# A successful boot does not power itself off. In QEMU mode a monitor watches
# boot.log and stops QEMU as soon as every required assertion has matched (3 in
# kernel mode, 5 in UEFI mode, 8 in UEFI graphical mode), which is what lets a
# healthily booted VM finish before --timeout.
#
# Requires bash 3.2+ (macOS /bin/bash). Do not use bash 4 features
# (mapfile, associative arrays, wait -n, ...).

set -euo pipefail

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------

ARTIFACT_API_VERSION="sysemble/artifact/v1"
EVIDENCE_API_VERSION="sysemble/boot-evidence/v1"
DEFAULT_TIMEOUT=300

EXIT_PASS=0
EXIT_ASSERT=1
EXIT_USAGE=2
EXIT_QEMU=3
EXIT_TIMEOUT=4

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

ARTIFACT_ARG=""
TIMEOUT_SECONDS=$DEFAULT_TIMEOUT
JSON_OUTPUT=0
LOG_FROM=""
QEMU_OPT=""
FIRMWARE_OPT=""

ARTIFACT_ABS=""
ARTIFACT_DIR=""
JSON_BACKEND=""
TMP_DIR=""

ARCH_VALUE=""
BOOT_MODE="kernel"
GRAPHICAL_MODE=0
MEMORY_MB=1024
KERNEL_REL=""
INITRD_REL=""
CMDLINE_VALUE=""
RAW_IMAGE_REL=""
BOOT_DISK_REL=""

KERNEL_ABS=""
INITRD_ABS=""
RAW_IMAGE_ABS=""
BOOT_DISK_ABS=""

QEMU_LABEL=""
QEMU_BIN=""
MACHINE=""

FIRMWARE_CODE=""
FIRMWARE_VARS=""
VARS_TMP=""

LOG_PATH=""
LOG_EVIDENCE=""
EVIDENCE_PATH=""
LOG_HASH=""
ELAPSED=0

FIRMWARE_RESULT="fail"
FIRMWARE_DETAIL=""
GRUB_RESULT="fail"
GRUB_DETAIL=""
KERNEL_RESULT="fail"
KERNEL_DETAIL=""
SYSTEMD_RESULT="fail"
SYSTEMD_DETAIL=""
LOGIN_RESULT="fail"
LOGIN_DETAIL=""
DISPLAY_MANAGER_RESULT="fail"
DISPLAY_MANAGER_DETAIL=""
XORG_RESULT="fail"
XORG_DETAIL=""
GRAPHICAL_RESULT="fail"
GRAPHICAL_DETAIL=""

# Assertion records for the evidence JSON: id<0x1f>result<0x1f>detail per line.
# The unit separator is the same framing character the artifact parser uses, so
# assertion details can never be split by the shell or by IFS whitespace.
US=$'\x1f'
ASSERT_RECORDS=""
LOG_STATE="ok"

RESULT="fail"
TIMED_OUT=0
SUCCEEDED=0

QEMU_PID=""
MONITOR_PID=""
WATCHDOG_PID=""
CLEANED=0

# ---------------------------------------------------------------------------
# Logging / usage
# ---------------------------------------------------------------------------

err() {
  printf 'boot-check: error: %s\n' "$*" >&2
}

warn() {
  printf 'boot-check: warning: %s\n' "$*" >&2
}

# Human-readable progress goes to stderr when stdout is reserved for --json.
say() {
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    printf 'boot-check: %s\n' "$*" >&2
  else
    printf 'boot-check: %s\n' "$*"
  fi
}

IFS= read -r -d '' USAGE_TEXT <<'USAGE' || true
Sysemble boot-check (P0-b/P0-c/P0-d) - prove a built image boots to a login prompt

Usage:
  tools/boot-check.sh --artifact <artifact.json> [--timeout 300] [--json]
                      [--log-from <file>] [--qemu <binary>]
                      [--firmware <OVMF_CODE.fd>]

Options:
  --artifact <path>  artifact.json produced by builders/debian/build.sh
  --timeout <secs>   QEMU boot deadline in whole seconds (default: 300)
  --json             print only the evidence JSON on stdout; the human summary
                     goes to stderr
  --log-from <file>  offline mode: do not run QEMU, run the assertions against
                     this existing serial log
  --qemu <binary>    QEMU binary (default: qemu-system-<arch> from PATH)
  --firmware <path>  OVMF code image for boot.mode=uefi. Default: the first
                     readable path of
                       /usr/share/OVMF/OVMF_CODE_4M.fd
                       /usr/share/OVMF/OVMF_CODE.fd
                       /usr/share/edk2/ovmf/OVMF_CODE.fd
                     The matching VARS template is taken from the same
                     directory (OVMF_VARS_4M.fd / OVMF_VARS.fd).
  -h, --help         show this help and exit 0

Artifact fields used (relative to the artifact.json directory):
  apiVersion must be 'sysemble/artifact/v1'
  arch       must be 'x86_64' or 'aarch64'
  boot.mode  'kernel' (default when absent) or 'uefi'
  boot.memory_mb  QEMU -m value in MB: a positive JSON integer (default: 1024)
  boot.graphical  uefi only: true adds -vga virtio and the three desktop
                  assertions below; missing/false keeps the P0-c behavior
  boot.kernel / boot.initrd  required when boot.mode=kernel
  boot.disk  required when boot.mode=uefi: raw GPT disk image with the ESP
  boot.cmdline is passed to QEMU -append in kernel mode only
  images[]   must contain an entry with format 'raw' whose path exists

In kernel mode QEMU opens the raw image read-write (the cmdline mounts the root
filesystem rw); in UEFI mode it opens boot.disk read-write and pflash. Boot-check
writes boot.log/boot-evidence.json beside artifact.json, so the artifact
directory, the raw image, and boot.disk must be writable by the invoking user.

Assertions (all required):
  boot.firmware  (uefi only) serial log contains 'EFI v' or 'UEFI'
  boot.grub      (uefi only) serial log contains 'GRUB' or 'Booting'
  boot.kernel    serial log contains 'Linux version'
  boot.systemd   serial log contains 'systemd[1]' or 'Reached target'
  boot.login     serial log contains 'login:'
  boot.display_manager  (uefi + graphical) log contains 'lightdm', 'sddm', or
                        'gdm' (case-insensitive)
  boot.xorg             (uefi + graphical) log contains 'X.Org X Server' or
                        'Xorg'
  boot.graphical        (uefi + graphical) log contains 'Reached target
                        Graphical Interface' or 'graphical.target'

The required assertion count is therefore 3 in kernel mode, 5 in UEFI mode, and
8 in UEFI graphical mode. boot.graphical is ignored in kernel mode.

In QEMU mode every assertion must pass before --timeout; QEMU is stopped as soon
as they do. A timeout keeps the partial boot.log and reports result 'timeout'.
--log-from never launches QEMU or probes firmware, so UEFI assertions are
testable offline.

Exit codes:
  0  all assertions passed
  1  one or more assertions failed
  2  usage, file, JSON, or evidence I/O error
  3  QEMU or OVMF firmware is unavailable
  4  timed out waiting for the assertions

This script never changes the host, never uses sudo, and never needs network.
USAGE

usage() {
  printf '%s' "$USAGE_TEXT"
}

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
      --artifact)
        if [ "$#" -lt 2 ]; then
          err "--artifact requires a value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        ARTIFACT_ARG=$2
        shift 2
        ;;
      --artifact=*)
        ARTIFACT_ARG=${1#--artifact=}
        shift
        ;;
      --timeout)
        if [ "$#" -lt 2 ]; then
          err "--timeout requires a value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        TIMEOUT_SECONDS=$2
        shift 2
        ;;
      --timeout=*)
        TIMEOUT_SECONDS=${1#--timeout=}
        shift
        ;;
      --log-from)
        if [ "$#" -lt 2 ]; then
          err "--log-from requires a value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        if [ -z "$2" ]; then
          err "--log-from must not be empty"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        LOG_FROM=$2
        shift 2
        ;;
      --log-from=*)
        LOG_FROM=${1#--log-from=}
        if [ -z "$LOG_FROM" ]; then
          err "--log-from must not be empty"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        shift
        ;;
      --qemu)
        if [ "$#" -lt 2 ]; then
          err "--qemu requires a value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        if [ -z "$2" ]; then
          err "--qemu must not be empty"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        QEMU_OPT=$2
        shift 2
        ;;
      --qemu=*)
        QEMU_OPT=${1#--qemu=}
        if [ -z "$QEMU_OPT" ]; then
          err "--qemu must not be empty"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        shift
        ;;
      --firmware)
        if [ "$#" -lt 2 ]; then
          err "--firmware requires a value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        if [ -z "$2" ]; then
          err "--firmware must not be empty"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        FIRMWARE_OPT=$2
        shift 2
        ;;
      --firmware=*)
        FIRMWARE_OPT=${1#--firmware=}
        if [ -z "$FIRMWARE_OPT" ]; then
          err "--firmware must not be empty"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        shift
        ;;
      --json)
        JSON_OUTPUT=1
        shift
        ;;
      --)
        shift
        if [ "$#" -gt 0 ]; then
          err "unexpected argument: $1"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        ;;
      -*)
        err "unknown option: $1"
        usage >&2
        exit "$EXIT_USAGE"
        ;;
      *)
        err "unexpected argument: $1"
        usage >&2
        exit "$EXIT_USAGE"
        ;;
    esac
  done

  if [ -z "$ARTIFACT_ARG" ]; then
    err "--artifact is required"
    usage >&2
    exit "$EXIT_USAGE"
  fi

  case "$TIMEOUT_SECONDS" in
    '' | *[!0-9]*)
      err "--timeout must be a positive whole number of seconds (got '$TIMEOUT_SECONDS')"
      usage >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  if [ "$TIMEOUT_SECONDS" -lt 1 ]; then
    err "--timeout must be at least 1 second (got '$TIMEOUT_SECONDS')"
    usage >&2
    exit "$EXIT_USAGE"
  fi
  # Canonicalize so a value such as 0300 is a valid JSON number and a valid
  # shell integer in every later comparison.
  TIMEOUT_SECONDS=$((10#$TIMEOUT_SECONDS))
}

# ---------------------------------------------------------------------------
# QEMU availability
#
# An explicit --qemu is validated before the artifact is read. That keeps the
# "qemu is unavailable" contract observable even when PATH has no JSON parser.
# ---------------------------------------------------------------------------

check_explicit_qemu() {
  local found=""

  case "$QEMU_OPT" in
    */*)
      if [ -d "$QEMU_OPT" ] || [ ! -x "$QEMU_OPT" ]; then
        err "QEMU binary is not executable: $QEMU_OPT"
        exit "$EXIT_QEMU"
      fi
      ;;
    *)
      if ! found=$(command -v "$QEMU_OPT" 2>/dev/null); then
        err "QEMU binary not found on PATH: $QEMU_OPT"
        exit "$EXIT_QEMU"
      fi
      if [ -z "$found" ] || [ -d "$found" ] || [ ! -x "$found" ]; then
        err "QEMU binary is not executable: $QEMU_OPT"
        exit "$EXIT_QEMU"
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup() {
  if [ "$CLEANED" -eq 1 ]; then
    return 0
  fi
  CLEANED=1

  if [ -n "$MONITOR_PID" ]; then
    kill -TERM "$MONITOR_PID" 2>/dev/null || true
  fi
  if [ -n "$WATCHDOG_PID" ]; then
    kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
  fi
  if [ -n "$QEMU_PID" ]; then
    kill -TERM "$QEMU_PID" 2>/dev/null || true
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    case "$TMP_DIR" in
      */sysemble-boot.*)
        rm -rf "$TMP_DIR" 2>/dev/null || true
        ;;
    esac
  fi
  # Only ever delete the OVMF VARS copy this run created inside its own
  # $TMPDIR work directory (mktemp template, checked again here). The
  # directory itself is removed by the TMP_DIR branch above.
  if [ -n "$VARS_TMP" ]; then
    case "$VARS_TMP" in
      */sysemble-boot.*/ovmf-vars.*)
        rm -f "$VARS_TMP" 2>/dev/null || true
        ;;
    esac
  fi
  return 0
}

# ---------------------------------------------------------------------------
# JSON extraction
#
# Both backends emit the same record stream. Fields are separated by the ASCII
# unit separator (0x1f), a non-whitespace delimiter, so empty fields survive
# `read`. Control characters are replaced with spaces so artifact values cannot
# break the record framing. Nothing is eval'd; the shell only reads records.
#
#   <key>0x1f<type>0x1f<value>
#   images0x1farray0x1f
#   image0x1fobject0x1fformat-kind0x1fformat0x1fpath-kind0x1fpath
# ---------------------------------------------------------------------------

IFS= read -r -d '' JQ_EXTRACT <<'JQ' || true
(if type != "object" then error("artifact must be a JSON object") else . end) as $root |
def has_path($p):
  if ($p | length) == 0 then true
  else
    ($p[0]) as $head |
    if (type == "object") and (has($head)) then (.[$head] | has_path($p[1:]))
    else false end
  end;
def kind:
  if . == null then "null"
  elif type == "boolean" then "boolean"
  elif type == "number" then "number"
  elif type == "string" then "string"
  elif type == "array" then "array"
  elif type == "object" then "object"
  else "unknown" end;
def clean: tostring | gsub("[\u0000-\u001f\u007f]"; " ");
def scalar($k; $p):
  if ($root | has_path($p)) then
    ($root | getpath($p)) as $v |
    "\($k)\u001f\($v|kind)\u001f\($v|clean)"
  else "\($k)\u001fmissing\u001f" end;
def image_records:
  if ($root | has_path(["images"])) then
    ($root.images) as $v |
    if ($v|type) == "array" then
      "images\u001farray\u001f",
      ($v[] | . as $img |
        "image\u001f" +
        (if ($img|type) == "object" then
          "object\u001f" +
          (($img.format // null)|kind) + "\u001f" + (($img.format // null)|clean) + "\u001f" +
          (($img.path // null)|kind) + "\u001f" + (($img.path // null)|clean)
        else
          ($img|kind) + "\u001fmissing\u001f\u001fmissing\u001f"
        end))
    else
      "images\u001f\($v|kind)\u001f\($v|clean)"
    end
  else "images\u001fmissing\u001f" end;
scalar("apiVersion"; ["apiVersion"]),
scalar("arch"; ["arch"]),
scalar("boot.mode"; ["boot", "mode"]),
scalar("boot.graphical"; ["boot", "graphical"]),
scalar("boot.memory_mb"; ["boot", "memory_mb"]),
scalar("boot.disk"; ["boot", "disk"]),
scalar("boot.kernel"; ["boot", "kernel"]),
scalar("boot.initrd"; ["boot", "initrd"]),
scalar("boot.cmdline"; ["boot", "cmdline"]),
image_records
JQ

IFS= read -r -d '' PY_EXTRACT <<'PY' || true
import json
import re
import sys

MISSING = object()
CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def reject_constant(value):
    raise ValueError("invalid JSON constant: %s" % value)


def main(argv):
    path = argv[1]
    try:
        with open(path, "r", encoding="utf-8") as fh:
            root = json.load(fh, parse_constant=reject_constant)
    except OSError as exc:
        sys.stderr.write("cannot read artifact: %s\n" % exc)
        return 3
    except ValueError as exc:
        sys.stderr.write("invalid JSON: %s\n" % exc)
        return 3
    if not isinstance(root, dict):
        sys.stderr.write("artifact must be a JSON object\n")
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
        return CONTROL.sub(" ", value)

    def emit(key, type_name, value):
        sys.stdout.write("%s\x1f%s\x1f%s\n" % (key, type_name, clean(value)))

    def scalar(key, keys):
        value = get(keys)
        if value is MISSING:
            emit(key, "missing", "")
        else:
            emit(key, kind(value), fmt(value))

    scalar("apiVersion", ["apiVersion"])
    scalar("arch", ["arch"])
    scalar("boot.mode", ["boot", "mode"])
    scalar("boot.graphical", ["boot", "graphical"])
    scalar("boot.memory_mb", ["boot", "memory_mb"])
    scalar("boot.disk", ["boot", "disk"])
    scalar("boot.kernel", ["boot", "kernel"])
    scalar("boot.initrd", ["boot", "initrd"])
    scalar("boot.cmdline", ["boot", "cmdline"])

    images = get(["images"])
    if images is MISSING:
        emit("images", "missing", "")
    elif isinstance(images, list):
        emit("images", "array", "")
        for image in images:
            if isinstance(image, dict):
                fmt_value = image.get("format", MISSING)
                path_value = image.get("path", MISSING)
                sys.stdout.write(
                    "image\x1fobject\x1f%s\x1f%s\x1f%s\x1f%s\n"
                    % (
                        kind(fmt_value),
                        clean(fmt(fmt_value)),
                        kind(path_value),
                        clean(fmt(path_value)),
                    )
                )
            else:
                sys.stdout.write(
                    "image\x1f%s\x1fmissing\x1f\x1fmissing\x1f\n" % kind(image)
                )
    else:
        emit("images", kind(images), fmt(images))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

detect_json_backend() {
  if command -v jq >/dev/null 2>&1; then
    JSON_BACKEND=jq
  elif command -v python3 >/dev/null 2>&1; then
    JSON_BACKEND=python3
  else
    err "no JSON parser found; install jq or python3"
    exit "$EXIT_USAGE"
  fi
}

# ---------------------------------------------------------------------------
# Artifact discovery / validation
# ---------------------------------------------------------------------------

resolve_artifact() {
  if [ ! -e "$ARTIFACT_ARG" ]; then
    err "artifact not found: $ARTIFACT_ARG"
    exit "$EXIT_USAGE"
  fi
  if [ ! -f "$ARTIFACT_ARG" ]; then
    err "artifact is not a regular file: $ARTIFACT_ARG"
    exit "$EXIT_USAGE"
  fi
  if [ ! -r "$ARTIFACT_ARG" ]; then
    err "artifact is not readable: $ARTIFACT_ARG"
    exit "$EXIT_USAGE"
  fi

  case "$ARTIFACT_ARG" in
    */*)
      ARTIFACT_DIR=${ARTIFACT_ARG%/*}
      ARTIFACT_BASE=${ARTIFACT_ARG##*/}
      ;;
    *)
      ARTIFACT_DIR=.
      ARTIFACT_BASE=$ARTIFACT_ARG
      ;;
  esac
  if [ -z "$ARTIFACT_DIR" ]; then
    ARTIFACT_DIR=/
  fi
  if ! ARTIFACT_DIR=$(cd "$ARTIFACT_DIR" 2>/dev/null && pwd -P); then
    err "cannot resolve artifact directory for: $ARTIFACT_ARG"
    exit "$EXIT_USAGE"
  fi
  if [ "$ARTIFACT_DIR" = "/" ]; then
    ARTIFACT_ABS="/$ARTIFACT_BASE"
  else
    ARTIFACT_ABS="$ARTIFACT_DIR/$ARTIFACT_BASE"
  fi
}

parse_artifact() {
  local parse_err="$TMP_DIR/parse.err"
  local records=""
  local key="" field1="" field2="" field3="" field4="" field5=""
  local api_type="missing" api_value=""
  local arch_type="missing" arch_value=""
  local mode_type="missing" mode_value=""
  local graphical_type="missing" graphical_value=""
  local memory_type="missing" memory_value=""
  local disk_type="missing" disk_value=""
  local kernel_type="missing" kernel_value=""
  local initrd_type="missing" initrd_value=""
  local cmdline_type="missing" cmdline_value=""
  local images_kind="missing"
  local malformed_image=0
  local format_type="" format_value="" path_type="" path_value=""

  if [ "$JSON_BACKEND" = "jq" ]; then
    if ! records=$(jq -r "$JQ_EXTRACT" "$ARTIFACT_ABS" 2>"$parse_err"); then
      err "artifact is not valid JSON (or is not a JSON object): $ARTIFACT_ARG"
      if [ -s "$parse_err" ]; then
        cat "$parse_err" >&2
      fi
      exit "$EXIT_USAGE"
    fi
  else
    if ! records=$(python3 -c "$PY_EXTRACT" "$ARTIFACT_ABS" 2>"$parse_err"); then
      err "artifact is not valid JSON (or is not a JSON object): $ARTIFACT_ARG"
      if [ -s "$parse_err" ]; then
        cat "$parse_err" >&2
      fi
      exit "$EXIT_USAGE"
    fi
  fi

  while IFS=$'\x1f' read -r key field1 field2 field3 field4 field5; do
    case "$key" in
      apiVersion)
        api_type=$field1
        api_value=$field2
        ;;
      arch)
        arch_type=$field1
        arch_value=$field2
        ;;
      boot.mode)
        mode_type=$field1
        mode_value=$field2
        ;;
      boot.graphical)
        graphical_type=$field1
        graphical_value=$field2
        ;;
      boot.memory_mb)
        memory_type=$field1
        memory_value=$field2
        ;;
      boot.disk)
        disk_type=$field1
        disk_value=$field2
        ;;
      boot.kernel)
        kernel_type=$field1
        kernel_value=$field2
        ;;
      boot.initrd)
        initrd_type=$field1
        initrd_value=$field2
        ;;
      boot.cmdline)
        cmdline_type=$field1
        cmdline_value=$field2
        ;;
      images)
        images_kind=$field1
        ;;
      image)
        if [ "$field1" != "object" ]; then
          malformed_image=1
        else
          format_type=$field2
          format_value=$field3
          path_type=$field4
          path_value=$field5
          if [ -z "$RAW_IMAGE_REL" ] &&
            [ "$format_type" = "string" ] &&
            [ "$format_value" = "raw" ] &&
            [ "$path_type" = "string" ] &&
            [ -n "$path_value" ]; then
            RAW_IMAGE_REL=$path_value
          fi
        fi
        ;;
      *)
        ;;
    esac
  done <<EOF
$records
EOF

  if [ "$api_type" != "string" ]; then
    err "artifact field apiVersion is missing or not a string"
    exit "$EXIT_USAGE"
  fi
  if [ "$api_value" != "$ARTIFACT_API_VERSION" ]; then
    err "artifact apiVersion must be '$ARTIFACT_API_VERSION' (got '$api_value')"
    exit "$EXIT_USAGE"
  fi

  if [ "$arch_type" != "string" ]; then
    err "artifact field arch is missing or not a string"
    exit "$EXIT_USAGE"
  fi
  case "$arch_value" in
    x86_64 | aarch64)
      ARCH_VALUE=$arch_value
      ;;
    *)
      err "artifact arch must be 'x86_64' or 'aarch64' (got '$arch_value')"
      exit "$EXIT_USAGE"
      ;;
  esac

  # boot.mode selects the QEMU boot path. Absent means "kernel", which keeps
  # P0-b artifacts (and their evidence) byte-compatible.
  case "$mode_type" in
    missing)
      BOOT_MODE=kernel
      ;;
    string)
      case "$mode_value" in
        kernel | uefi)
          BOOT_MODE=$mode_value
          ;;
        *)
          err "artifact boot.mode must be 'kernel' or 'uefi' (got '$mode_value')"
          exit "$EXIT_USAGE"
          ;;
      esac
      ;;
    *)
      err "artifact field boot.mode must be a string (got '$mode_type')"
      exit "$EXIT_USAGE"
      ;;
  esac

  # boot.memory_mb sizes QEMU's -m in every boot mode. Absent keeps the P0-b/c
  # default. Only a positive JSON integer is accepted: QEMU also understands
  # suffixes ('2G') and negative values, so anything else must not leak through.
  case "$memory_type" in
    missing)
      MEMORY_MB=1024
      ;;
    number)
      case "$memory_value" in
        '' | 0 | *[!0-9]*)
          err "artifact field boot.memory_mb must be a positive integer (got '$memory_value')"
          exit "$EXIT_USAGE"
          ;;
      esac
      MEMORY_MB=$memory_value
      ;;
    *)
      err "artifact field boot.memory_mb must be a number (got '$memory_type')"
      exit "$EXIT_USAGE"
      ;;
  esac

  # boot.graphical selects the desktop assertion set. Absent/false is the P0-c
  # behavior. The field is validated in every mode but only acted on in UEFI
  # mode, so a kernel-mode artifact that carries it still runs 3 assertions.
  case "$graphical_type" in
    missing)
      GRAPHICAL_MODE=0
      ;;
    boolean)
      case "$graphical_value" in
        true)
          GRAPHICAL_MODE=1
          ;;
        false)
          GRAPHICAL_MODE=0
          ;;
        *)
          err "artifact field boot.graphical must be a boolean (got '$graphical_value')"
          exit "$EXIT_USAGE"
          ;;
      esac
      ;;
    *)
      err "artifact field boot.graphical must be a boolean (got '$graphical_type')"
      exit "$EXIT_USAGE"
      ;;
  esac

  # OVMF is x86_64-only in P0-c; an aarch64 UEFI artifact would silently get
  # the wrong QEMU arguments, so reject it instead of booting something else.
  if [ "$BOOT_MODE" = "uefi" ] && [ "$ARCH_VALUE" != "x86_64" ]; then
    err "artifact boot.mode=uefi is only supported for arch x86_64 (got '$ARCH_VALUE')"
    exit "$EXIT_USAGE"
  fi

  if [ "$BOOT_MODE" = "kernel" ]; then
    if [ "$kernel_type" != "string" ] || [ -z "$kernel_value" ]; then
      err "artifact field boot.kernel is missing, empty, or not a string"
      exit "$EXIT_USAGE"
    fi
    KERNEL_REL=$kernel_value

    if [ "$initrd_type" != "string" ] || [ -z "$initrd_value" ]; then
      err "artifact field boot.initrd is missing, empty, or not a string"
      exit "$EXIT_USAGE"
    fi
    INITRD_REL=$initrd_value

    if [ "$cmdline_type" != "string" ]; then
      err "artifact field boot.cmdline is missing or not a string"
      exit "$EXIT_USAGE"
    fi
    CMDLINE_VALUE=$cmdline_value
  else
    # UEFI boots through firmware + GRUB, so the kernel/initrd/cmdline inside
    # boot are informational and are not handed to QEMU.
    if [ "$disk_type" != "string" ] || [ -z "$disk_value" ]; then
      err "artifact field boot.disk is required when boot.mode=uefi"
      exit "$EXIT_USAGE"
    fi
    BOOT_DISK_REL=$disk_value
  fi

  if [ "$images_kind" = "missing" ]; then
    err "artifact field images is required"
    exit "$EXIT_USAGE"
  fi
  if [ "$images_kind" != "array" ]; then
    err "artifact field images must be an array (got '$images_kind')"
    exit "$EXIT_USAGE"
  fi
  if [ "$malformed_image" -eq 1 ]; then
    err "artifact images[] contains an entry that is not an object"
    exit "$EXIT_USAGE"
  fi
  if [ -z "$RAW_IMAGE_REL" ]; then
    err "artifact images[] must contain a raw image with a non-empty path"
    exit "$EXIT_USAGE"
  fi

  if [ "$BOOT_MODE" = "kernel" ]; then
    resolve_artifact_file "boot.kernel" "$KERNEL_REL"
    KERNEL_ABS=$RESOLVED_FILE
    resolve_artifact_file "boot.initrd" "$INITRD_REL"
    INITRD_ABS=$RESOLVED_FILE
  else
    resolve_artifact_file "boot.disk" "$BOOT_DISK_REL"
    BOOT_DISK_ABS=$RESOLVED_FILE
  fi
  resolve_artifact_file "images[].path (raw)" "$RAW_IMAGE_REL"
  RAW_IMAGE_ABS=$RESOLVED_FILE
}

# Resolve a manifest path relative to the artifact directory, then require a
# readable regular file. Empty files are accepted: this is a presence check, not
# a content check (tests rely on that).
RESOLVED_FILE=""
resolve_artifact_file() {
  local label=$1
  local rel=$2
  local abs=""

  case "$rel" in
    /*)
      err "artifact $label must be relative to the artifact directory: $rel"
      exit "$EXIT_USAGE"
      ;;
  esac

  abs="$ARTIFACT_DIR/$rel"
  if [ ! -f "$abs" ]; then
    err "artifact $label does not exist or is not a regular file: $rel (resolved: $abs)"
    exit "$EXIT_USAGE"
  fi
  if [ ! -r "$abs" ]; then
    err "artifact $label is not readable: $rel (resolved: $abs)"
    exit "$EXIT_USAGE"
  fi
  RESOLVED_FILE=$abs
}

# ---------------------------------------------------------------------------
# Log assertions
# ---------------------------------------------------------------------------

log_has() {
  [ -f "$LOG_PATH" ] || return 1
  [ -s "$LOG_PATH" ] || return 1
  grep -Fq "$1" "$LOG_PATH" 2>/dev/null
}

# Display managers mix 'lightdm' and 'LightDM' in their log lines, so the
# boot.display_manager assertion matches case-insensitively. The Xorg and
# graphical-target patterns stay exact: their canonical spellings are frozen by
# docs/plan/P0-d1-workplan.md section 3.
log_has_ci() {
  [ -f "$LOG_PATH" ] || return 1
  [ -s "$LOG_PATH" ] || return 1
  grep -Fiq "$1" "$LOG_PATH" 2>/dev/null
}

# The assertion set depends on the boot mode: UEFI adds firmware and GRUB
# before the kernel/systemd/login triple; UEFI graphical mode adds the desktop
# triple after it. Both all_assertions_pass (the QEMU early-stop monitor) and
# evaluate_assertions (the evidence writer) use the same predicates so a boot
# can never be "proven" by one and reported by the other.
all_assertions_pass() {
  if [ "$BOOT_MODE" = "uefi" ]; then
    log_has 'EFI v' || log_has 'UEFI' || return 1
    log_has 'GRUB' || log_has 'Booting' || return 1
  fi
  log_has 'Linux version' || return 1
  if ! log_has 'systemd[1]' && ! log_has 'Reached target'; then
    return 1
  fi
  log_has 'login:' || return 1
  if [ "$BOOT_MODE" = "uefi" ] && [ "$GRAPHICAL_MODE" -eq 1 ]; then
    log_has_ci 'lightdm' || log_has_ci 'sddm' || log_has_ci 'gdm' || return 1
    log_has 'X.Org X Server' || log_has 'Xorg' || return 1
    log_has 'Reached target Graphical Interface' || log_has 'graphical.target' || return 1
  fi
  return 0
}

log_state_of() {
  if [ ! -f "$LOG_PATH" ]; then
    printf 'missing'
  elif [ ! -s "$LOG_PATH" ]; then
    printf 'empty'
  else
    printf 'ok'
  fi
}

# Compose the detail for a failed assertion. $1 is the expectation phrase, e.g.
# 'no `login:`'; the caller passes the exact wording used by P0-b.
failure_detail() {
  local expectation=$1

  if [ "$LOG_STATE" = "missing" ]; then
    printf 'log file is missing'
    return 0
  fi
  if [ "$LOG_STATE" = "empty" ]; then
    printf 'log is empty'
    return 0
  fi
  if [ "$TIMED_OUT" -eq 1 ]; then
    printf '%s within %ss' "$expectation" "$TIMEOUT_SECONDS"
  else
    printf '%s in log' "$expectation"
  fi
}

# evaluate_assertion <result-var> <detail-var> <fail-phrase> <pattern>...
#
# Pass when any pattern is present. The detail lists every pattern that matched
# so a log carrying all alternatives is visible in the evidence. A missing or
# empty log is an assertion failure, never an I/O error.
evaluate_assertion() {
  evaluate_assertion_with log_has "$@"
}

# Same contract as evaluate_assertion, with case-insensitive patterns.
evaluate_assertion_ci() {
  evaluate_assertion_with log_has_ci "$@"
}

evaluate_assertion_with() {
  local matcher=$1
  local result_var=$2
  local detail_var=$3
  local fail_phrase=$4
  local pattern=""
  local matched=""
  local result="fail"
  local detail=""

  shift 4
  for pattern in "$@"; do
    if "$matcher" "$pattern"; then
      if [ -z "$matched" ]; then
        matched="\`$pattern\`"
      else
        matched="$matched and \`$pattern\`"
      fi
    fi
  done

  if [ -n "$matched" ]; then
    result=pass
    detail="matched $matched"
  else
    detail=$(failure_detail "$fail_phrase")
  fi

  printf -v "$result_var" '%s' "$result"
  printf -v "$detail_var" '%s' "$detail"
}

# Append one record for the evidence JSON.
record_assertion() {
  ASSERT_RECORDS="${ASSERT_RECORDS}${1}${US}${2}${US}${3}
"
}

# Set the result/detail variables for every assertion that applies to the
# current boot mode, then snapshot them as evidence records in report order.
# kernel mode runs 3 assertions; uefi mode runs 5; uefi + graphical runs 8.
evaluate_assertions() {
  LOG_STATE=$(log_state_of)
  ASSERT_RECORDS=""

  if [ "$BOOT_MODE" = "uefi" ]; then
    evaluate_assertion FIRMWARE_RESULT FIRMWARE_DETAIL \
      'no `EFI v` or `UEFI`' 'EFI v' 'UEFI'
    record_assertion boot.firmware "$FIRMWARE_RESULT" "$FIRMWARE_DETAIL"

    evaluate_assertion GRUB_RESULT GRUB_DETAIL \
      'no `GRUB` or `Booting`' 'GRUB' 'Booting'
    record_assertion boot.grub "$GRUB_RESULT" "$GRUB_DETAIL"
  fi

  evaluate_assertion KERNEL_RESULT KERNEL_DETAIL \
    'no `Linux version`' 'Linux version'
  record_assertion boot.kernel "$KERNEL_RESULT" "$KERNEL_DETAIL"

  evaluate_assertion SYSTEMD_RESULT SYSTEMD_DETAIL \
    'no `systemd[1]` or `Reached target`' 'systemd[1]' 'Reached target'
  record_assertion boot.systemd "$SYSTEMD_RESULT" "$SYSTEMD_DETAIL"

  evaluate_assertion LOGIN_RESULT LOGIN_DETAIL \
    'no `login:`' 'login:'
  record_assertion boot.login "$LOGIN_RESULT" "$LOGIN_DETAIL"

  if [ "$BOOT_MODE" = "uefi" ] && [ "$GRAPHICAL_MODE" -eq 1 ]; then
    evaluate_assertion_ci DISPLAY_MANAGER_RESULT DISPLAY_MANAGER_DETAIL \
      'no `lightdm`, `sddm`, or `gdm`' 'lightdm' 'sddm' 'gdm'
    record_assertion boot.display_manager "$DISPLAY_MANAGER_RESULT" "$DISPLAY_MANAGER_DETAIL"

    evaluate_assertion XORG_RESULT XORG_DETAIL \
      'no `X.Org X Server` or `Xorg`' 'X.Org X Server' 'Xorg'
    record_assertion boot.xorg "$XORG_RESULT" "$XORG_DETAIL"

    evaluate_assertion GRAPHICAL_RESULT GRAPHICAL_DETAIL \
      'no `Reached target Graphical Interface` or `graphical.target`' \
      'Reached target Graphical Interface' 'graphical.target'
    record_assertion boot.graphical "$GRAPHICAL_RESULT" "$GRAPHICAL_DETAIL"
  fi
}

determine_result() {
  if [ "$TIMED_OUT" -eq 1 ] && [ "$SUCCEEDED" -eq 0 ]; then
    RESULT=timeout
    return 0
  fi
  if [ "$BOOT_MODE" = "uefi" ]; then
    if [ "$FIRMWARE_RESULT" != "pass" ] || [ "$GRUB_RESULT" != "pass" ]; then
      RESULT=fail
      return 0
    fi
  fi
  if [ "$KERNEL_RESULT" != "pass" ] ||
    [ "$SYSTEMD_RESULT" != "pass" ] ||
    [ "$LOGIN_RESULT" != "pass" ]; then
    RESULT=fail
    return 0
  fi
  if [ "$BOOT_MODE" = "uefi" ] && [ "$GRAPHICAL_MODE" -eq 1 ]; then
    if [ "$DISPLAY_MANAGER_RESULT" != "pass" ] ||
      [ "$XORG_RESULT" != "pass" ] ||
      [ "$GRAPHICAL_RESULT" != "pass" ]; then
      RESULT=fail
      return 0
    fi
  fi
  RESULT=pass
}

# ---------------------------------------------------------------------------
# QEMU execution
# ---------------------------------------------------------------------------

sha256_file() {
  local out=""

  # Hash via stdin so filenames containing spaces/backslashes cannot change the
  # output format (GNU coreutils escapes such filenames).
  if command -v sha256sum >/dev/null 2>&1; then
    if out=$(sha256sum <"$1" 2>/dev/null); then
      printf '%s\n' "${out%% *}"
      return 0
    fi
  fi
  if command -v shasum >/dev/null 2>&1; then
    if out=$(shasum -a 256 <"$1" 2>/dev/null); then
      printf '%s\n' "${out%% *}"
      return 0
    fi
  fi
  if command -v openssl >/dev/null 2>&1; then
    if out=$(openssl dgst -sha256 <"$1" 2>/dev/null); then
      printf '%s\n' "${out##* }"
      return 0
    fi
  fi
  return 1
}

select_qemu_for_run() {
  local found=""

  case "$ARCH_VALUE" in
    x86_64)
      QEMU_LABEL=qemu-system-x86_64
      MACHINE=q35
      ;;
    aarch64)
      QEMU_LABEL=qemu-system-aarch64
      MACHINE=virt
      ;;
  esac

  if [ -n "$QEMU_OPT" ]; then
    QEMU_LABEL=$QEMU_OPT
    case "$QEMU_OPT" in
      */*)
        QEMU_BIN=$QEMU_OPT
        ;;
      *)
        if ! found=$(command -v "$QEMU_OPT" 2>/dev/null); then
          err "QEMU binary not found on PATH: $QEMU_OPT"
          exit "$EXIT_QEMU"
        fi
        if [ -z "$found" ] || [ -d "$found" ] || [ ! -x "$found" ]; then
          err "QEMU binary is not executable: $QEMU_OPT"
          exit "$EXIT_QEMU"
        fi
        QEMU_BIN=$found
        ;;
    esac
    return 0
  fi

  if ! found=$(command -v "$QEMU_LABEL" 2>/dev/null); then
    err "$QEMU_LABEL not found on PATH; install QEMU or pass --qemu <binary>"
    exit "$EXIT_QEMU"
  fi
  if [ -z "$found" ] || [ -d "$found" ] || [ ! -x "$found" ]; then
    err "$QEMU_LABEL is not executable; pass --qemu <binary>"
    exit "$EXIT_QEMU"
  fi
  QEMU_BIN=$found
}

# ---------------------------------------------------------------------------
# OVMF firmware (boot.mode=uefi)
# ---------------------------------------------------------------------------

# Absolute path without requiring the file to exist. Returns 1 when the parent
# directory cannot be resolved.
absolutize_path() {
  local path=$1
  local dir=""
  local base=""

  case "$path" in
    /*)
      printf '%s' "$path"
      ;;
    *)
      dir=${path%/*}
      base=${path##*/}
      if [ "$dir" = "$path" ]; then
        dir=.
      fi
      if ! dir=$(cd "$dir" 2>/dev/null && pwd -P); then
        return 1
      fi
      printf '%s/%s' "$dir" "$base"
      ;;
  esac
}

# Probe order is part of the P0-c contract; --firmware always wins.
probe_firmware() {
  local candidate=""

  for candidate in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    if [ -f "$candidate" ] && [ -r "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# OVMF ships a read-only CODE image plus a writable VARS template. QEMU's
# pflash drive must be writable, so the template is copied into boot-check's
# own $TMPDIR work directory (removed by cleanup(), also on failure/timeout) and
# never into the artifact directory or the caller's working directory. Missing
# firmware is exit 3, the same class as a missing QEMU.
resolve_firmware() {
  local code_dir=""
  local code_base=""
  local vars_base=""
  local candidate=""
  local resolved=""

  if [ -n "$FIRMWARE_OPT" ]; then
    if ! resolved=$(absolutize_path "$FIRMWARE_OPT"); then
      err "cannot resolve --firmware path: $FIRMWARE_OPT"
      exit "$EXIT_QEMU"
    fi
    if [ ! -f "$resolved" ] || [ ! -r "$resolved" ]; then
      err "OVMF firmware not found or not readable: $FIRMWARE_OPT"
      err "hint: install OVMF (e.g. apt-get install ovmf) or pass --firmware <OVMF_CODE.fd>"
      exit "$EXIT_QEMU"
    fi
    FIRMWARE_CODE=$resolved
  else
    if ! FIRMWARE_CODE=$(probe_firmware); then
      err "no OVMF firmware found; boot.mode=uefi needs a UEFI code image"
      err "looked for: /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd"
      err "hint: install OVMF (e.g. apt-get install ovmf) or pass --firmware <OVMF_CODE.fd>"
      exit "$EXIT_QEMU"
    fi
  fi

  code_dir=${FIRMWARE_CODE%/*}
  code_base=${FIRMWARE_CODE##*/}
  case "$code_base" in
    *CODE_4M.fd) vars_base=${code_base%CODE_4M.fd}VARS_4M.fd ;;
    *CODE.fd) vars_base=${code_base%CODE.fd}VARS.fd ;;
    *CODE_4M) vars_base=${code_base%CODE_4M}VARS_4M ;;
    *CODE) vars_base=${code_base%CODE}VARS ;;
    *) vars_base="" ;;
  esac

  # Prefer the name derived from the code image, then the two conventional
  # template names in the same directory.
  for candidate in "$vars_base" OVMF_VARS_4M.fd OVMF_VARS.fd; do
    if [ -n "$candidate" ] && [ -f "$code_dir/$candidate" ] && [ -r "$code_dir/$candidate" ]; then
      FIRMWARE_VARS="$code_dir/$candidate"
      break
    fi
  done

  if [ -z "$FIRMWARE_VARS" ]; then
    err "cannot find an OVMF VARS template next to $FIRMWARE_CODE"
    err "expected ${vars_base:-OVMF_VARS_4M.fd} or OVMF_VARS.fd in ${code_dir:-/}"
    exit "$EXIT_QEMU"
  fi

  case "$FIRMWARE_CODE" in
    *,*)
      err "firmware code path contains a comma, which cannot be expressed in QEMU -drive: $FIRMWARE_CODE"
      exit "$EXIT_USAGE"
      ;;
  esac
  case "$FIRMWARE_VARS" in
    *,*)
      err "firmware VARS path contains a comma, which cannot be expressed in QEMU -drive: $FIRMWARE_VARS"
      exit "$EXIT_USAGE"
      ;;
  esac

  if ! VARS_TMP=$(mktemp "$TMP_DIR/ovmf-vars.XXXXXX" 2>/dev/null); then
    err "cannot create a temporary OVMF VARS file in: $TMP_DIR"
    exit "$EXIT_USAGE"
  fi
  case "$VARS_TMP" in
    *,*)
      err "temporary directory path contains a comma, which cannot be expressed in QEMU -drive: $TMP_DIR"
      exit "$EXIT_USAGE"
      ;;
  esac
  if ! cp "$FIRMWARE_VARS" "$VARS_TMP" 2>/dev/null; then
    err "cannot copy OVMF VARS template: $FIRMWARE_VARS"
    rm -f "$VARS_TMP" 2>/dev/null || true
    VARS_TMP=""
    exit "$EXIT_USAGE"
  fi

  say "firmware: $FIRMWARE_CODE"
  say "firmware vars: $FIRMWARE_VARS (temporary copy in $TMP_DIR)"
}

# QEMU opens the boot disk read-write (the guest mounts the root filesystem rw),
# so a root-owned image from a sudo build cannot boot. Fail early with an
# actionable diagnostic instead of letting QEMU emit a permission error that
# would look like a boot assertion failure.
require_writable_disk() {
  local label=$1
  local rel=$2
  local abs=$3

  case "$rel" in
    *,*)
      err "$label path contains a comma, which cannot be expressed in QEMU -drive: $rel"
      exit "$EXIT_USAGE"
      ;;
  esac
  if [ ! -w "$abs" ]; then
    err "$label is not writable by this user: $abs"
    err "hint: run boot-check as the user that owns the build output, or chown the output directory"
    exit "$EXIT_USAGE"
  fi
}

run_qemu() {
  local qemu_args=()
  local qemu_status=0
  local done_flag=""

  select_qemu_for_run

  if [ ! -w "$ARTIFACT_DIR" ]; then
    err "artifact directory is not writable: $ARTIFACT_DIR"
    err "hint: run boot-check as the user that owns the build output, or chown/chmod the output directory"
    exit "$EXIT_USAGE"
  fi

  if [ "$BOOT_MODE" = "uefi" ]; then
    resolve_firmware
    require_writable_disk "boot.disk" "$BOOT_DISK_REL" "$BOOT_DISK_ABS"
  else
    require_writable_disk "raw image" "$RAW_IMAGE_REL" "$RAW_IMAGE_ABS"
  fi

  LOG_PATH="$ARTIFACT_DIR/boot.log"
  LOG_EVIDENCE="boot.log"
  EVIDENCE_PATH="$ARTIFACT_DIR/boot-evidence.json"
  done_flag="$TMP_DIR/done.flag"

  if ! : >"$LOG_PATH" 2>/dev/null; then
    err "cannot write boot log: $LOG_PATH"
    exit "$EXIT_USAGE"
  fi

  if [ "$BOOT_MODE" = "uefi" ]; then
    # Contract sequence: firmware CODE (read-only), writable VARS copy, then the
    # partitioned disk as a virtio drive. GRUB loads the kernel from the ESP.
    # Graphical mode inserts -vga virtio before the drives; serial stays the only
    # console (-nographic), so the guest's virtio-gpu is exercised by Xorg
    # without opening a host window.
    qemu_args=(
      -machine q35
      -m "$MEMORY_MB"
      -smp 2
      -nographic
      -no-reboot
    )
    if [ "$GRAPHICAL_MODE" -eq 1 ]; then
      qemu_args+=(-vga virtio)
    fi
    qemu_args+=(
      -drive "if=pflash,format=raw,readonly=on,file=$FIRMWARE_CODE"
      -drive "if=pflash,format=raw,file=$VARS_TMP"
      -drive "file=$BOOT_DISK_ABS,format=raw,if=virtio"
    )
    say "launching $QEMU_LABEL (uefi/OVMF, -machine q35, timeout ${TIMEOUT_SECONDS}s)"
  else
    qemu_args=(
      -machine "$MACHINE"
      -m "$MEMORY_MB"
      -smp 2
      -nographic
      -no-reboot
      -kernel "$KERNEL_ABS"
      -initrd "$INITRD_ABS"
      -append "$CMDLINE_VALUE"
      -drive "file=$RAW_IMAGE_ABS,format=raw,if=virtio"
    )
    say "launching $QEMU_LABEL (-machine $MACHINE, timeout ${TIMEOUT_SECONDS}s)"
  fi
  say "serial log: $LOG_PATH"

  SECONDS=0
  "$QEMU_BIN" "${qemu_args[@]}" </dev/null >"$LOG_PATH" 2>&1 &
  QEMU_PID=$!

  # Stop QEMU as soon as the boot is proven; a booted VM never exits by itself.
  (
    while :; do
      if all_assertions_pass; then
        : >"$TMP_DIR/success.flag"
        kill -TERM "$QEMU_PID" 2>/dev/null || true
        sleep 2
        # The parent sets done.flag as soon as wait(2) reaps QEMU. Do not risk
        # sending KILL to a recycled PID in the meantime.
        if [ -f "$done_flag" ]; then
          exit 0
        fi
        kill -KILL "$QEMU_PID" 2>/dev/null || true
        exit 0
      fi
      sleep 1
    done
  ) >/dev/null 2>&1 &
  MONITOR_PID=$!

  # Bash 3.2 watchdog: background sleep loop, no GNU timeout(1).
  (
    elapsed=0
    while [ "$elapsed" -lt "$TIMEOUT_SECONDS" ]; do
      sleep 1
      elapsed=$((elapsed + 1))
    done
    : >"$TMP_DIR/timeout.flag"
    kill -TERM "$QEMU_PID" 2>/dev/null || true
    sleep 2
    if [ -f "$done_flag" ]; then
      exit 0
    fi
    kill -KILL "$QEMU_PID" 2>/dev/null || true
  ) >/dev/null 2>&1 &
  WATCHDOG_PID=$!

  wait "$QEMU_PID" || qemu_status=$?
  ELAPSED=$SECONDS
  : >"$done_flag" 2>/dev/null || true

  kill -TERM "$MONITOR_PID" 2>/dev/null || true
  kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
  wait "$MONITOR_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  QEMU_PID=""
  MONITOR_PID=""
  WATCHDOG_PID=""

  if [ -f "$TMP_DIR/success.flag" ]; then
    SUCCEEDED=1
  fi
  if [ -f "$TMP_DIR/timeout.flag" ]; then
    TIMED_OUT=1
  fi

  if [ "$TIMED_OUT" -eq 1 ]; then
    warn "boot did not complete all assertions within ${TIMEOUT_SECONDS}s"
  elif [ "$qemu_status" -ne 0 ] && [ "$SUCCEEDED" -eq 0 ]; then
    warn "QEMU exited with status $qemu_status"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Offline mode
# ---------------------------------------------------------------------------

run_offline() {
  if [ ! -e "$LOG_FROM" ]; then
    err "--log-from file not found: $LOG_FROM"
    exit "$EXIT_USAGE"
  fi
  if [ ! -f "$LOG_FROM" ]; then
    err "--log-from is not a regular file: $LOG_FROM"
    exit "$EXIT_USAGE"
  fi
  if [ ! -r "$LOG_FROM" ]; then
    err "--log-from file is not readable: $LOG_FROM"
    exit "$EXIT_USAGE"
  fi
  if [ ! -w "$ARTIFACT_DIR" ]; then
    err "artifact directory is not writable: $ARTIFACT_DIR"
    err "hint: run boot-check as the user that owns the build output, or chown/chmod the output directory"
    exit "$EXIT_USAGE"
  fi

  LOG_PATH=$LOG_FROM
  LOG_EVIDENCE=$LOG_FROM
  EVIDENCE_PATH="$ARTIFACT_DIR/boot-evidence.json"

  if [ -n "$QEMU_OPT" ]; then
    QEMU_LABEL=$QEMU_OPT
  else
    case "$ARCH_VALUE" in
      x86_64) QEMU_LABEL=qemu-system-x86_64 ;;
      aarch64) QEMU_LABEL=qemu-system-aarch64 ;;
    esac
  fi

  say "offline mode: assertions on $LOG_FROM"
  SECONDS=0
  ELAPSED=$SECONDS
}

# ---------------------------------------------------------------------------
# Evidence
# ---------------------------------------------------------------------------

write_evidence() {
  local tmp="$TMP_DIR/boot-evidence.json"

  if [ -f "$LOG_PATH" ]; then
    if ! LOG_HASH=$(sha256_file "$LOG_PATH"); then
      warn "cannot compute sha256 for $LOG_PATH"
      LOG_HASH=""
    fi
  fi

  if [ "$JSON_BACKEND" = "jq" ]; then
    if ! jq -n \
      --arg apiVersion "$EVIDENCE_API_VERSION" \
      --arg artifact "$ARTIFACT_ABS" \
      --arg qemu "$QEMU_LABEL" \
      --argjson timeout_seconds "$TIMEOUT_SECONDS" \
      --argjson elapsed_seconds "$ELAPSED" \
      --arg result "$RESULT" \
      --arg assertions "$ASSERT_RECORDS" \
      --arg log "$LOG_EVIDENCE" \
      --arg log_sha256 "$LOG_HASH" \
      '{
        apiVersion: $apiVersion,
        artifact: $artifact,
        qemu: $qemu,
        timeout_seconds: $timeout_seconds,
        elapsed_seconds: $elapsed_seconds,
        result: $result,
        assertions: (
          $assertions
          | split("\n")
          | map(select(length > 0) | split("\u001f"))
          | map({id: .[0], result: .[1], detail: .[2]})
        ),
        log: $log,
        log_sha256: $log_sha256
      }' >"$tmp"; then
      err "failed to render evidence JSON"
      return 1
    fi
  else
    if ! python3 - "$tmp" "$ARTIFACT_ABS" "$QEMU_LABEL" "$TIMEOUT_SECONDS" \
      "$ELAPSED" "$RESULT" "$ASSERT_RECORDS" \
      "$LOG_EVIDENCE" "$LOG_HASH" <<'PY'
import json
import sys


def parse_assertions(records):
    assertions = []
    for line in records.split("\n"):
        if not line:
            continue
        parts = line.split("\x1f")
        assertions.append(
            {
                "id": parts[0],
                "result": parts[1] if len(parts) > 1 else "fail",
                "detail": parts[2] if len(parts) > 2 else "",
            }
        )
    return assertions


def main(argv):
    out = argv[1]
    evidence = {
        "apiVersion": "sysemble/boot-evidence/v1",
        "artifact": argv[2],
        "qemu": argv[3],
        "timeout_seconds": int(argv[4]),
        "elapsed_seconds": int(argv[5]),
        "result": argv[6],
        "assertions": parse_assertions(argv[7]),
        "log": argv[8],
        "log_sha256": argv[9],
    }
    try:
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(evidence, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
    except OSError as exc:
        sys.stderr.write("cannot write evidence: %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY
    then
      err "failed to render evidence JSON"
      return 1
    fi
  fi

  if ! mv -f "$tmp" "$EVIDENCE_PATH"; then
    err "cannot write evidence file: $EVIDENCE_PATH"
    return 1
  fi
  return 0
}

report_summary() {
  local id=""
  local result=""
  local detail=""

  if [ "$BOOT_MODE" = "uefi" ]; then
    if [ -n "$FIRMWARE_CODE" ]; then
      say "boot mode: uefi (OVMF $FIRMWARE_CODE + GRUB)"
    else
      say "boot mode: uefi (OVMF + GRUB)"
    fi
  else
    say "boot mode: kernel (-kernel/-initrd)"
  fi
  if [ -n "$LOG_FROM" ]; then
    say "mode: offline (--log-from $LOG_FROM)"
  fi
  if [ "$BOOT_MODE" = "uefi" ] && [ "$GRAPHICAL_MODE" -eq 1 ]; then
    say "graphical: -vga virtio, -m ${MEMORY_MB} (8 assertions)"
  fi
  say "artifact: $ARTIFACT_ABS"
  say "qemu: $QEMU_LABEL (timeout ${TIMEOUT_SECONDS}s)"
  while IFS="$US" read -r id result detail; do
    if [ -n "$id" ]; then
      say "$id: $result - $detail"
    fi
  done <<EOF
$ASSERT_RECORDS
EOF
  say "result: $RESULT (${ELAPSED}s)"
  say "evidence: $EVIDENCE_PATH"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"

  if [ -z "$LOG_FROM" ] && [ -n "$QEMU_OPT" ]; then
    check_explicit_qemu
  fi

  if ! TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sysemble-boot.XXXXXX" 2>/dev/null); then
    err "cannot create a temporary directory"
    exit "$EXIT_USAGE"
  fi
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  resolve_artifact
  detect_json_backend
  parse_artifact

  if [ -n "$FIRMWARE_OPT" ] && [ "$BOOT_MODE" != "uefi" ]; then
    warn "ignoring --firmware: artifact boot.mode is '$BOOT_MODE' (only 'uefi' uses OVMF)"
  fi

  if [ -n "$LOG_FROM" ]; then
    run_offline
  else
    run_qemu
  fi

  evaluate_assertions
  determine_result

  if ! write_evidence; then
    exit "$EXIT_USAGE"
  fi

  report_summary

  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if ! cat "$EVIDENCE_PATH"; then
      err "cannot read evidence file: $EVIDENCE_PATH"
      exit "$EXIT_USAGE"
    fi
  fi

  case "$RESULT" in
    pass) exit "$EXIT_PASS" ;;
    fail) exit "$EXIT_ASSERT" ;;
    timeout) exit "$EXIT_TIMEOUT" ;;
    *)
      err "internal error: unknown result '$RESULT'"
      exit "$EXIT_USAGE"
      ;;
  esac
}

main "$@"
