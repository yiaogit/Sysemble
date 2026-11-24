#!/usr/bin/env bash
# Sysemble VM image build (P1-e3a).
#
# Contract (frozen): docs/plan/P1-e3-workplan.md section 2.1.
#
#   build-image.sh [--ref <name>] [--out <dir>] [--engine auto|docker|native]
#                  [--no-cache] [--verify <dir>] [--help]
#
# Builds the arm64 engine VM image and writes <out>/{disk.img,vmlinuz,initrd.img,
# sysemble-vm.json}:
#
#   - macOS: Docker Desktop runs the privileged debian:trixie container with
#     --platform linux/arm64 (native arm64, no emulation).
#   - Linux arm64: docker when the daemon is available, otherwise the same
#     in-container script directly as root/sudo (native).
#
# The heavy lifting lives in in-container-build.sh, which runs apt-get,
# mmdebstrap, systemctl --root, mke2fs and the manifest collector. This script
# only chooses the engine, mounts the repo read-only at /src and the output at
# /out, streams the build log, and then verifies the manifest on the *host* with
# python3 (the container may not be usable afterwards).
#
# --verify re-checks an existing manifest: schema/name/version/arch, kernel
# release, disk size, and the sha256 of kernel/initrd/disk against the files.
#
# Requires bash 3.2+ (macOS /bin/bash, GitHub ubuntu-*-arm). No bash 4-only
# constructs (no mapfile, no associative arrays, no ${x,,}).

set -euo pipefail

case "$0" in
  */*) SCRIPT_DIR=${0%/*} ;;
  *) SCRIPT_DIR=. ;;
esac
SCRIPT_DIR=$(cd "$SCRIPT_DIR" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd -P)

VERSION_FILE="$SCRIPT_DIR/version"
IN_CONTAINER="$SCRIPT_DIR/in-container-build.sh"
MANIFEST_NAME="sysemble-vm.json"
BUILD_IMAGE_REF=${SYSEMBLE_VM_BUILD_IMAGE:-debian:trixie}

REF=""
OUT=""
ENGINE="auto"
NO_CACHE=0
VERIFY_DIR=""
VERSION=""
HOST_OS=""
HOST_ARCH=""
NATIVE_PREFIX=""
START_SECONDS=$SECONDS

cleanup() {
  # Nothing to clean up: every artifact stays in --out for the caller and the
  # container is --rm. Keep the trap so interrupts exit with a shell status.
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

note() {
  printf 'build-image: %s\n' "$*"
}

warn() {
  printf 'build-image: warning: %s\n' "$*" >&2
}

die() {
  printf 'build-image: error: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf 'build-image: error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

usage() {
  local help_version="0.1.0"
  if [ -f "$VERSION_FILE" ]; then
    help_version=$(tr -d '[:space:]' <"$VERSION_FILE" 2>/dev/null || true)
    [ -n "$help_version" ] || help_version="0.1.0"
  fi
  cat <<EOF
Usage: engine/vm/image/build-image.sh [options]

Build the Sysemble arm64 engine VM image and write <out>/$MANIFEST_NAME.
--verify checks an existing image directory instead of building.

Options:
  --ref <name>        manifest label, not a docker tag (default:
                      sysemble-vm:$help_version)
  --out <dir>         output directory (default: engine/vm/image/build)
  --engine <name>     auto | docker | native (default: auto)
                      auto: macOS -> docker; Linux arm64 -> docker when the
                      daemon is reachable, otherwise native (sudo/root)
  --no-cache          docker: pull the base image again (--pull=always);
                      native: accepted and ignored
  --verify <dir>      verify <dir>/$MANIFEST_NAME and its files; does not build
  -h, --help          show this help and exit 0

Environment:
  SYSEMBLE_VM_BUILD_IMAGE   container image used by --engine docker
                            (default: debian:trixie)
  SOURCE_DATE_EPOCH         optional UTC epoch recorded as "created"

Exit codes: 0 success, 1 build/verify failure, 2 usage error.
EOF
}

# ---------------------------------------------------------------------------
# Arguments and static inputs
# ---------------------------------------------------------------------------

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ref)
        [ "$#" -ge 2 ] || usage_error "--ref requires a value"
        REF=$2
        shift 2
        ;;
      --out)
        [ "$#" -ge 2 ] || usage_error "--out requires a directory"
        OUT=$2
        shift 2
        ;;
      --engine)
        [ "$#" -ge 2 ] || usage_error "--engine requires a value"
        ENGINE=$2
        shift 2
        ;;
      --no-cache)
        NO_CACHE=1
        shift
        ;;
      --verify)
        [ "$#" -ge 2 ] || usage_error "--verify requires a directory"
        VERIFY_DIR=$2
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
}

load_version() {
  [ -f "$VERSION_FILE" ] || die "version file not found: $VERSION_FILE"
  VERSION=$(tr -d '[:space:]' <"$VERSION_FILE")
  [ -n "$VERSION" ] || die "version file is empty: $VERSION_FILE"
  case "$VERSION" in
    *[!0-9A-Za-z.+-]*) die "version file contains unsupported characters: '$VERSION'" ;;
  esac
}

validate_inputs() {
  load_version

  [ -n "$REF" ] || REF="sysemble-vm:$VERSION"
  [ -n "$OUT" ] || OUT="$SCRIPT_DIR/build"

  case "$ENGINE" in
    auto | docker | native) ;;
    *) usage_error "--engine must be auto, docker or native (got '$ENGINE')" ;;
  esac

  case "$REF" in
    *[[:space:]]*) usage_error "--ref must not contain whitespace: '$REF'" ;;
    -*) usage_error "--ref must not start with '-': '$REF'" ;;
  esac

  HOST_OS=$(uname -s)
  HOST_ARCH=$(uname -m)
}

host_arch_is_arm64() {
  case "$HOST_ARCH" in
    arm64 | aarch64) return 0 ;;
    *) return 1 ;;
  esac
}

require_arm64_host() {
  host_arch_is_arm64 ||
    die "the VM image is arm64-only: Virtualization.framework on Apple Silicon cannot boot another guest arch (host reports '$HOST_ARCH' on $HOST_OS)"
}

require_python() {
  command -v python3 >/dev/null 2>&1 ||
    die "python3 is required to verify $MANIFEST_NAME on the host (jq is not required on the host)"
}

docker_daemon_available() {
  command -v docker >/dev/null 2>&1 || return 1
  docker info --format '{{.ServerVersion}}' >/dev/null 2>&1
}

require_docker() {
  command -v docker >/dev/null 2>&1 ||
    die "docker CLI not found on PATH; start Docker Desktop (or install docker) and retry"
  docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 ||
    die "docker daemon is not reachable; start Docker Desktop and retry (Linux arm64 can also use --engine native with sudo)"
}

prepare_native() {
  [ "$HOST_OS" = "Linux" ] ||
    die "--engine native requires Linux arm64: mmdebstrap cannot bootstrap Debian as root on $HOST_OS (use --engine docker on macOS)"
  require_arm64_host

  if [ "$(id -u)" -eq 0 ]; then
    NATIVE_PREFIX=""
    return 0
  fi
  command -v sudo >/dev/null 2>&1 ||
    die "native build requires root and sudo is not installed; rerun as root"
  NATIVE_PREFIX="sudo"
  note "native build elevates with sudo (CI arm64 runners have passwordless sudo)"
}

resolve_engine() {
  case "$ENGINE" in
    auto)
      if [ "$HOST_OS" = "Darwin" ]; then
        ENGINE=docker
      elif [ "$HOST_OS" = "Linux" ]; then
        if docker_daemon_available; then
          ENGINE=docker
        else
          ENGINE=native
        fi
      else
        die "unsupported host OS '$HOST_OS': use a macOS Apple Silicon host or an arm64 Linux host"
      fi
      ;;
  esac

  case "$ENGINE" in
    docker)
      require_arm64_host
      require_docker
      ;;
    native)
      prepare_native
      ;;
  esac
  note "engine: $ENGINE (host $HOST_OS/$HOST_ARCH)"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

run_docker() {
  local docker_args=(docker run --rm --privileged --platform linux/arm64)

  if [ "$NO_CACHE" -eq 1 ]; then
    docker_args+=(--pull=always)
  fi
  docker_args+=(
    -v "$REPO_ROOT":/src:ro
    -v "$OUT":/out
    "$BUILD_IMAGE_REF"
    bash /src/engine/vm/image/in-container-build.sh
    --out /out
    --ref "$REF"
  )

  note "docker: ${BUILD_IMAGE_REF} (platform linux/arm64, --privileged)"
  note "repo:   $REPO_ROOT (read-only at /src)"
  note "out:    $OUT (bind mount at /out)"
  # The pipeline's exit status is docker's (pipefail), not tee's.
  if ! "${docker_args[@]}" 2>&1 | tee "$BUILD_LOG"; then
    die "docker build failed (see $BUILD_LOG); the container output above is the full log"
  fi
}

run_native() {
  if [ "$NO_CACHE" -eq 1 ]; then
    warn "--no-cache only affects --engine docker; ignored for native"
  fi
  note "native: bash $IN_CONTAINER --out $OUT --ref $REF"
  if [ -n "$NATIVE_PREFIX" ]; then
    # shellcheck disable=SC2086
    if ! $NATIVE_PREFIX bash "$IN_CONTAINER" --out "$OUT" --ref "$REF" 2>&1 | tee "$BUILD_LOG"; then
      die "native build failed (see $BUILD_LOG); the output above is the full log"
    fi
  else
    if ! bash "$IN_CONTAINER" --out "$OUT" --ref "$REF" 2>&1 | tee "$BUILD_LOG"; then
      die "native build failed (see $BUILD_LOG); the output above is the full log"
    fi
  fi
}

build_image() {
  mkdir -p "$OUT" || die "cannot create output directory: $OUT"
  OUT=$(cd "$OUT" && pwd -P)
  BUILD_LOG="$OUT/build-image.log"

  resolve_engine

  note "ref:    $REF"
  note "log:    $BUILD_LOG"

  if [ "$ENGINE" = "docker" ]; then
    run_docker
  else
    run_native
  fi

  local file=""
  for file in disk.img vmlinuz initrd.img "$MANIFEST_NAME"; do
    [ -f "$OUT/$file" ] || die "the build reported success but $OUT/$file is missing"
  done

  note "verifying the manifest on the host"
  verify_manifest "$OUT"
}

summary() {
  local elapsed=$((SECONDS - START_SECONDS))
  local disk_allocated_kb=""

  disk_allocated_kb=$(du -k "$OUT/disk.img" | cut -f 1) || disk_allocated_kb=""
  note "artifacts:"
  ls -lh "$OUT/disk.img" "$OUT/vmlinuz" "$OUT/initrd.img" "$OUT/$MANIFEST_NAME" || true
  note "disk.img logical=$(stat -c %s "$OUT/disk.img" 2>/dev/null || stat -f %z "$OUT/disk.img") bytes, allocated=$(( ${disk_allocated_kb:-0} * 1024 )) bytes"
  note "manifest: $OUT/$MANIFEST_NAME"
  note "elapsed:  ${elapsed}s"
}

# ---------------------------------------------------------------------------
# Verify (host side, python3)
# ---------------------------------------------------------------------------

verify_manifest() {
  local dir=$1
  local manifest="$dir/$MANIFEST_NAME"

  [ -f "$manifest" ] ||
    die "verify: manifest not found: $manifest (run build-image.sh first)"

  python3 - "$dir" "$MANIFEST_NAME" "$VERSION" <<'PY'
import hashlib
import json
import os
import re
import sys

directory, manifest_name, expected_version = sys.argv[1:4]
manifest_path = os.path.join(directory, manifest_name)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def fail(message):
    print("verify: error: %s" % message, file=sys.stderr)
    sys.exit(1)


def sha256_file(path):
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        fail("cannot read %s: %s" % (path, exc))
    return digest.hexdigest()


def require_file(entry, key, label):
    if not isinstance(entry, dict):
        fail("manifest %s is not an object" % label)
    path = entry.get("path")
    if not isinstance(path, str) or not path:
        fail("manifest %s.path is missing" % label)
    if os.path.basename(path) != path or path in (".", ".."):
        fail("manifest %s.path '%s' must be a plain file name" % (label, path))
    full_path = os.path.join(directory, path)
    if not os.path.isfile(full_path):
        fail("%s file not found: %s" % (label, full_path))
    recorded = entry.get("sha256")
    if not isinstance(recorded, str) or not SHA256_RE.match(recorded):
        fail("manifest %s.sha256 is missing or not 64 lowercase hex characters" % label)
    actual = sha256_file(full_path)
    if actual != recorded:
        fail("%s sha256 mismatch: manifest %s, file %s (%s)"
             % (label, recorded, actual, full_path))
    return entry, full_path


try:
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
except OSError as exc:
    fail("cannot read %s: %s" % (manifest_path, exc))
except ValueError as exc:
    fail("%s is not valid JSON: %s" % (manifest_path, exc))

if not isinstance(manifest, dict):
    fail("manifest is not a JSON object")
if manifest.get("schema") != 1:
    fail("manifest schema must be 1, got %r" % (manifest.get("schema"),))
if manifest.get("name") != "sysemble-vm":
    fail("manifest name must be 'sysemble-vm', got %r" % (manifest.get("name"),))
if manifest.get("version") != expected_version:
    fail("manifest version must be '%s', got %r"
         % (expected_version, manifest.get("version")))
if manifest.get("arch") != "arm64":
    fail("manifest arch must be 'arm64', got %r" % (manifest.get("arch"),))

kernel, kernel_path = require_file(manifest.get("kernel"), "kernel", "kernel")
initrd, initrd_path = require_file(manifest.get("initrd"), "initrd", "initrd")
disk, disk_path = require_file(manifest.get("disk"), "disk", "disk")

release = kernel.get("release")
if not isinstance(release, str) or not release.strip():
    fail("manifest kernel.release is empty")

size_bytes = disk.get("size_bytes")
if not isinstance(size_bytes, int) or isinstance(size_bytes, bool) or size_bytes <= 0:
    fail("manifest disk.size_bytes must be a positive integer, got %r" % (size_bytes,))
actual_size = os.path.getsize(disk_path)
if actual_size != size_bytes:
    fail("disk.size_bytes %d does not match the file size %d" % (size_bytes, actual_size))

guest = manifest.get("guest")
if not isinstance(guest, dict):
    fail("manifest guest is not an object")
if guest.get("agent_unit") != "sysemble-vm-agent.service":
    fail("manifest guest.agent_unit must be 'sysemble-vm-agent.service'")
if not isinstance(guest.get("minimal_build"), str) or not guest.get("minimal_build"):
    fail("manifest guest.minimal_build is empty")

packages = manifest.get("packages")
if not isinstance(packages, int) or isinstance(packages, bool) or packages <= 0:
    fail("manifest packages must be a positive integer, got %r" % (packages,))
if not isinstance(manifest.get("mmdebstrap"), str) or not manifest.get("mmdebstrap"):
    fail("manifest mmdebstrap version is empty")
if not isinstance(manifest.get("created"), str) or not manifest.get("created"):
    fail("manifest created is empty")

print("verify: OK  schema=1 name=sysemble-vm version=%s arch=arm64" % expected_version)
print("verify: OK  kernel=%s release=%s sha256=%s" % (kernel["path"], release, kernel["sha256"]))
print("verify: OK  initrd=%s sha256=%s" % (initrd["path"], initrd["sha256"]))
print("verify: OK  disk=%s size_bytes=%d sha256=%s" % (disk["path"], size_bytes, disk["sha256"]))
print("verify: OK  packages=%d mmdebstrap=%s" % (packages, manifest["mmdebstrap"]))
print("verify: manifest valid: %s" % manifest_path)
PY
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  validate_inputs

  if [ -n "$VERIFY_DIR" ]; then
    local verify_dir_arg=$VERIFY_DIR
    VERIFY_DIR=$(cd "$VERIFY_DIR" 2>/dev/null && pwd -P) ||
      die "verify: manifest directory not found: $verify_dir_arg"
    require_python
    verify_manifest "$VERIFY_DIR"
    exit 0
  fi

  require_python
  build_image
  summary
  exit 0
}

main "$@"
