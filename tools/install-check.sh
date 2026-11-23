#!/usr/bin/env bash
# Sysemble install-check (P0-d3): prove an installer ISO installs to a blank disk
# and that the installed disk boots.
#
# Contract (frozen by docs/plan/P0-d3-workplan.md sections 2.2/2.3):
#   tools/install-check.sh --artifact <installer.json> [--timeout 1200] [--json]
#                          [--qemu <binary>] [--firmware <OVMF_CODE>]
#                          [--boot-check <path>] [--workdir <dir>]
#
# Two phases against one artifact:
#
#   install  A 6 GiB sparse raw disk is created, then QEMU boots the installer
#            ISO (q35 + OVMF pflash + -cdrom + the disk as a virtio drive) and
#            waits for the serial console to print `SYMBLE: install complete`.
#            The installer's own `SYMBLE: install failed` marker fails the run
#            immediately and its line is recorded as the phase error.
#   boot     The installer QEMU is stopped and tools/boot-check.sh boots the
#            installed disk in UEFI mode (a temporary mode=uefi artifact is
#            generated next to the disk). Its JSON evidence is merged into
#            install-evidence.json.
#
# Artifact fields used (boot-check convention: paths are relative to the
# directory holding artifact.json):
#   boot.mode       must be 'install'
#   boot.iso        installer ISO, a readable regular file (relative path)
#   boot.memory_mb  QEMU -m for the install phase: a positive JSON integer
#                   (default: 1024). The post-install boot uses 1024 MB, the
#                   frozen value from P0-d3 section 2.3.
#   boot.install_device / boot.cmdline are accepted but not interpreted here:
#   the installer ISO owns its kernel command line and target device.
#
# Outputs are written beside artifact.json so CI can upload the build output
# directory as-is:
#   install.log            installer serial console (always kept, also on
#                          failure/timeout)
#   install-boot.log       post-install serial console, copied from boot-check's
#                          boot.log when available (never overwrites anything
#                          outside the artifact and work directories)
#   install-evidence.json  merged evidence:
#     {"apiVersion":"sysemble/install-evidence/v1",
#      "result":"pass|fail|timeout",
#      "phases":{
#        "install":{"result":"pass","marker":"SYMBLE: install complete"},
#        "boot":{"result":"pass","assertions":[...]}}}
#   When the install phase fails or times out, the boot phase never runs and is
#   omitted from phases; the install phase carries an "error" string instead.
#
# Work directory:
#   Default: a fresh $TMPDIR/sysemble-install.XXXXXX directory, removed on exit
#   (the disk is sparse but can still confuse `du`; nothing is left behind).
#   --workdir <dir>: caller-owned, created if needed, never removed. It keeps
#   disk.img, boot-artifact.json, boot.log and boot-evidence.json for
#   diagnosis. An existing disk.img is never overwritten (exit 2).
#
# Exit codes (P0-d3 section 2.3):
#   0  install marker seen and the installed disk booted
#   1  install failed (failed marker / QEMU exited early) or the post-install
#      boot failed (including a boot-check timeout)
#   2  usage, artifact, output, or boot-check configuration error
#   3  QEMU or OVMF firmware is unavailable
#   4  install timed out waiting for the completion marker
#
# Requires bash 3.2+ (macOS /bin/bash). Do not use bash 4 features.
# This script never changes the host, never uses sudo, and never needs network.

set -euo pipefail

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------

EVIDENCE_API_VERSION="sysemble/install-evidence/v1"
INSTALL_MARKER="SYMBLE: install complete"
INSTALL_FAILED_MARKER="SYMBLE: install failed"
DISK_SIZE="6G"
DISK_SIZE_MB=6144
BOOT_MEMORY_MB=1024
DEFAULT_TIMEOUT=1200

EXIT_PASS=0
EXIT_FAIL=1
EXIT_USAGE=2
EXIT_QEMU=3
EXIT_TIMEOUT=4

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

ARTIFACT_ARG=""
TIMEOUT_SECONDS=$DEFAULT_TIMEOUT
JSON_OUTPUT=0
QEMU_OPT=""
FIRMWARE_OPT=""
BOOT_CHECK_OPT=""
WORKDIR_OPT=""

SCRIPT_DIR=""
ARTIFACT_DIR=""
ARTIFACT_ABS=""
JSON_BACKEND=""

WORKDIR=""
WORKDIR_OWNED=0
DISK_ABS=""
VARS_TMP=""
EVIDENCE_TMP=""

ISO_REL=""
ISO_ABS=""
BOOT_MODE_KIND="missing"
BOOT_MODE_VALUE=""
ISO_KIND="missing"
ISO_VALUE=""
MEMORY_KIND="missing"
MEMORY_VALUE=""
MEMORY_MB=1024

QEMU_LABEL=""
QEMU_BIN=""
FIRMWARE_CODE=""
FIRMWARE_VARS=""

INSTALL_LOG=""
EVIDENCE_PATH=""
BOOT_ARTIFACT=""
BOOT_STDOUT=""
BOOT_STDERR=""
BOOT_EVIDENCE_FILE=""
BOOT_CHECK=""

QEMU_ARGS=()
BOOT_ARGS=()
QEMU_PID=""
QEMU_STATUS=0
BOOT_PID=""

INSTALL_PHASE_RESULT="fail"
INSTALL_PHASE_ERROR=""
INSTALL_MARKER_OUT=""
INSTALL_ELAPSED=0
BOOT_PHASE_RESULT=""
BOOT_PHASE_ERROR=""
OVERALL_RESULT="fail"

CLEANED=0

# ---------------------------------------------------------------------------
# Logging / usage
# ---------------------------------------------------------------------------

err() {
  printf 'install-check: error: %s\n' "$*" >&2
}

warn() {
  printf 'install-check: warning: %s\n' "$*" >&2
}

# Human-readable progress goes to stderr when stdout is reserved for --json.
say() {
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    printf 'install-check: %s\n' "$*" >&2
  else
    printf 'install-check: %s\n' "$*"
  fi
}

IFS= read -r -d '' USAGE_TEXT <<'USAGE' || true
Sysemble install-check (P0-d3) - install an installer ISO to a blank disk, then
boot the installed disk

Usage:
  tools/install-check.sh --artifact <installer.json> [--timeout 1200] [--json]
                         [--qemu <binary>] [--firmware <OVMF_CODE>]
                         [--boot-check <path>] [--workdir <dir>]

Options:
  --artifact <path>   installer artifact.json (boot.mode=install)
  --timeout <secs>    install deadline in whole seconds (default: 1200); the
                      same value is passed to boot-check for the boot phase
  --json              print only install-evidence.json on stdout; the human
                      summary goes to stderr
  --qemu <binary>     QEMU binary (default: qemu-system-x86_64 from PATH)
  --firmware <path>   OVMF code image. Default: the first readable path of
                        /usr/share/OVMF/OVMF_CODE_4M.fd
                        /usr/share/OVMF/OVMF_CODE.fd
                        /usr/share/edk2/ovmf/OVMF_CODE.fd
                      The matching VARS template is taken from the same
                      directory (OVMF_VARS_4M.fd / OVMF_VARS.fd).
  --boot-check <path> boot-check script for phase two (default:
                      tools/boot-check.sh next to this script)
  --workdir <dir>     caller-owned work directory (created if needed, never
                      removed). Without it, $TMPDIR/sysemble-install.XXXXXX is
                      used and removed on exit.
  -h, --help          show this help and exit 0

Artifact fields:
  boot.mode       required, must be 'install'
  boot.iso        required, relative to artifact.json, must exist and be a
                  readable regular file
  boot.memory_mb  optional positive JSON integer, default 1024
  boot.install_device / boot.cmdline are informational here; the installer ISO
  carries its own kernel command line and target device.

Phase one QEMU arguments (frozen):
  -machine q35 -m <memory_mb> -smp 2 -nographic -no-reboot
  -drive if=pflash,format=raw,readonly=on,file=<OVMF_CODE>
  -drive if=pflash,format=raw,file=<VARS copy>
  -cdrom <boot.iso>
  -drive file=<workdir/disk.img>,format=raw,if=virtio

The disk is created with `truncate -s 6G`, i.e. a 6 GiB sparse raw image. The
installer must print `SYMBLE: install complete` on the serial console. A
`SYMBLE: install failed` line fails the run (exit 1) and is recorded in the
evidence.

Phase two writes <workdir>/boot-artifact.json:
  {"apiVersion":"sysemble/artifact/v1","arch":"x86_64",
   "images":[{"path":"disk.img","format":"raw","size_mb":6144}],
   "boot":{"mode":"uefi","disk":"disk.img","memory_mb":1024}}
and runs:
  tools/boot-check.sh --artifact <workdir>/boot-artifact.json \
      --timeout <timeout> --json --qemu <qemu> --firmware <OVMF_CODE>
Its boot-evidence.json assertions are merged into phases.boot. Any boot-check
exit code other than 0 is a post-install boot failure and maps to exit 1
(its 4 becomes phases.boot.result=timeout, result=fail).

Outputs (beside artifact.json):
  install.log            installer serial console (kept on every outcome)
  install-boot.log       post-install serial console (when boot-check wrote it)
  install-evidence.json  merged evidence

The install-phase evidence has {result, marker} on success and
{result, error} on failure/timeout. phases.boot is present only when the install
phase passed and boot-check ran.

Exit codes:
  0  install and post-install boot both passed
  1  install failed, or the installed disk did not boot
  2  usage, artifact, output, or boot-check configuration error
  3  QEMU or OVMF firmware is unavailable
  4  install timed out

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
      --qemu)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          err "--qemu requires a non-empty value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        QEMU_OPT=$2
        shift 2
        ;;
      --qemu=*)
        QEMU_OPT=${1#--qemu=}
        if [ -z "$QEMU_OPT" ]; then
          err "--qemu requires a non-empty value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        shift
        ;;
      --firmware)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          err "--firmware requires a non-empty value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        FIRMWARE_OPT=$2
        shift 2
        ;;
      --firmware=*)
        FIRMWARE_OPT=${1#--firmware=}
        if [ -z "$FIRMWARE_OPT" ]; then
          err "--firmware requires a non-empty value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        shift
        ;;
      --boot-check)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          err "--boot-check requires a non-empty value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        BOOT_CHECK_OPT=$2
        shift 2
        ;;
      --boot-check=*)
        BOOT_CHECK_OPT=${1#--boot-check=}
        if [ -z "$BOOT_CHECK_OPT" ]; then
          err "--boot-check requires a non-empty value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        shift
        ;;
      --workdir)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          err "--workdir requires a non-empty value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        WORKDIR_OPT=$2
        shift 2
        ;;
      --workdir=*)
        WORKDIR_OPT=${1#--workdir=}
        if [ -z "$WORKDIR_OPT" ]; then
          err "--workdir requires a non-empty value"
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
  TIMEOUT_SECONDS=$((10#$TIMEOUT_SECONDS))
}

# ---------------------------------------------------------------------------
# Script / artifact location
# ---------------------------------------------------------------------------

resolve_script_dir() {
  case "$0" in
    */*)
      if ! SCRIPT_DIR=$(cd "${0%/*}" 2>/dev/null && pwd -P); then
        err "cannot resolve the script directory from: $0"
        exit "$EXIT_USAGE"
      fi
      ;;
    *)
      SCRIPT_DIR=$(pwd -P)
      ;;
  esac
}

resolve_artifact() {
  local artifact_base=""

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
      artifact_base=${ARTIFACT_ARG##*/}
      ;;
    *)
      ARTIFACT_DIR=.
      artifact_base=$ARTIFACT_ARG
      ;;
  esac
  if [ -z "$ARTIFACT_DIR" ]; then
    ARTIFACT_DIR=/
  fi
  if ! ARTIFACT_DIR=$(cd "$ARTIFACT_DIR" 2>/dev/null && pwd -P); then
    err "cannot resolve the artifact directory for: $ARTIFACT_ARG"
    exit "$EXIT_USAGE"
  fi
  if [ "$ARTIFACT_DIR" = "/" ]; then
    ARTIFACT_ABS="/$artifact_base"
  else
    ARTIFACT_ABS="$ARTIFACT_DIR/$artifact_base"
  fi
}

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
# Artifact parsing
#
# Both backends emit `key<0x1f>kind<0x1f>value` records. Control characters in
# values are replaced with spaces, so a record can never be split by the shell.
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
scalar("boot.mode"; ["boot", "mode"]),
scalar("boot.iso"; ["boot", "iso"]),
scalar("boot.memory_mb"; ["boot", "memory_mb"])
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
        current = root
        for key in keys:
            if not isinstance(current, dict) or key not in current:
                return MISSING
            current = current[key]
        return current

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

    def emit(key, keys):
        value = get(keys)
        if value is MISSING:
            sys.stdout.write("%s\x1fmissing\x1f\n" % key)
        else:
            sys.stdout.write(
                "%s\x1f%s\x1f%s\n" % (key, kind(value), CONTROL.sub(" ", fmt(value)))
            )

    emit("boot.mode", ["boot", "mode"])
    emit("boot.iso", ["boot", "iso"])
    emit("boot.memory_mb", ["boot", "memory_mb"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

parse_artifact() {
  local records=""
  local key=""
  local field1=""
  local field2=""

  if [ "$JSON_BACKEND" = "jq" ]; then
    if ! records=$(jq -r "$JQ_EXTRACT" "$ARTIFACT_ABS" 2>&1); then
      err "artifact is not valid JSON (or is not a JSON object): $ARTIFACT_ARG"
      if [ -n "$records" ]; then
        printf '%s\n' "$records" >&2
      fi
      exit "$EXIT_USAGE"
    fi
  else
    if ! records=$(python3 -c "$PY_EXTRACT" "$ARTIFACT_ABS" 2>&1); then
      err "artifact is not valid JSON (or is not a JSON object): $ARTIFACT_ARG"
      if [ -n "$records" ]; then
        printf '%s\n' "$records" >&2
      fi
      exit "$EXIT_USAGE"
    fi
  fi

  while IFS=$'\x1f' read -r key field1 field2; do
    case "$key" in
      boot.mode)
        BOOT_MODE_KIND=$field1
        BOOT_MODE_VALUE=$field2
        ;;
      boot.iso)
        ISO_KIND=$field1
        ISO_VALUE=$field2
        ;;
      boot.memory_mb)
        MEMORY_KIND=$field1
        MEMORY_VALUE=$field2
        ;;
      *)
        ;;
    esac
  done <<EOF
$records
EOF

  case "$BOOT_MODE_KIND" in
    string)
      if [ "$BOOT_MODE_VALUE" != "install" ]; then
        err "artifact boot.mode must be 'install' (got '$BOOT_MODE_VALUE')"
        exit "$EXIT_USAGE"
      fi
      ;;
    missing)
      err "artifact field boot.mode is required and must be 'install'"
      exit "$EXIT_USAGE"
      ;;
    *)
      err "artifact field boot.mode must be a string (got '$BOOT_MODE_KIND')"
      exit "$EXIT_USAGE"
      ;;
  esac

  if [ "$ISO_KIND" != "string" ] || [ -z "$ISO_VALUE" ]; then
    err "artifact field boot.iso is required when boot.mode=install"
    exit "$EXIT_USAGE"
  fi
  case "$ISO_VALUE" in
    /*)
      err "artifact boot.iso must be relative to the artifact directory: $ISO_VALUE"
      exit "$EXIT_USAGE"
      ;;
  esac
  ISO_REL=$ISO_VALUE
  ISO_ABS="$ARTIFACT_DIR/$ISO_REL"
  if [ ! -f "$ISO_ABS" ]; then
    err "artifact boot.iso does not exist or is not a regular file: $ISO_REL (resolved: $ISO_ABS)"
    exit "$EXIT_USAGE"
  fi
  if [ ! -r "$ISO_ABS" ]; then
    err "artifact boot.iso is not readable: $ISO_REL (resolved: $ISO_ABS)"
    exit "$EXIT_USAGE"
  fi

  case "$MEMORY_KIND" in
    missing)
      MEMORY_MB=1024
      ;;
    number)
      case "$MEMORY_VALUE" in
        '' | 0 | *[!0-9]*)
          err "artifact field boot.memory_mb must be a positive integer (got '$MEMORY_VALUE')"
          exit "$EXIT_USAGE"
          ;;
      esac
      MEMORY_MB=$MEMORY_VALUE
      ;;
    *)
      err "artifact field boot.memory_mb must be a number (got '$MEMORY_KIND')"
      exit "$EXIT_USAGE"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# QEMU / boot-check / firmware availability
# ---------------------------------------------------------------------------

resolve_qemu() {
  local found=""

  if [ -n "$QEMU_OPT" ]; then
    QEMU_LABEL=$QEMU_OPT
    case "$QEMU_OPT" in
      */*)
        if [ -d "$QEMU_OPT" ] || [ ! -x "$QEMU_OPT" ]; then
          err "QEMU binary is not executable: $QEMU_OPT"
          exit "$EXIT_QEMU"
        fi
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

  QEMU_LABEL=qemu-system-x86_64
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

resolve_boot_check() {
  local candidate=""
  local found=""

  if [ -n "$BOOT_CHECK_OPT" ]; then
    case "$BOOT_CHECK_OPT" in
      */*)
        candidate=$BOOT_CHECK_OPT
        ;;
      *)
        if found=$(command -v "$BOOT_CHECK_OPT" 2>/dev/null); then
          candidate=$found
        else
          candidate=$BOOT_CHECK_OPT
        fi
        ;;
    esac
  else
    candidate="$SCRIPT_DIR/boot-check.sh"
  fi

  if [ ! -f "$candidate" ]; then
    err "boot-check script not found: $candidate"
    exit "$EXIT_USAGE"
  fi
  if [ ! -x "$candidate" ]; then
    err "boot-check script is not executable: $candidate"
    exit "$EXIT_USAGE"
  fi
  BOOT_CHECK=$candidate
}

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

# Probe order is the same as tools/boot-check.sh (P0-c contract); --firmware
# always wins. The VARS template must live next to the code image.
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

resolve_firmware() {
  local resolved=""
  local code_dir=""
  local code_base=""
  local vars_base=""
  local candidate=""

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
      err "no OVMF firmware found; the installer ISO needs a UEFI code image"
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

  # QEMU -drive values are comma-separated; a comma in a path cannot be
  # expressed, so reject it as a usage error instead of launching wrong drives.
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

  say "firmware: $FIRMWARE_CODE"
  say "firmware vars: $FIRMWARE_VARS"
}

# ---------------------------------------------------------------------------
# Outputs / work directory / disk
# ---------------------------------------------------------------------------

prepare_outputs() {
  if [ ! -w "$ARTIFACT_DIR" ]; then
    err "artifact directory is not writable: $ARTIFACT_DIR"
    err "hint: run install-check as the user that owns the build output, or chown the output directory"
    exit "$EXIT_USAGE"
  fi

  INSTALL_LOG="$ARTIFACT_DIR/install.log"
  EVIDENCE_PATH="$ARTIFACT_DIR/install-evidence.json"
  rm -f "$EVIDENCE_PATH" 2>/dev/null || true
  rm -f "$ARTIFACT_DIR/install-boot.log" 2>/dev/null || true
  if ! : >"$INSTALL_LOG" 2>/dev/null; then
    err "cannot write install log: $INSTALL_LOG"
    exit "$EXIT_USAGE"
  fi
}

create_workdir() {
  if [ -n "$WORKDIR_OPT" ]; then
    if [ -e "$WORKDIR_OPT" ] && [ ! -d "$WORKDIR_OPT" ]; then
      err "--workdir is not a directory: $WORKDIR_OPT"
      exit "$EXIT_USAGE"
    fi
    if ! mkdir -p "$WORKDIR_OPT" 2>/dev/null; then
      err "cannot create --workdir: $WORKDIR_OPT"
      exit "$EXIT_USAGE"
    fi
    if ! WORKDIR=$(cd "$WORKDIR_OPT" 2>/dev/null && pwd -P); then
      err "cannot resolve --workdir: $WORKDIR_OPT"
      exit "$EXIT_USAGE"
    fi
    WORKDIR_OWNED=0
  else
    if ! WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/sysemble-install.XXXXXX" 2>/dev/null); then
      err "cannot create a temporary work directory under ${TMPDIR:-/tmp}"
      exit "$EXIT_USAGE"
    fi
    WORKDIR_OWNED=1
  fi
  if [ ! -w "$WORKDIR" ]; then
    err "work directory is not writable: $WORKDIR"
    exit "$EXIT_USAGE"
  fi

  DISK_ABS="$WORKDIR/disk.img"
  case "$DISK_ABS" in
    *,*)
      err "disk path contains a comma, which cannot be expressed in QEMU -drive: $DISK_ABS"
      exit "$EXIT_USAGE"
      ;;
  esac
  if [ -e "$DISK_ABS" ]; then
    err "refusing to overwrite an existing disk image: $DISK_ABS"
    err "hint: use an empty --workdir (the caller owns it and it is never deleted)"
    exit "$EXIT_USAGE"
  fi
}

prepare_vars_copy() {
  if ! VARS_TMP=$(mktemp "$WORKDIR/ovmf-vars.XXXXXX" 2>/dev/null); then
    err "cannot create a temporary OVMF VARS file in: $WORKDIR"
    exit "$EXIT_USAGE"
  fi
  case "$VARS_TMP" in
    *,*)
      err "temporary VARS path contains a comma, which cannot be expressed in QEMU -drive: $VARS_TMP"
      exit "$EXIT_USAGE"
      ;;
  esac
  if ! cp "$FIRMWARE_VARS" "$VARS_TMP" 2>/dev/null; then
    err "cannot copy OVMF VARS template: $FIRMWARE_VARS"
    exit "$EXIT_USAGE"
  fi
}

create_disk() {
  if ! command -v truncate >/dev/null 2>&1; then
    err "truncate not found; a 6 GiB sparse raw disk cannot be created"
    exit "$EXIT_USAGE"
  fi
  if ! truncate -s "$DISK_SIZE" "$DISK_ABS" 2>/dev/null; then
    err "cannot create sparse disk image: $DISK_ABS"
    exit "$EXIT_USAGE"
  fi
  say "disk: $DISK_ABS (6 GiB sparse raw)"
}

# ---------------------------------------------------------------------------
# Install phase
# ---------------------------------------------------------------------------

install_marker_seen() {
  [ -f "$INSTALL_LOG" ] && grep -Fq "$INSTALL_MARKER" "$INSTALL_LOG" 2>/dev/null
}

install_failed_seen() {
  [ -f "$INSTALL_LOG" ] && grep -Fq "$INSTALL_FAILED_MARKER" "$INSTALL_LOG" 2>/dev/null
}

install_failure_reason() {
  local line=""

  line=$(grep -F "$INSTALL_FAILED_MARKER" "$INSTALL_LOG" 2>/dev/null | tail -n 1) || line=""
  if [ -z "$line" ]; then
    line=$INSTALL_FAILED_MARKER
  fi
  printf '%s' "$line" | tr -d '\r'
}

stop_qemu() {
  local i=0

  QEMU_STATUS=0
  if [ -z "$QEMU_PID" ]; then
    return 0
  fi
  if kill -0 "$QEMU_PID" 2>/dev/null; then
    kill -TERM "$QEMU_PID" 2>/dev/null || true
    while [ "$i" -lt 5 ]; do
      if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        break
      fi
      sleep 1
      i=$((i + 1))
    done
    if kill -0 "$QEMU_PID" 2>/dev/null; then
      kill -KILL "$QEMU_PID" 2>/dev/null || true
    fi
  fi
  wait "$QEMU_PID" 2>/dev/null || QEMU_STATUS=$?
  QEMU_PID=""
}

build_install_args() {
  QEMU_ARGS=(
    -machine q35
    -m "$MEMORY_MB"
    -smp 2
    -nographic
    -no-reboot
    -drive "if=pflash,format=raw,readonly=on,file=$FIRMWARE_CODE"
    -drive "if=pflash,format=raw,file=$VARS_TMP"
    -cdrom "$ISO_ABS"
    -drive "file=$DISK_ABS,format=raw,if=virtio"
  )
}

run_install_phase() {
  local outcome=""
  local elapsed=0

  build_install_args
  say "launching $QEMU_LABEL (installer ISO, q35/OVMF, -cdrom)"
  say "serial log: $INSTALL_LOG"
  say "install deadline: ${TIMEOUT_SECONDS}s"

  SECONDS=0
  "$QEMU_BIN" "${QEMU_ARGS[@]}" </dev/null >"$INSTALL_LOG" 2>&1 &
  QEMU_PID=$!

  while :; do
    if install_failed_seen; then
      outcome=failed
      break
    fi
    if install_marker_seen; then
      outcome=complete
      break
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
      outcome=exited
      break
    fi
    if [ "$elapsed" -ge "$TIMEOUT_SECONDS" ]; then
      outcome=timeout
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  stop_qemu
  INSTALL_ELAPSED=$SECONDS

  # A failed marker always wins; re-read after QEMU is stopped so a marker
  # written during the kill cannot be lost.
  if install_failed_seen; then
    outcome=failed
  elif install_marker_seen; then
    outcome=complete
  fi

  case "$outcome" in
    complete)
      INSTALL_PHASE_RESULT=pass
      INSTALL_MARKER_OUT=$INSTALL_MARKER
      say "install: pass (marker seen after ${INSTALL_ELAPSED}s)"
      ;;
    failed)
      INSTALL_PHASE_RESULT=fail
      INSTALL_PHASE_ERROR=$(install_failure_reason)
      warn "install failed: $INSTALL_PHASE_ERROR"
      ;;
    timeout)
      INSTALL_PHASE_RESULT=timeout
      INSTALL_PHASE_ERROR="no \`$INSTALL_MARKER\` within ${TIMEOUT_SECONDS}s"
      warn "$INSTALL_PHASE_ERROR"
      ;;
    exited)
      INSTALL_PHASE_RESULT=fail
      INSTALL_PHASE_ERROR="QEMU exited with status $QEMU_STATUS before \`$INSTALL_MARKER\`"
      warn "$INSTALL_PHASE_ERROR"
      ;;
    *)
      INSTALL_PHASE_RESULT=fail
      INSTALL_PHASE_ERROR="internal error: unknown install outcome '$outcome'"
      warn "$INSTALL_PHASE_ERROR"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Boot phase (delegates to tools/boot-check.sh in uefi mode)
# ---------------------------------------------------------------------------

write_boot_artifact() {
  BOOT_ARTIFACT="$WORKDIR/boot-artifact.json"
  if ! cat >"$BOOT_ARTIFACT" <<'EOF'
{
  "apiVersion": "sysemble/artifact/v1",
  "arch": "x86_64",
  "images": [
    {"path": "disk.img", "format": "raw", "size_mb": 6144}
  ],
  "boot": {
    "mode": "uefi",
    "disk": "disk.img",
    "memory_mb": 1024
  }
}
EOF
  then
    err "cannot write temporary boot artifact: $BOOT_ARTIFACT"
    exit "$EXIT_USAGE"
  fi
}

json_file_valid() {
  if [ "$JSON_BACKEND" = "jq" ]; then
    jq -e . "$1" >/dev/null 2>&1
  else
    python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$1" >/dev/null 2>&1
  fi
}

run_boot_phase() {
  local boot_status=0
  local last_err=""

  BOOT_PHASE_RESULT=""
  BOOT_PHASE_ERROR=""
  BOOT_EVIDENCE_FILE=""
  BOOT_STDOUT="$WORKDIR/boot-check.stdout"
  BOOT_STDERR="$WORKDIR/boot-check.stderr"

  write_boot_artifact
  rm -f "$WORKDIR/boot.log" "$WORKDIR/boot-evidence.json" 2>/dev/null || true

  BOOT_ARGS=(
    --artifact "$BOOT_ARTIFACT"
    --timeout "$TIMEOUT_SECONDS"
    --json
    --qemu "$QEMU_BIN"
    --firmware "$FIRMWARE_CODE"
  )

  say "launching $BOOT_CHECK (post-install disk, uefi/OVMF)"
  "$BOOT_CHECK" "${BOOT_ARGS[@]}" >"$BOOT_STDOUT" 2>"$BOOT_STDERR" &
  BOOT_PID=$!
  wait "$BOOT_PID" || boot_status=$?
  BOOT_PID=""

  if [ -f "$WORKDIR/boot-evidence.json" ] && json_file_valid "$WORKDIR/boot-evidence.json"; then
    BOOT_EVIDENCE_FILE="$WORKDIR/boot-evidence.json"
  elif [ -s "$BOOT_STDOUT" ] && json_file_valid "$BOOT_STDOUT"; then
    BOOT_EVIDENCE_FILE=$BOOT_STDOUT
  fi

  case "$boot_status" in
    0)
      BOOT_PHASE_RESULT=pass
      say "boot: pass (installed disk reached the boot-check assertions)"
      ;;
    4)
      BOOT_PHASE_RESULT=timeout
      BOOT_PHASE_ERROR="boot-check timed out after ${TIMEOUT_SECONDS}s"
      warn "$BOOT_PHASE_ERROR"
      ;;
    *)
      BOOT_PHASE_RESULT=fail
      last_err=$(tail -n 1 "$BOOT_STDERR" 2>/dev/null) || last_err=""
      if [ -n "$last_err" ]; then
        BOOT_PHASE_ERROR="boot-check exited with status ${boot_status}: ${last_err}"
      else
        BOOT_PHASE_ERROR="boot-check exited with status ${boot_status}"
      fi
      if [ -z "$BOOT_EVIDENCE_FILE" ]; then
        BOOT_PHASE_ERROR="$BOOT_PHASE_ERROR (no readable boot-evidence.json)"
      fi
      warn "$BOOT_PHASE_ERROR"
      ;;
  esac

  # boot-check writes boot.log next to its temporary artifact (inside the work
  # directory). Preserve it beside the installer log so a CI upload keeps the
  # post-install serial console as well. A caller-owned workdir already keeps
  # it, and the artifact directory must not be copied onto itself.
  if [ -f "$WORKDIR/boot.log" ] && [ "$WORKDIR" != "$ARTIFACT_DIR" ]; then
    if ! cp "$WORKDIR/boot.log" "$ARTIFACT_DIR/install-boot.log" 2>/dev/null; then
      warn "cannot preserve post-install serial log in $ARTIFACT_DIR"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Evidence
# ---------------------------------------------------------------------------

boot_assertions_json() {
  if [ -z "$BOOT_EVIDENCE_FILE" ]; then
    printf '[]'
    return 0
  fi
  if [ "$JSON_BACKEND" = "jq" ]; then
    jq -c '.assertions | if type == "array" then . else [] end' "$BOOT_EVIDENCE_FILE" 2>/dev/null || printf '[]'
  else
    python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get("assertions") if isinstance(data, dict) else None
print(json.dumps(value if isinstance(value, list) else []))
' "$BOOT_EVIDENCE_FILE" 2>/dev/null || printf '[]'
  fi
}

write_evidence() {
  local assertions_json="[]"

  if ! EVIDENCE_TMP=$(mktemp "$ARTIFACT_DIR/.install-evidence.XXXXXX" 2>/dev/null); then
    err "cannot create a temporary evidence file in: $ARTIFACT_DIR"
    return 1
  fi

  if [ "$JSON_BACKEND" = "jq" ]; then
    assertions_json=$(boot_assertions_json)
    [ -n "$assertions_json" ] || assertions_json="[]"
    if ! jq -n \
      --arg apiVersion "$EVIDENCE_API_VERSION" \
      --arg result "$OVERALL_RESULT" \
      --arg installResult "$INSTALL_PHASE_RESULT" \
      --arg installMarker "$INSTALL_MARKER_OUT" \
      --arg installError "$INSTALL_PHASE_ERROR" \
      --arg bootResult "$BOOT_PHASE_RESULT" \
      --arg bootError "$BOOT_PHASE_ERROR" \
      --argjson assertions "$assertions_json" \
      'def phase($r; $m; $e):
         {result: $r}
         + (if $m != "" then {marker: $m} else {} end)
         + (if $e != "" then {error: $e} else {} end);
       {
         apiVersion: $apiVersion,
         result: $result,
         phases: (
           {install: phase($installResult; $installMarker; $installError)}
           + (if $bootResult != "" then
                {boot: ({result: $bootResult, assertions: $assertions}
                         + (if $bootError != "" then {error: $bootError} else {} end))}
              else {} end)
         )
       }' >"$EVIDENCE_TMP"; then
      err "failed to render install evidence JSON"
      rm -f "$EVIDENCE_TMP" 2>/dev/null || true
      EVIDENCE_TMP=""
      return 1
    fi
  else
    if ! python3 - "$EVIDENCE_TMP" "$EVIDENCE_API_VERSION" "$OVERALL_RESULT" \
      "$INSTALL_PHASE_RESULT" "$INSTALL_MARKER_OUT" "$INSTALL_PHASE_ERROR" \
      "$BOOT_PHASE_RESULT" "$BOOT_PHASE_ERROR" "$BOOT_EVIDENCE_FILE" <<'PY'
import json
import sys


def load_assertions(path):
    if not path:
        return []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict):
        return []
    value = data.get("assertions")
    return value if isinstance(value, list) else []


def main(argv):
    out = argv[1]
    api_version = argv[2]
    result = argv[3]
    install_result = argv[4]
    install_marker = argv[5]
    install_error = argv[6]
    boot_result = argv[7]
    boot_error = argv[8]
    boot_evidence = argv[9]

    install = {"result": install_result}
    if install_marker:
        install["marker"] = install_marker
    if install_error:
        install["error"] = install_error

    phases = {"install": install}
    if boot_result:
        boot = {"result": boot_result, "assertions": load_assertions(boot_evidence)}
        if boot_error:
            boot["error"] = boot_error
        phases["boot"] = boot

    evidence = {
        "apiVersion": api_version,
        "result": result,
        "phases": phases,
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
      err "failed to render install evidence JSON"
      rm -f "$EVIDENCE_TMP" 2>/dev/null || true
      EVIDENCE_TMP=""
      return 1
    fi
  fi

  if ! mv -f "$EVIDENCE_TMP" "$EVIDENCE_PATH"; then
    err "cannot write evidence file: $EVIDENCE_PATH"
    rm -f "$EVIDENCE_TMP" 2>/dev/null || true
    EVIDENCE_TMP=""
    return 1
  fi
  EVIDENCE_TMP=""
}

report_summary() {
  say "artifact: $ARTIFACT_ABS"
  if [ -n "$DISK_ABS" ] && [ -f "$DISK_ABS" ]; then
    say "disk: $DISK_ABS (6 GiB sparse raw)"
  fi
  say "install: $INSTALL_PHASE_RESULT"
  if [ -n "$BOOT_PHASE_RESULT" ]; then
    say "boot: $BOOT_PHASE_RESULT"
  fi
  say "result: $OVERALL_RESULT"
  say "evidence: $EVIDENCE_PATH"
}

print_evidence_if_json() {
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    if ! cat "$EVIDENCE_PATH"; then
      err "cannot read evidence file: $EVIDENCE_PATH"
      exit "$EXIT_USAGE"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup() {
  if [ "$CLEANED" -eq 1 ]; then
    return 0
  fi
  CLEANED=1

  if [ -n "$BOOT_PID" ]; then
    kill -TERM "$BOOT_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$BOOT_PID" 2>/dev/null || true
    wait "$BOOT_PID" 2>/dev/null || true
    BOOT_PID=""
  fi
  stop_qemu

  if [ -n "$EVIDENCE_TMP" ] && [ -f "$EVIDENCE_TMP" ]; then
    rm -f "$EVIDENCE_TMP" 2>/dev/null || true
  fi
  if [ -n "$VARS_TMP" ] && [ -f "$VARS_TMP" ]; then
    rm -f "$VARS_TMP" 2>/dev/null || true
  fi

  # Only auto-created mktemp directories are ever removed. A caller-owned
  # --workdir is deliberately preserved for diagnosis.
  if [ "$WORKDIR_OWNED" -eq 1 ] && [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    case "$WORKDIR" in
      */sysemble-install.*)
        rm -rf "$WORKDIR" 2>/dev/null || true
        ;;
    esac
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  resolve_script_dir
  # An explicit QEMU is validated before the artifact, so "qemu is
  # unavailable" is observable even with a bad artifact (boot-check parity).
  if [ -n "$QEMU_OPT" ]; then
    resolve_qemu
  fi

  resolve_artifact
  detect_json_backend
  parse_artifact
  if [ -z "$QEMU_BIN" ]; then
    resolve_qemu
  fi
  resolve_boot_check
  resolve_firmware
  prepare_outputs

  create_workdir
  prepare_vars_copy
  create_disk

  run_install_phase
  if [ "$INSTALL_PHASE_RESULT" != "pass" ]; then
    if [ "$INSTALL_PHASE_RESULT" = "timeout" ]; then
      OVERALL_RESULT=timeout
    else
      OVERALL_RESULT=fail
    fi
    if ! write_evidence; then
      exit "$EXIT_USAGE"
    fi
    report_summary
    print_evidence_if_json
    if [ "$OVERALL_RESULT" = "timeout" ]; then
      exit "$EXIT_TIMEOUT"
    fi
    exit "$EXIT_FAIL"
  fi

  run_boot_phase
  if [ "$BOOT_PHASE_RESULT" = "pass" ]; then
    OVERALL_RESULT=pass
  else
    OVERALL_RESULT=fail
  fi

  if ! write_evidence; then
    exit "$EXIT_USAGE"
  fi
  report_summary
  print_evidence_if_json

  if [ "$OVERALL_RESULT" = "pass" ]; then
    exit "$EXIT_PASS"
  fi
  exit "$EXIT_FAIL"
}

main "$@"
