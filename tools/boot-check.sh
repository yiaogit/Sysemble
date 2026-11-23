#!/usr/bin/env bash
# Sysemble boot-check (P0-b).
#
# Boots a built disk image with QEMU and proves that the serial console reaches
# a kernel, systemd, and a login prompt. With --log-from it runs the same
# assertions against an existing log, so the assertion logic is testable on a
# host without QEMU.
#
# Contract (frozen):
#   tools/boot-check.sh --artifact <artifact.json> [--timeout 300] [--json]
#                       [--log-from <file>] [--qemu <binary>]
#
# Artifact paths (boot.kernel, boot.initrd, images[].path) are resolved relative
# to the directory holding artifact.json. Boot-check writes
# <artifact dir>/boot.log and <artifact dir>/boot-evidence.json plus a temporary
# directory under $TMPDIR. QEMU itself opens the raw image read-write because the
# artifact cmdline mounts the root filesystem rw, so the image must be writable
# by the user running boot-check. The host, network, and boot configuration are
# never modified; no sudo is used.
#
# A successful boot does not power itself off. In QEMU mode a monitor watches
# boot.log and stops QEMU as soon as all three required assertions have matched,
# which is what lets a healthily booted VM finish before --timeout.
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

ARTIFACT_ABS=""
ARTIFACT_DIR=""
JSON_BACKEND=""
TMP_DIR=""

ARCH_VALUE=""
KERNEL_REL=""
INITRD_REL=""
CMDLINE_VALUE=""
RAW_IMAGE_REL=""

KERNEL_ABS=""
INITRD_ABS=""
RAW_IMAGE_ABS=""

QEMU_LABEL=""
QEMU_BIN=""
MACHINE=""

LOG_PATH=""
LOG_EVIDENCE=""
EVIDENCE_PATH=""
LOG_HASH=""
ELAPSED=0

KERNEL_RESULT="fail"
KERNEL_DETAIL=""
SYSTEMD_RESULT="fail"
SYSTEMD_DETAIL=""
LOGIN_RESULT="fail"
LOGIN_DETAIL=""

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
Sysemble boot-check (P0-b) - prove a built image reaches a login prompt

Usage:
  tools/boot-check.sh --artifact <artifact.json> [--timeout 300] [--json]
                      [--log-from <file>] [--qemu <binary>]

Options:
  --artifact <path>  artifact.json produced by builders/debian/build.sh
  --timeout <secs>   QEMU boot deadline in whole seconds (default: 300)
  --json             print only the evidence JSON on stdout; the human summary
                     goes to stderr
  --log-from <file>  offline mode: do not run QEMU, run the assertions against
                     this existing serial log
  --qemu <binary>    QEMU binary (default: qemu-system-<arch> from PATH)
  -h, --help         show this help and exit 0

Artifact fields used (relative to the artifact.json directory):
  apiVersion must be 'sysemble/artifact/v1'
  arch       must be 'x86_64' or 'aarch64'
  boot.kernel / boot.initrd must exist
  images[]   must contain an entry with format 'raw' whose path exists
  boot.cmdline is passed to QEMU -append

QEMU opens the raw image read-write (the cmdline mounts the root filesystem rw)
and boot-check writes boot.log/boot-evidence.json beside artifact.json, so the
artifact directory and raw image must be writable by the invoking user.

Assertions (all required):
  boot.kernel   serial log contains 'Linux version'
  boot.systemd  serial log contains 'systemd[1]' or 'Reached target'
  boot.login    serial log contains 'login:'

In QEMU mode all three must pass before --timeout; QEMU is stopped as soon as
they do. A timeout keeps the partial boot.log and reports result 'timeout'.

Exit codes:
  0  all assertions passed
  1  one or more assertions failed
  2  usage, file, JSON, or evidence I/O error
  3  QEMU is unavailable
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

  resolve_artifact_file "boot.kernel" "$KERNEL_REL"
  KERNEL_ABS=$RESOLVED_FILE
  resolve_artifact_file "boot.initrd" "$INITRD_REL"
  INITRD_ABS=$RESOLVED_FILE
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

all_assertions_pass() {
  log_has 'Linux version' || return 1
  if ! log_has 'systemd[1]' && ! log_has 'Reached target'; then
    return 1
  fi
  log_has 'login:'
}

# Set KERNEL_RESULT/KERNEL_DETAIL, SYSTEMD_RESULT/SYSTEMD_DETAIL, and
# LOGIN_RESULT/LOGIN_DETAIL from the current log. A missing or empty log is an
# assertion failure, never an I/O error.
evaluate_assertions() {
  local log_state="ok"

  if [ ! -f "$LOG_PATH" ]; then
    log_state="missing"
  elif [ ! -s "$LOG_PATH" ]; then
    log_state="empty"
  fi

  if log_has 'Linux version'; then
    KERNEL_RESULT=pass
    KERNEL_DETAIL="matched \`Linux version\`"
  else
    KERNEL_RESULT=fail
    if [ "$log_state" = "missing" ]; then
      KERNEL_DETAIL="log file is missing"
    elif [ "$log_state" = "empty" ]; then
      KERNEL_DETAIL="log is empty"
    elif [ "$TIMED_OUT" -eq 1 ]; then
      KERNEL_DETAIL="no \`Linux version\` within ${TIMEOUT_SECONDS}s"
    else
      KERNEL_DETAIL="no \`Linux version\` in log"
    fi
  fi

  if log_has 'systemd[1]' || log_has 'Reached target'; then
    SYSTEMD_RESULT=pass
    if log_has 'systemd[1]' && log_has 'Reached target'; then
      SYSTEMD_DETAIL="matched \`systemd[1]\` and \`Reached target\`"
    elif log_has 'systemd[1]'; then
      SYSTEMD_DETAIL="matched \`systemd[1]\`"
    else
      SYSTEMD_DETAIL="matched \`Reached target\`"
    fi
  else
    SYSTEMD_RESULT=fail
    if [ "$log_state" = "missing" ]; then
      SYSTEMD_DETAIL="log file is missing"
    elif [ "$log_state" = "empty" ]; then
      SYSTEMD_DETAIL="log is empty"
    elif [ "$TIMED_OUT" -eq 1 ]; then
      SYSTEMD_DETAIL="no \`systemd[1]\` or \`Reached target\` within ${TIMEOUT_SECONDS}s"
    else
      SYSTEMD_DETAIL="no \`systemd[1]\` or \`Reached target\` in log"
    fi
  fi

  if log_has 'login:'; then
    LOGIN_RESULT=pass
    LOGIN_DETAIL="matched \`login:\`"
  else
    LOGIN_RESULT=fail
    if [ "$log_state" = "missing" ]; then
      LOGIN_DETAIL="log file is missing"
    elif [ "$log_state" = "empty" ]; then
      LOGIN_DETAIL="log is empty"
    elif [ "$TIMED_OUT" -eq 1 ]; then
      LOGIN_DETAIL="no \`login:\` within ${TIMEOUT_SECONDS}s"
    else
      LOGIN_DETAIL="no \`login:\` in log"
    fi
  fi
}

determine_result() {
  if [ "$TIMED_OUT" -eq 1 ] && [ "$SUCCEEDED" -eq 0 ]; then
    RESULT=timeout
    return 0
  fi
  if [ "$KERNEL_RESULT" = "pass" ] &&
    [ "$SYSTEMD_RESULT" = "pass" ] &&
    [ "$LOGIN_RESULT" = "pass" ]; then
    RESULT=pass
  else
    RESULT=fail
  fi
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

  case "$RAW_IMAGE_REL" in
    *,*)
      err "raw image path contains a comma, which cannot be expressed in QEMU -drive: $RAW_IMAGE_REL"
      exit "$EXIT_USAGE"
      ;;
  esac

  # QEMU opens the raw image read-write (the artifact cmdline mounts the root
  # filesystem rw), so a root-owned 0644 image from a sudo build cannot boot.
  # Fail early with an actionable diagnostic instead of letting QEMU emit a
  # permission error that would look like a boot assertion failure.
  if [ ! -w "$RAW_IMAGE_ABS" ]; then
    err "raw image is not writable by this user: $RAW_IMAGE_ABS"
    err "hint: run boot-check as the user that owns the build output, or chown the output directory"
    exit "$EXIT_USAGE"
  fi

  LOG_PATH="$ARTIFACT_DIR/boot.log"
  LOG_EVIDENCE="boot.log"
  EVIDENCE_PATH="$ARTIFACT_DIR/boot-evidence.json"
  done_flag="$TMP_DIR/done.flag"

  if ! : >"$LOG_PATH" 2>/dev/null; then
    err "cannot write boot log: $LOG_PATH"
    exit "$EXIT_USAGE"
  fi

  qemu_args=(
    -machine "$MACHINE"
    -m 1024
    -smp 2
    -nographic
    -no-reboot
    -kernel "$KERNEL_ABS"
    -initrd "$INITRD_ABS"
    -append "$CMDLINE_VALUE"
    -drive "file=$RAW_IMAGE_ABS,format=raw,if=virtio"
  )

  say "launching $QEMU_LABEL (-machine $MACHINE, timeout ${TIMEOUT_SECONDS}s)"
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
      --arg kernel_result "$KERNEL_RESULT" \
      --arg kernel_detail "$KERNEL_DETAIL" \
      --arg systemd_result "$SYSTEMD_RESULT" \
      --arg systemd_detail "$SYSTEMD_DETAIL" \
      --arg login_result "$LOGIN_RESULT" \
      --arg login_detail "$LOGIN_DETAIL" \
      --arg log "$LOG_EVIDENCE" \
      --arg log_sha256 "$LOG_HASH" \
      '{
        apiVersion: $apiVersion,
        artifact: $artifact,
        qemu: $qemu,
        timeout_seconds: $timeout_seconds,
        elapsed_seconds: $elapsed_seconds,
        result: $result,
        assertions: [
          {id: "boot.kernel", result: $kernel_result, detail: $kernel_detail},
          {id: "boot.systemd", result: $systemd_result, detail: $systemd_detail},
          {id: "boot.login", result: $login_result, detail: $login_detail}
        ],
        log: $log,
        log_sha256: $log_sha256
      }' >"$tmp"; then
      err "failed to render evidence JSON"
      return 1
    fi
  else
    if ! python3 - "$tmp" "$ARTIFACT_ABS" "$QEMU_LABEL" "$TIMEOUT_SECONDS" \
      "$ELAPSED" "$RESULT" "$KERNEL_RESULT" "$KERNEL_DETAIL" \
      "$SYSTEMD_RESULT" "$SYSTEMD_DETAIL" "$LOGIN_RESULT" "$LOGIN_DETAIL" \
      "$LOG_EVIDENCE" "$LOG_HASH" <<'PY'
import json
import sys


def main(argv):
    out = argv[1]
    evidence = {
        "apiVersion": "sysemble/boot-evidence/v1",
        "artifact": argv[2],
        "qemu": argv[3],
        "timeout_seconds": int(argv[4]),
        "elapsed_seconds": int(argv[5]),
        "result": argv[6],
        "assertions": [
            {
                "id": "boot.kernel",
                "result": argv[7],
                "detail": argv[8],
            },
            {
                "id": "boot.systemd",
                "result": argv[9],
                "detail": argv[10],
            },
            {
                "id": "boot.login",
                "result": argv[11],
                "detail": argv[12],
            },
        ],
        "log": argv[13],
        "log_sha256": argv[14],
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
  if [ -n "$LOG_FROM" ]; then
    say "mode: offline (--log-from $LOG_FROM)"
  fi
  say "artifact: $ARTIFACT_ABS"
  say "qemu: $QEMU_LABEL (timeout ${TIMEOUT_SECONDS}s)"
  say "boot.kernel: $KERNEL_RESULT - $KERNEL_DETAIL"
  say "boot.systemd: $SYSTEMD_RESULT - $SYSTEMD_DETAIL"
  say "boot.login: $LOGIN_RESULT - $LOGIN_DETAIL"
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
