#!/usr/bin/env bash
# Sysemble TUI install-check (P0-e1): drive the serial TUI installer with
# expect, then prove the installed disk boots with the requested hostname.
#
# Contract (docs/plan/P0-e1-workplan.md sections 4 and 6):
#   tools/tui-install-check.sh --artifact <installer.json> --hostname <name>
#                              [--timeout 1200] [--json] [--workdir <dir>]
#                              [--qemu <binary>] [--firmware <OVMF_CODE>]
#                              [--boot-check <path>]
#
# Two phases against one artifact:
#
#   install  A 6 GiB sparse raw disk is created and QEMU boots the TUI installer
#            ISO (q35 + OVMF pflash + -cdrom + the disk as a virtio drive).
#            expect drives the frozen serial prompts in order:
#              SYMBLE-TUI disk [...]        -> Enter (default /dev/vda)
#              SYMBLE-TUI hostname [...]    -> --hostname
#              SYMBLE-TUI user [...]        -> ops
#              SYMBLE-TUI password:         -> s3cret
#              SYMBLE-TUI confirm ...       -> yes
#            The phase passes when `SYMBLE: install complete` appears. A
#            `SYMBLE: install failed: <reason>` line fails the phase immediately.
#            The whole interaction (serial console plus the expect answers, with
#            the password redacted) is kept as tui-install.log.
#   boot     The TUI QEMU is stopped and a temporary mode=uefi artifact is
#            written next to the disk. tools/boot-check.sh boots the installed
#            disk; its assertions are merged into tui-install-evidence.json.
#            An extra assertion `boot.hostname` requires the post-install serial
#            log to contain `<hostname> login:`, proving the hostname applied.
#
# Artifact fields used (paths relative to the directory holding artifact.json,
# the boot-check convention):
#   boot.mode         required, must be 'install'
#   boot.install_tui  required, must be boolean true
#   boot.iso          required, readable regular file
#   boot.memory_mb    optional positive JSON integer, default 1024
#   boot.install_device / boot.cmdline are accepted but not interpreted: the ISO
#   owns its kernel command line and target device.
#
# Outputs are written beside artifact.json so CI can upload the build output
# directory as-is:
#   tui-install.log            serial transcript plus redacted expect answers
#                              (always kept, also on failure/timeout)
#   tui-install-boot.log       post-install serial console, copied from
#                              boot-check's boot.log when it exists
#   tui-install-evidence.json  merged evidence:
#     {"apiVersion":"sysemble/install-evidence/v1",
#      "result":"pass|fail|timeout",
#      "phases":{
#        "install":{"result":"pass","marker":"SYMBLE: install complete"},
#        "boot":{"result":"pass","assertions":[..., {"id":"boot.hostname",...}]}}}
#   When the install phase fails or times out the boot phase never runs and is
#   omitted; the install phase carries an "error" string instead.
#
# Work directory:
#   Default: a fresh $TMPDIR/sysemble-tui-install.XXXXXX directory, removed on
#   exit. It holds disk.img, the generated expect script, the expect stdout /
#   stderr, boot-artifact.json, boot.log and boot-evidence.json while running.
#   --workdir <dir>: caller-owned, created if needed, never removed. It keeps
#   those files for diagnosis. An existing disk.img is never overwritten
#   (exit 2).
#
# Exit codes (same mapping as install-check):
#   0  install marker seen and the installed disk booted with the hostname
#   1  install failed (failed marker / QEMU or expect exited early) or the
#      post-install boot (including the hostname assertion) failed
#   2  usage, artifact, output, or boot-check configuration error
#   3  QEMU, OVMF firmware, or expect is unavailable
#   4  install timed out waiting for the completion marker
#
# Requires bash 3.2+ (macOS /bin/bash), expect, and jq or python3. Do not use
# bash 4 features. This script never changes the host, never uses sudo, and
# never needs network.

set -euo pipefail

# ---------------------------------------------------------------------------
# Contract constants
# ---------------------------------------------------------------------------

EVIDENCE_API_VERSION="sysemble/install-evidence/v1"
INSTALL_MARKER="SYMBLE: install complete"
INSTALL_FAILED_MARKER="SYMBLE: install failed"

DISK_SIZE="6G"
DEFAULT_TIMEOUT=1200

# Grace after --timeout before the shell watchdog force-kills a wedged expect.
# The expect script itself enforces --timeout exactly; this only protects the
# harness if expect cannot exit.
HARD_TIMEOUT_GRACE=5

EXIT_PASS=0
EXIT_FAIL=1
EXIT_USAGE=2
EXIT_QEMU=3
EXIT_TIMEOUT=4

# Internal expect exit statuses (never exposed to callers).
EXPECT_INSTALL_FAILED=10
EXPECT_EARLY_EXIT=5
EXPECT_SPAWN_FAILED=3

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

ARTIFACT_ARG=""
HOSTNAME_VALUE=""
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
TUI_KIND="missing"
TUI_VALUE=""
ISO_KIND="missing"
ISO_VALUE=""
MEMORY_KIND="missing"
MEMORY_VALUE=""
MEMORY_MB=1024

QEMU_LABEL=""
QEMU_BIN=""
EXPECT_BIN=""
FIRMWARE_CODE=""
FIRMWARE_VARS=""

TUI_LOG=""
EVIDENCE_PATH=""
BOOT_LOG_COPY=""
BOOT_ARTIFACT=""
BOOT_STDOUT=""
BOOT_STDERR=""
BOOT_EVIDENCE_FILE=""
BOOT_CHECK=""
EXPECT_SCRIPT=""
QEMU_PIDFILE=""
EXPECT_STDOUT=""
EXPECT_STDERR=""

QEMU_ARGS=()
BOOT_ARGS=()
EXPECT_PID=""
BOOT_PID=""

INSTALL_PHASE_RESULT="fail"
INSTALL_PHASE_ERROR=""
INSTALL_MARKER_OUT=""
INSTALL_ELAPSED=0
BOOT_PHASE_RESULT=""
BOOT_PHASE_ERROR=""
BOOT_HOSTNAME_RESULT="fail"
BOOT_HOSTNAME_DETAIL="boot phase did not run"
OVERALL_RESULT="fail"

CLEANED=0

# ---------------------------------------------------------------------------
# Logging / usage
# ---------------------------------------------------------------------------

err() {
  printf 'tui-install-check: error: %s\n' "$*" >&2
}

warn() {
  printf 'tui-install-check: warning: %s\n' "$*" >&2
}

# Human-readable progress goes to stderr when stdout is reserved for --json.
say() {
  if [ "$JSON_OUTPUT" -eq 1 ]; then
    printf 'tui-install-check: %s\n' "$*" >&2
  else
    printf 'tui-install-check: %s\n' "$*"
  fi
}

IFS= read -r -d '' USAGE_TEXT <<'USAGE' || true
Sysemble TUI install-check (P0-e1) - drive the serial TUI installer with
expect, then boot the installed disk

Usage:
  tools/tui-install-check.sh --artifact <installer.json> --hostname <name>
                             [--timeout 1200] [--json] [--workdir <dir>]
                             [--qemu <binary>] [--firmware <OVMF_CODE>]
                             [--boot-check <path>]

Options:
  --artifact <path>   installer artifact.json with boot.mode=install,
                      boot.install_tui=true, and an existing boot.iso
  --hostname <name>   hostname typed at the TUI and expected at the installed
                      disk's login prompt; [A-Za-z0-9.-], must start and end
                      with a letter or digit, max 63 characters (the installer's
                      valid_hostname contract)
  --timeout <secs>    install deadline in whole seconds (default: 1200); used
                      for the expect session and passed to boot-check
  --json              print only tui-install-evidence.json on stdout; the human
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
                      removed). Without it, $TMPDIR/sysemble-tui-install.XXXXXX
                      is used and removed on exit.
  -h, --help          show this help and exit 0

The TUI prompts are the frozen P0-e1 contract:
  SYMBLE-TUI disk [/dev/vda]:          -> Enter (default disk)
  SYMBLE-TUI hostname [sysemble]:      -> --hostname
  SYMBLE-TUI user [ops]:               -> ops
  SYMBLE-TUI password:                 -> s3cret
  SYMBLE-TUI confirm install to ...:   -> yes
The password is never written to the log; it is recorded as <redacted>.

Phase one QEMU arguments (frozen):
  -machine q35 -m <memory_mb> -smp 2 -nographic -no-reboot
  -drive if=pflash,format=raw,readonly=on,file=<OVMF_CODE>
  -drive if=pflash,format=raw,file=<VARS copy>
  -cdrom <boot.iso>
  -drive file=<workdir/disk.img>,format=raw,if=virtio

The disk is created with `truncate -s 6G`, i.e. a 6 GiB sparse raw image.

Phase two writes <workdir>/boot-artifact.json:
  {"apiVersion":"sysemble/artifact/v1","arch":"x86_64",
   "images":[{"path":"disk.img","format":"raw","size_mb":6144}],
   "boot":{"mode":"uefi","disk":"disk.img","memory_mb":1024}}
and runs:
  tools/boot-check.sh --artifact <workdir>/boot-artifact.json \
      --timeout <timeout> --json --qemu <qemu> --firmware <OVMF_CODE>
Its boot-evidence.json assertions are merged into phases.boot and an additional
`boot.hostname` assertion requires `<hostname> login:` in the post-install
serial log (boot.log). Any boot-check exit code other than 0 fails the run
(its 4 becomes phases.boot.result=timeout, overall result=fail).

Outputs (beside artifact.json):
  tui-install.log            TUI serial transcript + redacted expect answers
  tui-install-boot.log       post-install serial console (when produced)
  tui-install-evidence.json  merged evidence

Exit codes:
  0  install and post-install boot (including hostname) both passed
  1  install failed, or the installed disk did not boot / show the hostname
  2  usage, artifact, output, or boot-check configuration error
  3  QEMU, OVMF firmware, or expect is unavailable
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
      --hostname)
        if [ "$#" -lt 2 ]; then
          err "--hostname requires a value"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        HOSTNAME_VALUE=$2
        shift 2
        ;;
      --hostname=*)
        HOSTNAME_VALUE=${1#--hostname=}
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
  if [ -z "$HOSTNAME_VALUE" ]; then
    err "--hostname is required"
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

validate_hostname() {
  case "$HOSTNAME_VALUE" in
    *[!A-Za-z0-9.-]*)
      err "--hostname is not a valid hostname: '$HOSTNAME_VALUE'"
      err "expected [A-Za-z0-9.-]"
      usage >&2
      exit "$EXIT_USAGE"
      ;;
    [A-Za-z0-9]*) : ;;
    *)
      err "--hostname must start with a letter or digit: '$HOSTNAME_VALUE'"
      usage >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  case "$HOSTNAME_VALUE" in
    *[A-Za-z0-9]) : ;;
    *)
      err "--hostname must end with a letter or digit: '$HOSTNAME_VALUE'"
      usage >&2
      exit "$EXIT_USAGE"
      ;;
  esac
  # The installer's valid_hostname() caps hostnames at 63 characters; rejecting
  # longer values here avoids an endless "invalid hostname; try again" loop in
  # the TUI followed by a timeout.
  if [ "${#HOSTNAME_VALUE}" -gt 63 ]; then
    err "--hostname is too long (max 63 characters): '${HOSTNAME_VALUE}'"
    usage >&2
    exit "$EXIT_USAGE"
  fi
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
scalar("boot.install_tui"; ["boot", "install_tui"]),
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
    emit("boot.install_tui", ["boot", "install_tui"])
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
      boot.install_tui)
        TUI_KIND=$field1
        TUI_VALUE=$field2
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

  case "$TUI_KIND" in
    boolean)
      if [ "$TUI_VALUE" != "true" ]; then
        err "artifact field boot.install_tui must be true (got $TUI_VALUE)"
        exit "$EXIT_USAGE"
      fi
      ;;
    missing)
      err "artifact field boot.install_tui is required and must be true"
      exit "$EXIT_USAGE"
      ;;
    *)
      err "artifact field boot.install_tui must be a boolean (got '$TUI_KIND')"
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
# QEMU / expect / boot-check / firmware availability
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

resolve_expect() {
  local found=""

  if ! found=$(command -v expect 2>/dev/null); then
    err "expect not found on PATH; install expect (e.g. apt-get install expect)"
    exit "$EXIT_QEMU"
  fi
  if [ -z "$found" ] || [ -d "$found" ] || [ ! -x "$found" ]; then
    err "expect is not executable: $found"
    exit "$EXIT_QEMU"
  fi
  EXPECT_BIN=$found
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
    err "hint: run tui-install-check as the user that owns the build output, or chown the output directory"
    exit "$EXIT_USAGE"
  fi

  TUI_LOG="$ARTIFACT_DIR/tui-install.log"
  EVIDENCE_PATH="$ARTIFACT_DIR/tui-install-evidence.json"
  BOOT_LOG_COPY="$ARTIFACT_DIR/tui-install-boot.log"
  rm -f "$EVIDENCE_PATH" 2>/dev/null || true
  rm -f "$BOOT_LOG_COPY" 2>/dev/null || true
  if ! : >"$TUI_LOG" 2>/dev/null; then
    err "cannot write TUI install log: $TUI_LOG"
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
    if ! WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/sysemble-tui-install.XXXXXX" 2>/dev/null); then
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

  EXPECT_SCRIPT="$WORKDIR/tui-install.expect"
  QEMU_PIDFILE="$WORKDIR/tui-qemu.pid"
  EXPECT_STDOUT="$WORKDIR/tui-expect.stdout"
  EXPECT_STDERR="$WORKDIR/tui-expect.stderr"
  BOOT_ARTIFACT="$WORKDIR/boot-artifact.json"
  BOOT_STDOUT="$WORKDIR/boot-check.stdout"
  BOOT_STDERR="$WORKDIR/boot-check.stderr"

  # A reused caller-owned workdir may hold a stale pid from an earlier run;
  # never let cleanup signal a pid that this run did not start.
  rm -f "$QEMU_PIDFILE" "$EXPECT_STDOUT" "$EXPECT_STDERR" \
    "$BOOT_ARTIFACT" "$BOOT_STDOUT" "$BOOT_STDERR" 2>/dev/null || true
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
# Expect script
#
# Generated with a quoted heredoc so no Tcl metacharacter in this shell script is
# expanded twice. Runtime values (QEMU path, log/pid paths, timeout, hostname,
# and the QEMU argv) are passed as expect argv entries, never interpolated into
# Tcl code. `set timeout` starts at --timeout and every later expect uses the
# remaining wall-clock budget; an `after` watchdog enforces the total deadline
# even when the console keeps printing output (expect timeouts are idle-based).
# The password is sent but only `<redacted>` is written to the log.
# ---------------------------------------------------------------------------

write_expect_script() {
  if ! cat >"$EXPECT_SCRIPT" <<'EXPECT'
#!/usr/bin/expect -f
# Generated by tools/tui-install-check.sh. Do not edit.
#
# argv: qemu_bin log_path pid_path timeout_seconds hostname qemu_args...
set qemu_bin [lindex $argv 0]
set log_path [lindex $argv 1]
set pid_path [lindex $argv 2]
set timeout_seconds [lindex $argv 3]
set hostname_value [lindex $argv 4]
set qemu_args [lrange $argv 5 end]

set complete_marker "SYMBLE: install complete"
set failed_marker "SYMBLE: install failed"
set user_value "ops"
set password_value "s3cret"
set confirm_value "yes"

set qpid ""
set watchdog ""
set deadline [expr {[clock seconds] + $timeout_seconds}]
set timeout $timeout_seconds

log_file -a $log_path

# Stop QEMU and exit. QEMU gets SIGTERM here; the shell wrapper reaps it (and
# escalates to SIGKILL after a grace period) because expect must not block on a
# wedged child.
proc stop {code} {
    global qpid watchdog
    if {$watchdog ne ""} {
        catch {after cancel $watchdog}
        set watchdog ""
    }
    if {$qpid ne ""} {
        catch {exec kill -TERM $qpid}
    }
    exit $code
}

proc remaining {} {
    global deadline
    set left [expr {$deadline - [clock seconds]}]
    if {$left < 1} {
        return 0
    }
    return $left
}

# Match one frozen prompt, answer it, and record the answer in the log.
# A failure marker or EOF during the prompts is surfaced immediately.
proc answer_prompt {prompt answer label} {
    global timeout failed_marker
    set left [remaining]
    if {$left < 1} {
        stop 4
    }
    set timeout $left
    expect {
        -exact $prompt { }
        -exact $failed_marker { stop 10 }
        timeout { stop 4 }
        eof { stop 5 }
    }
    if {$answer eq ""} {
        send -- "\r"
        send_log "\n\[expect\] answer $label: <default>\n"
    } elseif {$label eq "password"} {
        # The TUI prints the prompt before running stty -echo; a tiny pause
        # keeps the typed password from being echoed into the serial log.
        after 200
        send -- "$answer\r"
        send_log "\n\[expect\] answer $label: <redacted>\n"
    } else {
        send -- "$answer\r"
        send_log "\n\[expect\] answer $label: $answer\n"
    }
}

# Absolute deadline: expect's own timeout is an idle timeout, so a guest that
# prints continuously would otherwise never time out.
set watchdog [after [expr {$timeout_seconds * 1000}] { stop 4 }]

if {[catch {spawn -noecho $qemu_bin {*}$qemu_args} spawn_error]} {
    puts stderr "expect: cannot spawn QEMU: $spawn_error"
    exit 3
}
set qpid [exp_pid]
if {$qpid eq ""} {
    puts stderr "expect: spawn returned no QEMU pid"
    stop 1
}
if {[catch {set pid_fh [open $pid_path w]} pid_error]} {
    puts stderr "expect: cannot write QEMU pid file: $pid_error"
    stop 1
} else {
    puts $pid_fh $qpid
    close $pid_fh
}

answer_prompt {SYMBLE-TUI disk [} "" "disk"
answer_prompt {SYMBLE-TUI hostname [} $hostname_value "hostname"
answer_prompt {SYMBLE-TUI user [} $user_value "user"
answer_prompt {SYMBLE-TUI password:} $password_value "password"
answer_prompt {SYMBLE-TUI confirm install to } $confirm_value "confirm"

set left [remaining]
if {$left < 1} {
    stop 4
}
set timeout $left
expect {
    -exact $complete_marker { stop 0 }
    -exact $failed_marker { stop 10 }
    timeout { stop 4 }
    eof { stop 5 }
}
# Unreachable: every expect branch above exits.
stop 1
EXPECT
  then
    err "cannot write expect script: $EXPECT_SCRIPT"
    exit "$EXIT_USAGE"
  fi
}

# ---------------------------------------------------------------------------
# Install phase
# ---------------------------------------------------------------------------

install_marker_seen() {
  [ -f "$TUI_LOG" ] && grep -Fq "$INSTALL_MARKER" "$TUI_LOG" 2>/dev/null
}

install_failed_seen() {
  [ -f "$TUI_LOG" ] && grep -Fq "$INSTALL_FAILED_MARKER" "$TUI_LOG" 2>/dev/null
}

install_failure_reason() {
  local line=""

  line=$(grep -F "$INSTALL_FAILED_MARKER" "$TUI_LOG" 2>/dev/null | tail -n 1) || line=""
  if [ -z "$line" ]; then
    line=$INSTALL_FAILED_MARKER
  else
    # The marker can share a serial line with a prompt (no newline before it),
    # so keep only the marker and its reason, never the preceding transcript.
    case "$line" in
      *"$INSTALL_FAILED_MARKER"*)
        line="${INSTALL_FAILED_MARKER}${line#*"$INSTALL_FAILED_MARKER"}"
        ;;
    esac
  fi
  printf '%s' "$line" | tr -d '\r'
}

# Stop QEMU using the pid expect recorded. QEMU is not this shell's child, so
# it cannot be reaped with wait; SIGTERM gets a 5s grace before SIGKILL (the
# same policy as install-check's stop_qemu).
stop_qemu_from_pidfile() {
  local pid=""
  local i=0

  if [ -n "$QEMU_PIDFILE" ] && [ -f "$QEMU_PIDFILE" ]; then
    pid=$(cat "$QEMU_PIDFILE" 2>/dev/null) || pid=""
    case "$pid" in
      '' | *[!0-9]*) pid="" ;;
    esac
  fi
  if [ -z "$pid" ]; then
    return 0
  fi

  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    while [ "$i" -lt 5 ]; do
      if ! kill -0 "$pid" 2>/dev/null; then
        break
      fi
      sleep 1
      i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  : >"$QEMU_PIDFILE" 2>/dev/null || true
  return 0
}

stop_expect() {
  local i=0

  if [ -z "$EXPECT_PID" ]; then
    return 0
  fi
  if kill -0 "$EXPECT_PID" 2>/dev/null; then
    kill -TERM "$EXPECT_PID" 2>/dev/null || true
    while [ "$i" -lt 3 ]; do
      if ! kill -0 "$EXPECT_PID" 2>/dev/null; then
        break
      fi
      sleep 1
      i=$((i + 1))
    done
    if kill -0 "$EXPECT_PID" 2>/dev/null; then
      kill -KILL "$EXPECT_PID" 2>/dev/null || true
    fi
  fi
  wait "$EXPECT_PID" 2>/dev/null || true
  EXPECT_PID=""
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
  local hard_deadline=0
  local hard_timeout=0
  local status=0
  local last_err=""

  build_install_args
  say "launching $QEMU_LABEL via expect (TUI installer ISO, q35/OVMF, -cdrom)"
  say "TUI log: $TUI_LOG"
  say "install deadline: ${TIMEOUT_SECONDS}s"

  : >"$EXPECT_STDOUT"
  : >"$EXPECT_STDERR"

  SECONDS=0
  "$EXPECT_BIN" -f "$EXPECT_SCRIPT" -- \
    "$QEMU_BIN" "$TUI_LOG" "$QEMU_PIDFILE" "$TIMEOUT_SECONDS" "$HOSTNAME_VALUE" \
    "${QEMU_ARGS[@]}" \
    >"$EXPECT_STDOUT" 2>"$EXPECT_STDERR" &
  EXPECT_PID=$!
  hard_deadline=$((TIMEOUT_SECONDS + HARD_TIMEOUT_GRACE))

  while kill -0 "$EXPECT_PID" 2>/dev/null; do
    if [ "$SECONDS" -ge "$hard_deadline" ]; then
      hard_timeout=1
      break
    fi
    sleep 1
  done

  if [ "$hard_timeout" -eq 1 ]; then
    warn "expect did not exit within ${hard_deadline}s; killing it"
    stop_expect
  fi

  status=0
  if [ -n "$EXPECT_PID" ]; then
    wait "$EXPECT_PID" 2>/dev/null || status=$?
    EXPECT_PID=""
  fi
  stop_qemu_from_pidfile
  INSTALL_ELAPSED=$SECONDS

  # Re-read the markers after QEMU is stopped so output written during shutdown
  # cannot be lost. A failed marker wins; a completion marker wins over any
  # expect timeout/exit status (the installation did finish).
  if install_failed_seen; then
    INSTALL_PHASE_RESULT=fail
    INSTALL_PHASE_ERROR=$(install_failure_reason)
    warn "install failed: $INSTALL_PHASE_ERROR"
    return 0
  fi
  if install_marker_seen; then
    INSTALL_PHASE_RESULT=pass
    INSTALL_MARKER_OUT=$INSTALL_MARKER
    say "install: pass (marker seen after ${INSTALL_ELAPSED}s)"
    return 0
  fi
  if [ "$hard_timeout" -eq 1 ] || [ "$status" -eq 4 ]; then
    INSTALL_PHASE_RESULT=timeout
    INSTALL_PHASE_ERROR="no \`$INSTALL_MARKER\` within ${TIMEOUT_SECONDS}s"
    warn "$INSTALL_PHASE_ERROR"
    return 0
  fi

  case "$status" in
    0)
      INSTALL_PHASE_RESULT=fail
      INSTALL_PHASE_ERROR="expect returned success but \`$INSTALL_MARKER\` is missing from $TUI_LOG"
      warn "$INSTALL_PHASE_ERROR"
      ;;
    "$EXPECT_INSTALL_FAILED")
      INSTALL_PHASE_RESULT=fail
      INSTALL_PHASE_ERROR=$(install_failure_reason)
      warn "install failed: $INSTALL_PHASE_ERROR"
      ;;
    "$EXPECT_EARLY_EXIT")
      INSTALL_PHASE_RESULT=fail
      INSTALL_PHASE_ERROR="QEMU exited before \`$INSTALL_MARKER\`"
      warn "$INSTALL_PHASE_ERROR"
      ;;
    "$EXPECT_SPAWN_FAILED")
      INSTALL_PHASE_RESULT=fail
      last_err=$(tail -n 1 "$EXPECT_STDERR" 2>/dev/null) || last_err=""
      INSTALL_PHASE_ERROR="expect could not start QEMU"
      if [ -n "$last_err" ]; then
        INSTALL_PHASE_ERROR="$INSTALL_PHASE_ERROR: $last_err"
      fi
      warn "$INSTALL_PHASE_ERROR"
      ;;
    *)
      INSTALL_PHASE_RESULT=fail
      last_err=$(tail -n 1 "$EXPECT_STDERR" 2>/dev/null) || last_err=""
      INSTALL_PHASE_ERROR="expect exited with status $status before \`$INSTALL_MARKER\`"
      if [ -n "$last_err" ]; then
        INSTALL_PHASE_ERROR="$INSTALL_PHASE_ERROR: $last_err"
      fi
      warn "$INSTALL_PHASE_ERROR"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Boot phase (delegates to tools/boot-check.sh in uefi mode)
# ---------------------------------------------------------------------------

write_boot_artifact() {
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

# The installed disk's hostname is proven by the login prompt line, e.g.
# `sysemble-tui login:`. boot-check already asserts a generic `login:`; this
# extra assertion ties the prompt to the requested hostname.
evaluate_boot_hostname() {
  BOOT_HOSTNAME_RESULT=fail
  if [ ! -f "$WORKDIR/boot.log" ]; then
    BOOT_HOSTNAME_DETAIL="boot.log is missing"
  elif [ ! -s "$WORKDIR/boot.log" ]; then
    BOOT_HOSTNAME_DETAIL="boot.log is empty"
  elif grep -Fq "$HOSTNAME_VALUE login:" "$WORKDIR/boot.log" 2>/dev/null; then
    BOOT_HOSTNAME_RESULT=pass
    BOOT_HOSTNAME_DETAIL="matched \`$HOSTNAME_VALUE login:\`"
  else
    BOOT_HOSTNAME_DETAIL="no \`$HOSTNAME_VALUE login:\` in boot.log"
  fi
}

run_boot_phase() {
  local boot_status=0
  local last_err=""

  BOOT_PHASE_RESULT=""
  BOOT_PHASE_ERROR=""
  BOOT_EVIDENCE_FILE=""

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

  evaluate_boot_hostname

  case "$boot_status" in
    0)
      if [ "$BOOT_HOSTNAME_RESULT" = "pass" ]; then
        BOOT_PHASE_RESULT=pass
        say "boot: pass (installed disk reached \`$HOSTNAME_VALUE login:\`)"
      else
        BOOT_PHASE_RESULT=fail
        BOOT_PHASE_ERROR="installed disk did not report \`$HOSTNAME_VALUE login:\` ($BOOT_HOSTNAME_DETAIL)"
        warn "$BOOT_PHASE_ERROR"
      fi
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

  # Preserve the post-install serial console beside the installer log so a CI
  # upload keeps both. boot-check writes boot.log next to its temporary artifact
  # (inside the work directory).
  if [ -f "$WORKDIR/boot.log" ]; then
    if ! cp "$WORKDIR/boot.log" "$BOOT_LOG_COPY" 2>/dev/null; then
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

  if ! EVIDENCE_TMP=$(mktemp "$ARTIFACT_DIR/.tui-install-evidence.XXXXXX" 2>/dev/null); then
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
      --arg hostname "$HOSTNAME_VALUE" \
      --arg hostnameResult "$BOOT_HOSTNAME_RESULT" \
      --arg hostnameDetail "$BOOT_HOSTNAME_DETAIL" \
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
                {boot: ({result: $bootResult,
                         assertions: ($assertions
                           + [{id: "boot.hostname", result: $hostnameResult, detail: $hostnameDetail}])}
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
      "$BOOT_PHASE_RESULT" "$BOOT_PHASE_ERROR" "$BOOT_EVIDENCE_FILE" \
      "$HOSTNAME_VALUE" "$BOOT_HOSTNAME_RESULT" "$BOOT_HOSTNAME_DETAIL" <<'PY'
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
    hostname = argv[10]
    hostname_result = argv[11]
    hostname_detail = argv[12]

    install = {"result": install_result}
    if install_marker:
        install["marker"] = install_marker
    if install_error:
        install["error"] = install_error

    phases = {"install": install}
    if boot_result:
        assertions = load_assertions(boot_evidence)
        assertions.append(
            {
                "id": "boot.hostname",
                "result": hostname_result,
                "detail": hostname_detail,
            }
        )
        boot = {"result": boot_result, "assertions": assertions}
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
  say "hostname: $HOSTNAME_VALUE"
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
  stop_expect
  stop_qemu_from_pidfile

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
      */sysemble-tui-install.*)
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
  validate_hostname
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  resolve_script_dir
  # Artifact/field errors are reported before dependency errors so a malformed
  # artifact always maps to exit 2 (install-check parity for explicit --qemu).
  resolve_artifact
  detect_json_backend
  parse_artifact
  resolve_qemu
  resolve_expect
  resolve_boot_check
  resolve_firmware
  prepare_outputs

  create_workdir
  prepare_vars_copy
  create_disk
  write_expect_script

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
