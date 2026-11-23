#!/usr/bin/env bash
# Sysemble Debian builder - shared helpers for build.sh (P0-a).
#
# This file is sourced by build.sh. It is written for bash 3.2 (the /bin/bash
# shipped by macOS) and must not use bash 4 features (mapfile, nameref, ...).
#
# It owns:
#   - JSON access (jq preferred, python3 fallback) and the record protocol
#   - plan validation
#   - engine preflight checks (native / docker)
#   - output helpers / usage text

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
Sysemble Debian builder (P0-a) - build a Debian rootfs from plan.json

Usage:
  builders/debian/build.sh --plan <plan.json> --out <dir> [--dry-run] [--engine docker|native]

Options:
  --plan <path>      plan.json produced by `sysemble plan --json`
  --out <dir>        output directory; created if missing
  --dry-run          validate the plan, print stages/packages/estimates, and
                     write only <out>/plan.copy.json
  --engine <name>    native (default) or docker
  -h, --help         show this help and exit 0

Engines:
  native   requires Linux, euid 0, and mmdebstrap on PATH; builds <out>/rootfs
  docker   runs mmdebstrap in a debian:trixie container with <out> mounted at
           /out; requires a working Docker daemon. --dry-run does not check
           the engine, so it works on hosts without Linux/Docker.

Exit codes:
  0  success (dry run, or rootfs bootstrap completed)
  1  invalid plan (malformed JSON or failed plan validation)
  2  usage or I/O error (including an unsafe --out)
  3  native engine unavailable (not Linux, not root, or no mmdebstrap)
  4  docker engine unavailable (no docker CLI or no daemon)
  5  no JSON parser available (install jq or python3)
  6  a build step failed, or <out>/rootfs already exists

P0-a scope: rootfs bootstrap only. No partitioning, bootloader, qcow2/ISO
conversion, system configuration, networking changes, or host changes.
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
