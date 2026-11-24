#!/usr/bin/env bash
# Sysemble engine container smoke test (P1-e2a, container contract v2).
#
# Proves K4 + K5 of docs/plan/P1-e2-workplan.md section 4 end to end in one
# image. Contract v2 (section 2.3) builds inside the container's own
# case-sensitive filesystem and exports only the top-level artifacts, because a
# Debian rootfs cannot be assembled directly on a case-insensitive host
# filesystem (macOS APFS: `pam.7.gz -> PAM.7.gz` becomes a symlink loop).
#
#   phase 1  docker run --rm --init --privileged --platform linux/amd64 \
#              -v <repo>:/work:ro -v <out>:/export -w /work <image> \
#              bash engine/runtime/container-entry.sh \
#                --plan /export/plan.json --out /out --export /export --mode execute
#   phase 2  docker run --rm --init --privileged --platform linux/amd64 \
#              -v <repo>:/work:ro -v <out>:/out -w /work <image> \
#              bash tools/boot-check.sh --artifact /out/artifact.json \
#                --timeout <boot-timeout> --json
#
# The caller writes <out>/plan.json first, for example:
#   mkdir -p /tmp/engine-smoke
#   cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml \
#     > /tmp/engine-smoke/plan.json
#
# The container entry script runs builders/debian/build.sh with /out as the
# build directory and exports artifact.json, disk.img, disk.qcow2 (and any
# *.iso) into /export; the host paths (including non-ASCII ones) never reach the
# container. Phase 2 mounts the exported files back at /out so the UEFI
# boot-check can find artifact.json and the raw disk image it boots.
#
# Requires bash 3.2+ (macOS /bin/bash). Do not use bash 4 features.
# Host requirements: docker CLI + daemon. The image must already be built and
# loaded (engine/image/build-image.sh).

set -euo pipefail

case "$0" in
  */*) SCRIPT_DIR=${0%/*} ;;
  *) SCRIPT_DIR=. ;;
esac
SCRIPT_DIR=$(cd "$SCRIPT_DIR" && pwd -P)
IMAGE_DIR=$(cd "$SCRIPT_DIR/.." && pwd -P)
REPO_ROOT=$(cd "$IMAGE_DIR/../.." && pwd -P)

PLATFORM="linux/amd64"
IMAGE=""
REPO=""
OUT=""
BOOT_TIMEOUT=900
START_SECONDS=$SECONDS

DOCKER_BUILD_LOG=""
DOCKER_BOOT_LOG=""

usage() {
  cat <<EOF
Usage: engine/image/tests/container_smoke.sh --image <ref> --repo <dir> --out <dir> [options]

Build a minimal Debian image inside the engine container and boot-verify it in
the same image. <out>/plan.json must exist before the run. The build runs in the
container's /out; artifact.json, disk.img, disk.qcow2 (and any ISO) are exported
to <out>, then boot-check runs against /out.

Options:
  --image <ref>          engine image reference (required), e.g. sysemble-engine:0.1.0
  --repo <dir>           repository root mounted read-only at /work (required)
  --out <dir>            host output/export directory (required); plan.json must
                         already be there
  --boot-timeout <secs>  boot-check timeout in seconds (default: 900)
  -h, --help             show this help and exit 0

Outputs under <out>: artifact.json, disk.img, disk.qcow2, plan.copy.json,
boot.log, boot-evidence.json, container-build.log, container-boot-check.log.

Exit codes: 0 pass, 1 build/boot/assert failure, 2 usage error.
EOF
}

usage_error() {
  printf 'container-smoke: error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

die() {
  printf 'container-smoke: error: %s\n' "$*" >&2
  exit 1
}

smoke_fail() {
  printf 'CONTAINER-SMOKE: fail (%s)\n' "$*" >&2
  exit 1
}

note() {
  printf 'container-smoke: %s\n' "$*"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --image)
        [ "$#" -ge 2 ] || usage_error "--image requires a value"
        IMAGE=$2
        shift 2
        ;;
      --repo)
        [ "$#" -ge 2 ] || usage_error "--repo requires a directory"
        REPO=$2
        shift 2
        ;;
      --out)
        [ "$#" -ge 2 ] || usage_error "--out requires a directory"
        OUT=$2
        shift 2
        ;;
      --boot-timeout)
        [ "$#" -ge 2 ] || usage_error "--boot-timeout requires a number of seconds"
        BOOT_TIMEOUT=$2
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage_error "unknown argument: $1"
        ;;
    esac
  done

  [ -n "$IMAGE" ] || usage_error "--image is required"
  [ -n "$REPO" ] || usage_error "--repo is required"
  [ -n "$OUT" ] || usage_error "--out is required"
  case "$BOOT_TIMEOUT" in
    '' | *[!0-9]*) usage_error "--boot-timeout must be a positive integer, got '$BOOT_TIMEOUT'" ;;
  esac
  [ "$BOOT_TIMEOUT" -gt 0 ] || usage_error "--boot-timeout must be greater than zero"
}

prepare_paths() {
  command -v docker >/dev/null 2>&1 ||
    die "docker CLI not found on PATH; start Docker Desktop (or install docker) and retry"

  [ -d "$REPO" ] || die "repo directory not found: $REPO"
  REPO=$(cd "$REPO" && pwd -P)

  mkdir -p "$OUT" || die "cannot create output directory: $OUT"
  OUT=$(cd "$OUT" && pwd -P)

  local write_probe="$OUT/.sysemble-write-probe.$$"
  : >"$write_probe" 2>/dev/null || die "output directory is not writable: $OUT"
  rm -f "$write_probe"

  [ -f "$REPO/engine/runtime/container-entry.sh" ] ||
    die "container entry script not found: $REPO/engine/runtime/container-entry.sh (wrong --repo?)"
  [ -f "$REPO/builders/debian/build.sh" ] ||
    die "builder not found: $REPO/builders/debian/build.sh (wrong --repo?)"
  [ -f "$REPO/tools/boot-check.sh" ] ||
    die "boot-check not found: $REPO/tools/boot-check.sh (wrong --repo?)"
  [ -f "$OUT/plan.json" ] ||
    die "missing $OUT/plan.json; write the plan first:
  cargo run -q -p sysemble-cli -- plan examples/minimal-debian.yaml > $OUT/plan.json"

  docker image inspect "$IMAGE" >/dev/null 2>&1 ||
    die "image '$IMAGE' is not present locally; build it first:
  bash engine/image/build-image.sh --ref $IMAGE --out engine/image/build"

  DOCKER_BUILD_LOG="$OUT/container-build.log"
  DOCKER_BOOT_LOG="$OUT/container-boot-check.log"
}

dump_tail() {
  local label=$1
  local file=$2
  local lines=${3:-60}
  if [ -f "$file" ]; then
    printf -- '--- %s (last %s lines): %s ---\n' "$label" "$lines" "$file" >&2
    tail -n "$lines" "$file" >&2 2>/dev/null || true
  else
    printf -- '--- %s: %s not found ---\n' "$label" "$file" >&2
  fi
  return 0
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{ print $NF }'
  else
    printf 'unavailable\n'
  fi
}

file_size() {
  wc -c <"$1" | tr -d '[:space:]'
}

# Phase 1: the builder writes to the container-local /out (case-sensitive); the
# entry script exports only top-level regular files to /export (= host <out>).
run_phase1_build() {
  note "phase 1/2: build inside $IMAGE"
  note "  repo: $REPO -> /work (read-only)"
  note "  out:  $OUT -> /export (build directory: /out inside the container)"
  if ! docker run --rm --init --privileged --platform linux/amd64 \
    -v "$REPO":/work:ro \
    -v "$OUT":/export \
    -w /work \
    "$IMAGE" \
    bash engine/runtime/container-entry.sh \
    --plan /export/plan.json \
    --out /out \
    --export /export \
    --mode execute \
    2>&1 | tee "$DOCKER_BUILD_LOG"; then
    dump_tail "container build output" "$DOCKER_BUILD_LOG" 80
    smoke_fail "phase 1 container build failed"
  fi
  note "phase 1/2: done"
}

# Phase 2: boot-verify the exported artifact with the same image. The exported
# disk.img/disk.qcow2/artifact.json are mounted at /out; boot-check writes
# boot.log and boot-evidence.json there.
run_phase2_boot() {
  note "phase 2/2: boot-check inside $IMAGE (timeout ${BOOT_TIMEOUT}s)"
  if ! docker run --rm --init --privileged --platform linux/amd64 \
    -v "$REPO":/work:ro \
    -v "$OUT":/out \
    -w /work \
    "$IMAGE" \
    bash tools/boot-check.sh --artifact /out/artifact.json \
    --timeout "$BOOT_TIMEOUT" --json \
    2>&1 | tee "$DOCKER_BOOT_LOG"; then
    dump_tail "container build output" "$DOCKER_BUILD_LOG" 80
    dump_tail "boot log" "$OUT/boot.log" 80
    dump_tail "container boot-check output" "$DOCKER_BOOT_LOG" 60
    smoke_fail "phase 2 boot-check failed"
  fi
  note "phase 2/2: done"
}

ASSERT_FAILURES=0

require_file() {
  local label=$1
  local path=$2
  if [ -f "$path" ] && [ -s "$path" ]; then
    printf 'OK    %s: %s (%s bytes)\n' "$label" "$path" "$(file_size "$path")"
  else
    ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
    printf 'FAIL  %s: %s is missing or empty\n' "$label" "$path"
  fi
}

collect_qcow2() {
  local file=""
  local found=0
  for file in "$OUT"/*.qcow2; do
    [ -e "$file" ] || continue
    found=$((found + 1))
  done
  printf '%s\n' "$found"
}

assert_outputs() {
  note "asserting exported artifacts"
  require_file "artifact.json" "$OUT/artifact.json"
  require_file "raw disk image (disk.img, UEFI boot target)" "$OUT/disk.img"
  require_file "qcow2 disk image (disk.qcow2)" "$OUT/disk.qcow2"
  require_file "boot evidence" "$OUT/boot-evidence.json"

  local qcow2_count=0
  qcow2_count=$(collect_qcow2)
  if [ "$qcow2_count" -ge 1 ]; then
    printf 'OK    qcow2 image(s) exported: %s\n' "$qcow2_count"
  else
    ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
    printf 'FAIL  qcow2 image: no *.qcow2 in %s\n' "$OUT"
  fi

  if [ "$ASSERT_FAILURES" -ne 0 ]; then
    dump_tail "container build output" "$DOCKER_BUILD_LOG" 80
    smoke_fail "$ASSERT_FAILURES expected output(s) missing"
  fi
}

print_evidence() {
  local file=""
  note "artifact sha256:"
  for file in \
    "$OUT/artifact.json" \
    "$OUT/disk.img" \
    "$OUT/boot-evidence.json"; do
    [ -f "$file" ] || continue
    printf '  sha256 %s  %s bytes  %s\n' \
      "$(file_sha256 "$file")" "$(file_size "$file")" "${file#"$OUT"/}"
  done
  for file in "$OUT"/*.qcow2; do
    [ -f "$file" ] || continue
    printf '  sha256 %s  %s bytes  %s\n' \
      "$(file_sha256 "$file")" "$(file_size "$file")" "${file#"$OUT"/}"
  done
}

main() {
  parse_args "$@"
  prepare_paths

  note "image: $IMAGE (platform $PLATFORM)"
  run_phase1_build
  run_phase2_boot
  assert_outputs
  print_evidence

  local elapsed=$((SECONDS - START_SECONDS))
  note "elapsed: ${elapsed}s"
  printf 'CONTAINER-SMOKE: pass\n'
  exit 0
}

main "$@"
