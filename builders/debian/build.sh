#!/usr/bin/env bash
# Sysemble Debian builder (P0-a).
#
# Reads a plan.json produced by `sysemble plan --json` and bootstraps a Debian
# rootfs with mmdebstrap, either natively (Linux/root) or inside a
# debian:trixie Docker container. --dry-run validates the plan and prints the
# plan without touching the engine.
#
# Contract (frozen):
#   build.sh --plan <plan.json> --out <dir> [--dry-run] [--engine docker|native]
#
# Only builders/** is modified by this script at runtime: the rootfs and a
# plan.copy.json are written under --out. The host system, network
# configuration, and boot configuration are never touched.
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
ENGINE="native"

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
  info "[build] stage 6/6: assemble image - not implemented in P0-a (skipped)"
  warn "rootfs is bootstrapped but not configured; requested outputs ($OUTPUTS_TEXT) were not assembled (P0-b)"
  info "rootfs ready: $rootfs"
}

build_native() {
  local rootfs="$OUT_ABS/rootfs"
  local pkg_csv=""

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
  info "[build] stage 2/6: fetch base - $PLAN_BASE_KIND_VALUE/$PLAN_BASE_RELEASE_VALUE"
  info "[build] stage 3/6: bootstrap rootfs - $rootfs"
  info "[build] stage 4/6: install packages - $PKG_COUNT packages via --include"

  if ! mmdebstrap --variant=minbase --include="$pkg_csv" \
    "$PLAN_BASE_RELEASE_VALUE" "$rootfs"; then
    err "mmdebstrap failed; no complete rootfs was produced"
    return 6
  fi
  if [ ! -d "$rootfs" ]; then
    err "mmdebstrap reported success but $rootfs is missing"
    return 6
  fi

  finish_rootfs_only "$rootfs"
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
    prepare_out || exit 2
    copy_plan || exit 2
    build_native || exit 6
  else
    docker_preflight || exit 4
    prepare_out || exit 2
    copy_plan || exit 2
    build_docker || exit 6
  fi

  exit 0
}

main "$@"
