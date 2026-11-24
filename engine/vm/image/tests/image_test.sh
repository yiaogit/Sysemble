#!/usr/bin/env bash
# Sysemble VM image tests (P1-e3a).
#
# Static (default; no docker, no build artifacts, no network):
#   - engine/vm/image/version is the frozen 0.1.0
#   - build-image.sh / in-container-build.sh / tests/image_test.sh and both
#     guest scripts pass `bash -n`; the executable ones are +x
#   - the guest unit matches the frozen contract (Type=simple, ExecStart,
#     WantedBy, After, Restart=no), the modules-load and networkd files exist
#     and have the required keys
#   - the guest agent implements the file protocol (virtiofs mounts with a
#     120 s retry, ready/job.sh/log/done, sync, no poweroff)
#   - minimal-build.sh carries the frozen guest package list and the four
#     stages, rejects /work and /export as --out, and prints VM-BUILD lines
#   - build-image.sh --help, unknown arguments (exit 2), bad --engine (exit 2),
#     and --verify failures (exit 1 with a readable message)
#   - in-container-build.sh builds the rootfs outside --out, mke2fs -d, sparse
#     6 GiB disk, systemctl --root, guest install paths, debugfs checks
#   - README and ci-snippet expose the frozen contract (arm64-only, 6 GiB,
#     ubuntu-24.04-arm, 45 min, no disk.img upload)
#
# --docker (requires a built image; works for docker *and* native builds):
#   - the four artifacts exist, build-image.sh --verify passes
#   - manifest schema/name/version/arch/kernel release/package count are valid
#   - sha256 of kernel/initrd/disk match the manifest and the actual file sizes
#   - disk.img is ext4 with label sysemble-engine and is sparse
#   - vmlinuz has the arm64 Image magic and file(1) recognises it
#   - initrd.img is a compressed cpio (gzip/zstd/xz)
#   - the guest files are in the disk: debugfs when available, otherwise the
#     diskcheck lines from build-image.log (in-container-build.sh reads the
#     image back with debugfs during the build)
#
# Each check prints PASS/FAIL/SKIP; the suite exits non-zero if any check fails.
#
# Requires bash 3.2+ (macOS /bin/bash). Do not use bash 4 features.

set -u

case "$0" in
  */*) TEST_DIR=${0%/*} ;;
  *) TEST_DIR=. ;;
esac
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
IMAGE_DIR=$(cd "$TEST_DIR/.." && pwd -P)
REPO_ROOT=$(cd "$IMAGE_DIR/../../.." && pwd -P)
GUEST_DIR="$REPO_ROOT/engine/vm/guest"

VERSION_FILE="$IMAGE_DIR/version"
BUILD_IMAGE="$IMAGE_DIR/build-image.sh"
IN_CONTAINER="$IMAGE_DIR/in-container-build.sh"
MANIFEST_NAME="sysemble-vm.json"
README="$IMAGE_DIR/README.md"
CI_SNIPPET="$IMAGE_DIR/ci-snippet.yml"

AGENT="$GUEST_DIR/sysemble-vm-agent"
AGENT_UNIT="sysemble-vm-agent.service"
AGENT_UNIT_FILE="$GUEST_DIR/$AGENT_UNIT"
MODULES_FILE="$GUEST_DIR/virtiofs.conf"
NETWORK_FILE="$GUEST_DIR/20-wired.network"
MINIMAL_BUILD="$GUEST_DIR/minimal-build.sh"
GUEST_README="$GUEST_DIR/README.md"

VERSION="0.1.0"
if [ -f "$VERSION_FILE" ]; then
  VERSION=$(tr -d '[:space:]' <"$VERSION_FILE" 2>/dev/null || true)
  [ -n "$VERSION" ] || VERSION="0.1.0"
fi
BUILD_DIR="$IMAGE_DIR/build"
MANIFEST="$BUILD_DIR/$MANIFEST_NAME"

EXPECTED_INCLUDE="systemd-sysv,systemd,udev,kmod,initramfs-tools,linux-image-arm64,systemd-resolved,ca-certificates,mmdebstrap,debian-archive-keyring,curl,jq,rsync,procps,iproute2,netbase,util-linux,bash,coreutils,tar,gzip,zstd,e2fsprogs"
DISK_LOGICAL_SIZE=6442450944

DOCKER_MODE=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

usage() {
  cat <<EOF
Usage: engine/vm/image/tests/image_test.sh [options]

Run the Sysemble VM image checks. Without options only the static checks run
(no docker, no build artifacts needed). --docker additionally checks a built
image directory (the flag name is historical: it works for docker and native
builds alike).

Options:
  --docker               also check a built image directory
  --manifest-dir <dir>   directory holding $MANIFEST_NAME and the artifacts
                         (default: engine/vm/image/build)
  -h, --help             show this help and exit 0

Environment:
  SYSEMBLE_VM_IMAGE_DIR  same as --manifest-dir

Exit codes: 0 all checks passed, 1 at least one check failed, 2 usage error.
EOF
}

usage_error() {
  printf 'image-test: error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

parse_args() {
  if [ -n "${SYSEMBLE_VM_IMAGE_DIR:-}" ]; then
    BUILD_DIR=$SYSEMBLE_VM_IMAGE_DIR
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --docker)
        DOCKER_MODE=1
        shift
        ;;
      --manifest-dir)
        [ "$#" -ge 2 ] || usage_error "--manifest-dir requires a directory"
        BUILD_DIR=$2
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

  MANIFEST="$BUILD_DIR/$MANIFEST_NAME"
}

# ---------------------------------------------------------------------------
# Report helpers
# ---------------------------------------------------------------------------

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'PASS  %s\n' "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf 'FAIL  %s\n' "$1"
  if [ "$#" -gt 1 ] && [ -n "$2" ]; then
    printf '      %s\n' "$2"
  fi
}

skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  printf 'SKIP  %s\n' "$1"
}

check_eq() {
  if [ "$2" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "expected [$2], got [$3]"
  fi
}

check_contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "[$2] not found in output" ;;
  esac
}

check_file_contains() {
  local label=$1
  local needle=$2
  local file=$3
  if [ ! -f "$file" ]; then
    fail "$label" "missing file: $file"
    return
  fi
  if grep -Fq -- "$needle" "$file"; then
    pass "$label"
  else
    fail "$label" "missing [$needle] in $file"
  fi
}

check_file_missing() {
  local label=$1
  local needle=$2
  local file=$3
  if [ ! -f "$file" ]; then
    fail "$label" "missing file: $file"
    return
  fi
  if grep -Fq -- "$needle" "$file"; then
    fail "$label" "found forbidden [$needle] in $file"
  else
    pass "$label"
  fi
}

is_executable() {
  [ -f "$1" ] && [ -x "$1" ]
}

# ---------------------------------------------------------------------------
# Static checks
# ---------------------------------------------------------------------------

static_version() {
  if [ ! -f "$VERSION_FILE" ]; then
    fail "version file exists" "missing $VERSION_FILE"
    return
  fi
  pass "version file exists"
  check_eq "version file is exactly 0.1.0" "0.1.0" "$(tr -d '[:space:]' <"$VERSION_FILE")"
  check_eq "version file has one line" "1" "$(wc -l <"$VERSION_FILE" | tr -d '[:space:]')"
}

static_scripts() {
  local script=""
  for script in "$BUILD_IMAGE" "$IN_CONTAINER" "$TEST_DIR/image_test.sh" "$AGENT" "$MINIMAL_BUILD"; do
    if [ ! -f "$script" ]; then
      fail "bash -n $(basename "$script")" "missing $script"
      continue
    fi
    if bash -n "$script" 2>/dev/null; then
      pass "bash -n $(basename "$script")"
    else
      fail "bash -n $(basename "$script")" "syntax error (run: bash -n $script)"
    fi
  done

  local executable=""
  for executable in "$BUILD_IMAGE" "$IN_CONTAINER" "$AGENT" "$MINIMAL_BUILD"; do
    if is_executable "$executable"; then
      pass "$(basename "$executable") is executable"
    else
      fail "$(basename "$executable") is executable" "chmod +x $executable"
    fi
  done
}

static_guest_unit() {
  if [ ! -f "$AGENT_UNIT_FILE" ]; then
    fail "sysemble-vm-agent.service exists" "missing $AGENT_UNIT_FILE"
    return
  fi
  pass "sysemble-vm-agent.service exists"
  check_file_contains "unit is Type=simple" "Type=simple" "$AGENT_UNIT_FILE"
  check_file_contains "unit ExecStart is /usr/local/sbin/sysemble-vm-agent" \
    "ExecStart=/usr/local/sbin/sysemble-vm-agent" "$AGENT_UNIT_FILE"
  check_file_contains "unit is WantedBy=multi-user.target" \
    "WantedBy=multi-user.target" "$AGENT_UNIT_FILE"
  check_file_contains "unit runs After=systemd-modules-load.service" \
    "After=systemd-modules-load.service" "$AGENT_UNIT_FILE"
  check_file_contains "unit has Restart=no" "Restart=no" "$AGENT_UNIT_FILE"
}

static_guest_config() {
  if [ ! -f "$MODULES_FILE" ]; then
    fail "virtiofs.conf exists" "missing $MODULES_FILE"
  else
    pass "virtiofs.conf exists"
    check_eq "virtiofs.conf loads exactly virtiofs" "virtiofs" \
      "$(tr -d '[:space:]' <"$MODULES_FILE")"
  fi

  if [ ! -f "$NETWORK_FILE" ]; then
    fail "20-wired.network exists" "missing $NETWORK_FILE"
    return
  fi
  pass "20-wired.network exists"
  check_file_contains "network matches en* interfaces" "Name=en*" "$NETWORK_FILE"
  check_file_contains "network uses DHCP" "DHCP=yes" "$NETWORK_FILE"
}

static_guest_agent() {
  if [ ! -f "$AGENT" ]; then
    fail "guest agent exists" "missing $AGENT"
    return
  fi
  pass "guest agent exists"
  check_file_contains "agent mounts virtiofs" "mount -t virtiofs" "$AGENT"
  check_file_contains "agent uses the sysemble-repo tag" "TAG_REPO=\"sysemble-repo\"" "$AGENT"
  check_file_contains "agent uses the sysemble-out tag" 'TAG_OUT="sysemble-out"' "$AGENT"
  check_file_contains "agent retries mounts for 120s" "MOUNT_TIMEOUT_SECONDS=120" "$AGENT"
  check_file_contains "agent writes the ready marker" "ready" "$AGENT"
  check_file_contains "agent polls job.sh" "job.sh" "$AGENT"
  check_file_contains "agent writes log" "job_log" "$AGENT"
  check_file_contains "agent writes done" "done_file" "$AGENT"
  check_file_contains "agent syncs before exiting" "sync" "$AGENT"
  check_file_contains "agent logs with the sysemble-vm-agent prefix" \
    "sysemble-vm-agent:" "$AGENT"

  if grep -Eq '^[[:space:]]*(poweroff|reboot|shutdown)([[:space:]]|$)' "$AGENT"; then
    fail "agent never powers the VM off" "found a poweroff/reboot command in $AGENT"
  else
    pass "agent never powers the VM off"
  fi
}

static_minimal_build() {
  if [ ! -f "$MINIMAL_BUILD" ]; then
    fail "minimal-build.sh exists" "missing $MINIMAL_BUILD"
    return
  fi
  pass "minimal-build.sh exists"

  local include=""
  include=$(sed -n 's/^GUEST_INCLUDE="\(.*\)"$/\1/p' "$MINIMAL_BUILD" | head -n 1)
  check_eq "guest package list matches the frozen contract" "$EXPECTED_INCLUDE" "$include"

  check_file_contains "minimal-build uses the read-only builder" \
    "/work/builders/debian/build.sh" "$MINIMAL_BUILD"
  check_file_contains "minimal-build runs the builder with --dry-run" "--dry-run" "$MINIMAL_BUILD"
  check_file_contains "minimal-build uses mmdebstrap --variant=minbase" "--variant=minbase" "$MINIMAL_BUILD"
  check_file_contains "minimal-build bootstraps trixie" "trixie" "$MINIMAL_BUILD"
  check_file_contains "minimal-build exports rootfs.tar.gz" "rootfs.tar.gz" "$MINIMAL_BUILD"
  check_file_contains "minimal-build runs sha256sum" "sha256sum" "$MINIMAL_BUILD"
  check_file_contains "minimal-build writes artifact-vm.json" "artifact-vm.json" "$MINIMAL_BUILD"
  check_file_contains "minimal-build records builder_dry_run=pass" "pass" "$MINIMAL_BUILD"
  check_file_contains "minimal-build prints VM-BUILD: complete" \
    "VM-BUILD: complete" "$MINIMAL_BUILD"
  check_file_contains "minimal-build prints VM-BUILD: failed" \
    "VM-BUILD: failed" "$MINIMAL_BUILD"
  check_file_contains "minimal-build rejects the /export share as --out" "/export/*" "$MINIMAL_BUILD"
  check_file_contains "minimal-build rejects the /work share as --out" "/work/*" "$MINIMAL_BUILD"
  check_file_contains "minimal-build records the arm64 arch" '"arm64"' "$MINIMAL_BUILD"
}

static_build_cli() {
  local help_output=""
  local help_rc=0
  help_output=$("$BUILD_IMAGE" --help 2>&1)
  help_rc=$?
  check_eq "build-image.sh --help exits 0" "0" "$help_rc"
  check_contains "build-image.sh --help documents --ref" "--ref" "$help_output"
  check_contains "build-image.sh --help documents --out" "--out" "$help_output"
  check_contains "build-image.sh --help documents --engine" "--engine" "$help_output"
  check_contains "build-image.sh --help documents --no-cache" "--no-cache" "$help_output"
  check_contains "build-image.sh --help documents --verify" "--verify" "$help_output"
  check_contains "build-image.sh --help shows the default ref" "sysemble-vm:$VERSION" "$help_output"

  local bogus_rc=0
  "$BUILD_IMAGE" --definitely-not-a-flag >/dev/null 2>&1
  bogus_rc=$?
  check_eq "build-image.sh unknown argument exits 2" "2" "$bogus_rc"

  local engine_rc=0
  "$BUILD_IMAGE" --engine definitely-not-an-engine >/dev/null 2>&1
  engine_rc=$?
  check_eq "build-image.sh invalid --engine exits 2" "2" "$engine_rc"

  local verify_output=""
  local verify_rc=0
  verify_output=$("$BUILD_IMAGE" --verify /nonexistent 2>&1)
  verify_rc=$?
  check_eq "build-image.sh --verify /nonexistent exits 1" "1" "$verify_rc"
  check_contains "build-image.sh --verify failure is readable" \
    "manifest directory not found" "$verify_output"

  check_file_contains "build-image.sh pins --platform linux/arm64" \
    "--platform linux/arm64" "$BUILD_IMAGE"
  check_file_contains "build-image.sh runs in-container-build.sh" \
    "in-container-build.sh" "$BUILD_IMAGE"
  check_file_contains "build-image.sh uses --privileged" "--privileged" "$BUILD_IMAGE"
  check_file_contains "build-image.sh mounts the repo read-only at /src" ":/src:ro" "$BUILD_IMAGE"
  check_file_contains "build-image.sh mounts the output at /out" ":/out" "$BUILD_IMAGE"
  check_file_contains "build-image.sh enforces the arm64 host" "arm64-only" "$BUILD_IMAGE"
  check_file_contains "build-image.sh selects native on Linux without docker" \
    "ENGINE=native" "$BUILD_IMAGE"
}

static_in_container() {
  if [ ! -f "$IN_CONTAINER" ]; then
    fail "in-container-build.sh exists" "missing $IN_CONTAINER"
    return
  fi
  pass "in-container-build.sh exists"
  check_file_contains "in-container uses the same guest package list" \
    'mmdebstrap --variant=minbase --include="$GUEST_INCLUDE" trixie "$ROOTFS_DIR"' \
    "$IN_CONTAINER"
  check_eq "in-container guest package list matches the frozen contract" "$EXPECTED_INCLUDE" \
    "$(sed -n 's/^GUEST_INCLUDE="\(.*\)"$/\1/p' "$IN_CONTAINER" | head -n 1)"
  check_file_contains "in-container builds a 6G sparse disk" 'DISK_SIZE="6G"' "$IN_CONTAINER"
  check_file_contains "in-container truncates the disk image" 'truncate -s "$DISK_SIZE"' "$IN_CONTAINER"
  check_file_contains "in-container formats the ext4 image with a label" \
    'mke2fs -t ext4 -F -L "$DISK_LABEL"' "$IN_CONTAINER"
  check_file_contains "in-container populates the image from the rootfs" \
    '-d "$ROOTFS_DIR"' "$IN_CONTAINER"
  check_file_contains "in-container enables units offline" "systemctl --root" "$IN_CONTAINER"
  check_file_contains "in-container installs the agent binary" \
    "/usr/local/sbin/sysemble-vm-agent" "$IN_CONTAINER"
  check_file_contains "in-container installs the agent unit" \
    '/etc/systemd/system/$AGENT_UNIT' "$IN_CONTAINER"
  check_file_contains "in-container installs the modules-load file" \
    "/etc/modules-load.d/virtiofs.conf" "$IN_CONTAINER"
  check_file_contains "in-container installs the networkd file" \
    "/etc/systemd/network/20-wired.network" "$IN_CONTAINER"
  check_file_contains "in-container handles resolv.conf" "stub-resolv.conf" "$IN_CONTAINER"
  check_file_contains "in-container writes the manifest" "$MANIFEST_NAME" "$IN_CONTAINER"
  check_file_contains "in-container counts guest packages with chroot dpkg-query" \
    'chroot "$ROOTFS_DIR" dpkg-query -W' "$IN_CONTAINER"
  check_file_contains "in-container reads the disk back with debugfs" "debugfs" "$IN_CONTAINER"
  check_file_contains "in-container keeps the rootfs outside --out" \
    "refusing --rootfs-dir" "$IN_CONTAINER"
  check_file_contains "in-container requires root" "must run as root" "$IN_CONTAINER"
  check_file_contains "in-container rejects non-arm64 hosts" "arm64-only" "$IN_CONTAINER"
}

static_docs_and_ci() {
  if [ -f "$README" ]; then
    pass "README.md exists"
  else
    fail "README.md exists" "missing $README"
  fi
  check_file_contains "README.md documents arm64-only" "arm64-only" "$README"
  check_file_contains "README.md documents the 6 GiB sparse disk" "6 GiB" "$README"
  check_file_contains "README.md documents --verify" "--verify" "$README"
  check_file_contains "README.md documents --engine" "--engine" "$README"

  if [ -f "$GUEST_README" ]; then
    pass "guest README.md exists"
  else
    fail "guest README.md exists" "missing $GUEST_README"
  fi
  check_file_contains "guest README documents the job protocol" "job.sh" "$GUEST_README"
  check_file_contains "guest README documents minimal-build.sh" "minimal-build.sh" "$GUEST_README"

  if [ ! -f "$CI_SNIPPET" ]; then
    fail "ci-snippet.yml exists" "missing $CI_SNIPPET"
    return
  fi
  pass "ci-snippet.yml exists"
  check_file_contains "ci-snippet defines vm-image" "vm-image:" "$CI_SNIPPET"
  check_file_contains "ci-snippet uses the arm64 runner" \
    "runs-on: ubuntu-24.04-arm" "$CI_SNIPPET"
  check_file_contains "ci-snippet sets a 45 minute timeout" "timeout-minutes: 45" "$CI_SNIPPET"
  check_file_contains "ci-snippet uploads the manifest" "engine/vm/image/build/sysemble-vm.json" "$CI_SNIPPET"
  check_file_contains "ci-snippet uploads the kernel" "engine/vm/image/build/vmlinuz" "$CI_SNIPPET"
  check_file_contains "ci-snippet uploads the initrd" "engine/vm/image/build/initrd.img" "$CI_SNIPPET"
  check_file_missing "ci-snippet never uploads the 6 GiB disk.img" "disk.img" "$CI_SNIPPET"
}

# ---------------------------------------------------------------------------
# Artifact checks (--docker / built image directory)
# ---------------------------------------------------------------------------

require_python() {
  command -v python3 >/dev/null 2>&1 ||
    { fail "python3 is available for artifact checks" "python3 not found on PATH"; return 1; }
  return 0
}

artifact_files() {
  if [ ! -d "$BUILD_DIR" ]; then
    fail "image directory exists" "missing $BUILD_DIR; run: bash engine/vm/image/build-image.sh --out $BUILD_DIR"
    return 1
  fi
  pass "image directory exists ($BUILD_DIR)"

  local file=""
  local missing=0
  for file in disk.img vmlinuz initrd.img "$MANIFEST_NAME"; do
    if [ -f "$BUILD_DIR/$file" ]; then
      pass "$file exists"
    else
      fail "$file exists" "missing $BUILD_DIR/$file"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || return 1
  return 0
}

artifact_verify() {
  local output=""
  local rc=0
  output=$("$BUILD_IMAGE" --verify "$BUILD_DIR" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "build-image.sh --verify $BUILD_DIR exits 0"
  else
    fail "build-image.sh --verify $BUILD_DIR exits 0" "$output"
    return
  fi
  printf '%s\n' "$output" | sed 's/^/      /'
  check_contains "verify reports a valid manifest" "manifest valid" "$output"
}

# Emits key<TAB>value lines; a malformed manifest becomes parse_error.
manifest_fields() {
  python3 - "$MANIFEST" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        manifest = json.load(handle)
except OSError as exc:
    print("parse_error\tcannot read manifest: %s" % exc)
    sys.exit(0)
except ValueError as exc:
    print("parse_error\tmanifest is not valid JSON: %s" % exc)
    sys.exit(0)

if not isinstance(manifest, dict):
    print("parse_error\tmanifest is not a JSON object")
    sys.exit(0)


def emit(key, value):
    if value is None:
        value = ""
    print("%s\t%s" % (key, value))


kernel = manifest.get("kernel") if isinstance(manifest.get("kernel"), dict) else {}
initrd = manifest.get("initrd") if isinstance(manifest.get("initrd"), dict) else {}
disk = manifest.get("disk") if isinstance(manifest.get("disk"), dict) else {}
guest = manifest.get("guest") if isinstance(manifest.get("guest"), dict) else {}

emit("schema", manifest.get("schema"))
emit("name", manifest.get("name"))
emit("version", manifest.get("version"))
emit("ref", manifest.get("ref"))
emit("arch", manifest.get("arch"))
emit("kernel_path", kernel.get("path"))
emit("kernel_release", kernel.get("release"))
emit("kernel_sha256", kernel.get("sha256"))
emit("initrd_path", initrd.get("path"))
emit("initrd_sha256", initrd.get("sha256"))
emit("disk_path", disk.get("path"))
emit("disk_sha256", disk.get("sha256"))
emit("disk_size_bytes", disk.get("size_bytes"))
emit("agent_unit", guest.get("agent_unit"))
emit("minimal_build", guest.get("minimal_build"))
emit("packages", manifest.get("packages"))
emit("mmdebstrap", manifest.get("mmdebstrap"))
emit("created", manifest.get("created"))
PY
}

artifact_manifest() {
  if [ ! -f "$MANIFEST" ]; then
    fail "manifest exists" "missing $MANIFEST"
    return
  fi
  pass "manifest exists"

  local fields=""
  fields=$(manifest_fields)
  local schema="" name="" version="" m_ref="" arch=""
  local kernel_path="" kernel_release="" kernel_sha256=""
  local initrd_path="" initrd_sha256=""
  local disk_path="" disk_sha256="" disk_size_bytes=""
  local agent_unit="" minimal_build="" packages="" mmdebstrap="" created=""
  local key="" value="" parse_error=""
  while IFS=$'\t' read -r key value; do
    case "$key" in
      schema) schema=$value ;;
      name) name=$value ;;
      version) version=$value ;;
      ref) m_ref=$value ;;
      arch) arch=$value ;;
      kernel_path) kernel_path=$value ;;
      kernel_release) kernel_release=$value ;;
      kernel_sha256) kernel_sha256=$value ;;
      initrd_path) initrd_path=$value ;;
      initrd_sha256) initrd_sha256=$value ;;
      disk_path) disk_path=$value ;;
      disk_sha256) disk_sha256=$value ;;
      disk_size_bytes) disk_size_bytes=$value ;;
      agent_unit) agent_unit=$value ;;
      minimal_build) minimal_build=$value ;;
      packages) packages=$value ;;
      mmdebstrap) mmdebstrap=$value ;;
      created) created=$value ;;
      parse_error) parse_error=$value ;;
    esac
  done <<EOF
$fields
EOF

  [ -z "$parse_error" ] || { fail "manifest is valid JSON" "$parse_error"; return; }
  pass "manifest is valid JSON"

  check_eq "manifest schema is 1" "1" "$schema"
  check_eq "manifest name is sysemble-vm" "sysemble-vm" "$name"
  check_eq "manifest version matches the version file" "$VERSION" "$version"
  check_eq "manifest arch is arm64" "arm64" "$arch"
  if [ -n "$kernel_release" ]; then
    pass "manifest kernel.release is non-empty ($kernel_release)"
  else
    fail "manifest kernel.release is non-empty" "empty kernel release"
  fi
  check_eq "manifest kernel.path is vmlinuz" "vmlinuz" "$kernel_path"
  check_eq "manifest initrd.path is initrd.img" "initrd.img" "$initrd_path"
  check_eq "manifest disk.path is disk.img" "disk.img" "$disk_path"
  check_eq "manifest disk.size_bytes is the 6 GiB logical size" \
    "$DISK_LOGICAL_SIZE" "$disk_size_bytes"
  check_eq "manifest guest.agent_unit is sysemble-vm-agent.service" \
    "sysemble-vm-agent.service" "$agent_unit"
  check_eq "manifest guest.minimal_build is the guest script" \
    "engine/vm/guest/minimal-build.sh" "$minimal_build"
  if [ -n "$packages" ] && [ "$packages" -gt 0 ] 2>/dev/null; then
    pass "manifest packages is a positive integer ($packages)"
  else
    fail "manifest packages is a positive integer" "got [$packages]"
  fi
  if [ -n "$mmdebstrap" ]; then
    pass "manifest mmdebstrap is non-empty ($mmdebstrap)"
  else
    fail "manifest mmdebstrap is non-empty" "empty mmdebstrap version"
  fi
  case "$created" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z)
      pass "manifest created is a UTC timestamp ($created)" ;;
    *) fail "manifest created is a UTC timestamp" "got [$created]" ;;
  esac

  # Host-side stat of the disk must match the manifest.
  local actual_size=""
  actual_size=$(wc -c <"$BUILD_DIR/disk.img" | tr -d '[:space:]')
  check_eq "disk.img file size matches disk.size_bytes" "$disk_size_bytes" "$actual_size"

  # Recompute every digest once (the disk is 6 GiB, so do it in one pass set).
  local sha_output=""
  local sha_rc=0
  sha_output=$(python3 - "$BUILD_DIR" "$kernel_sha256" "$initrd_sha256" "$disk_sha256" <<'PY'
import hashlib
import os
import sys

directory, expected_kernel, expected_initrd, expected_disk = sys.argv[1:5]


def digest(path):
    value = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


for name, expected in (("vmlinuz", expected_kernel),
                       ("initrd.img", expected_initrd),
                       ("disk.img", expected_disk)):
    actual = digest(os.path.join(directory, name))
    print("%s %s %s" % (name, "OK" if actual == expected else "MISMATCH", actual))
    if actual != expected:
        sys.exit(1)
PY
)
  sha_rc=$?
  if [ "$sha_rc" -eq 0 ]; then
    pass "manifest sha256 matches vmlinuz, initrd.img and disk.img"
  else
    fail "manifest sha256 matches vmlinuz, initrd.img and disk.img" "$sha_output"
  fi
  printf '%s\n' "$sha_output" | sed 's/^/      /'
}

artifact_magic() {
  if [ ! -f "$BUILD_DIR/disk.img" ] || [ ! -f "$BUILD_DIR/vmlinuz" ] || [ ! -f "$BUILD_DIR/initrd.img" ]; then
    skip "binary magic checks (artifacts missing)"
    return
  fi

  local facts=""
  facts=$(python3 - "$BUILD_DIR/disk.img" "$BUILD_DIR/vmlinuz" "$BUILD_DIR/initrd.img" <<'PY'
import sys

disk_path, kernel_path, initrd_path = sys.argv[1:4]

with open(disk_path, "rb") as handle:
    handle.seek(0x438)
    disk_magic = handle.read(2).hex()
    handle.seek(0x478)
    label = handle.read(16).split(b"\x00")[0].decode("ascii", "replace")

with open(kernel_path, "rb") as handle:
    handle.seek(0x38)
    kernel_magic = handle.read(4).hex()

with open(initrd_path, "rb") as handle:
    initrd_magic = handle.read(4).hex()

print("disk_magic=%s" % disk_magic)
print("disk_label=%s" % label)
print("kernel_magic=%s" % kernel_magic)
print("initrd_magic=%s" % initrd_magic)
PY
)
  local disk_magic="" disk_label="" kernel_magic="" initrd_magic=""
  local key="" value=""
  while IFS='=' read -r key value; do
    case "$key" in
      disk_magic) disk_magic=$value ;;
      disk_label) disk_label=$value ;;
      kernel_magic) kernel_magic=$value ;;
      initrd_magic) initrd_magic=$value ;;
    esac
  done <<EOF
$facts
EOF

  check_eq "disk.img has the ext4 superblock magic (0x53ef)" "53ef" "$disk_magic"
  check_eq "disk.img is labelled sysemble-engine" "sysemble-engine" "$disk_label"
  # arm64 Image magic 0x644d5241 at offset 0x38, little-endian -> "ARMd".
  check_eq "vmlinuz has the arm64 Image magic (ARMd)" "41524d64" "$kernel_magic"
  case "$initrd_magic" in
    1f8b | 28b52ffd | fd377a58 | 04224d18)
      pass "initrd.img starts with a compressed cpio stream ($initrd_magic)" ;;
    30373037)
      # Debian initramfs-tools concatenates an uncompressed newc cpio (for
      # already-compressed *.zst/*.xz members) with the compressed main cpio;
      # file(1) and the first magic only describe the first member.
      if grep -aq 'TRAILER!!!' "$BUILD_DIR/initrd.img"; then
        pass "initrd.img is a concatenated cpio image (uncompressed member first)"
      else
        fail "initrd.img is a concatenated cpio image" "no cpio trailer found"
      fi
      ;;
    *) fail "initrd.img is a compressed or concatenated cpio" "unexpected magic [$initrd_magic]" ;;
  esac

  if command -v file >/dev/null 2>&1; then
    local kernel_type=""
    kernel_type=$(file -b "$BUILD_DIR/vmlinuz" 2>/dev/null || true)
    case "$kernel_type" in
      *ARM64* | *aarch64* | *arm64*) pass "file(1) identifies the kernel as arm64 ($kernel_type)" ;;
      "") skip "file(1) kernel identification (empty output)" ;;
      *) fail "file(1) identifies the kernel as arm64" "file says [$kernel_type]" ;;
    esac
  else
    skip "file(1) kernel identification (file not installed)"
  fi
}

artifact_sparse() {
  if [ ! -f "$BUILD_DIR/disk.img" ]; then
    skip "disk.img sparse check (missing)"
    return
  fi
  local allocated_kb=""
  local logical=""
  allocated_kb=$(du -k "$BUILD_DIR/disk.img" | cut -f 1 | tr -d '[:space:]')
  logical=$(wc -c <"$BUILD_DIR/disk.img" | tr -d '[:space:]')
  case "$allocated_kb" in
    '' | *[!0-9]*) fail "disk.img is sparse" "du -k returned '$allocated_kb'"; return ;;
  esac
  if [ "$allocated_kb" -gt 0 ] && [ "$((allocated_kb * 1024))" -lt "$((logical / 2))" ]; then
    pass "disk.img is sparse (allocated $((allocated_kb / 1024)) MiB vs logical $((logical / 1048576)) MiB)"
  else
    fail "disk.img is sparse" "allocated ${allocated_kb} KiB vs logical ${logical} bytes"
  fi
}

artifact_guest_install() {
  if [ ! -f "$BUILD_DIR/disk.img" ]; then
    skip "guest install checks (disk.img missing)"
    return
  fi

  if command -v debugfs >/dev/null 2>&1; then
    local listing=""
    listing=$(debugfs -R "ls -l /" "$BUILD_DIR/disk.img" 2>/dev/null || true)
    if printf '%s\n' "$listing" | grep -q "etc"; then
      pass "debugfs can read the ext4 root directory"
    else
      fail "debugfs can read the ext4 root directory" "unexpected debugfs output"
    fi
    local agent=""
    agent=$(debugfs -R "cat /usr/local/sbin/sysemble-vm-agent" "$BUILD_DIR/disk.img" 2>/dev/null || true)
    case "$agent" in
      *"sysemble-vm-agent:"*) pass "debugfs finds the guest agent in disk.img" ;;
      *) fail "debugfs finds the guest agent in disk.img" "agent content missing" ;;
    esac
    local wants=""
    wants=$(debugfs -R "ls -l /etc/systemd/system/multi-user.target.wants" "$BUILD_DIR/disk.img" 2>/dev/null || true)
    case "$wants" in
      *"sysemble-vm-agent.service"*) pass "debugfs confirms sysemble-vm-agent.service is enabled" ;;
      *) fail "debugfs confirms sysemble-vm-agent.service is enabled" "symlink missing" ;;
    esac
    return
  fi

  # macOS has no debugfs. in-container-build.sh reads the finished image back
  # with debugfs before writing the manifest and logs diskcheck: OK lines.
  if [ -f "$BUILD_DIR/build-image.log" ] &&
    [ "$(grep -c 'vm-image: diskcheck: OK' "$BUILD_DIR/build-image.log" 2>/dev/null | tr -d '[:space:]')" -ge 5 ]; then
    pass "build log records the debugfs guest checks (debugfs not available on this host)"
    skip "debugfs root-directory check (debugfs not installed)"
  else
    skip "debugfs guest install checks (debugfs not installed and no diskcheck lines)"
  fi
}

artifact_build_log() {
  if [ -f "$BUILD_DIR/build-image.log" ]; then
    pass "build-image.log exists"
  else
    fail "build-image.log exists" "missing $BUILD_DIR/build-image.log"
    return
  fi
  check_file_contains "build log records VM-IMAGE: complete" "VM-IMAGE: complete" "$BUILD_DIR/build-image.log"
  check_file_contains "build log records the guest diskcheck lines" "diskcheck: OK" "$BUILD_DIR/build-image.log"
}

run_artifact_checks() {
  printf -- '----------------------------------------------------------------\n'
  if ! require_python; then
    return
  fi
  if ! artifact_files; then
    return
  fi
  artifact_verify
  artifact_manifest
  artifact_magic
  artifact_sparse
  artifact_guest_install
  artifact_build_log
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

parse_args "$@"

printf 'VM image tests (build dir: %s)\n' "$BUILD_DIR"
printf -- '----------------------------------------------------------------\n'

static_version
static_scripts
static_guest_unit
static_guest_config
static_guest_agent
static_minimal_build
static_build_cli
static_in_container
static_docs_and_ci

if [ "$DOCKER_MODE" -eq 1 ]; then
  run_artifact_checks
else
  skip "built image checks (pass --docker to run them)"
fi

printf -- '----------------------------------------------------------------\n'
printf 'Summary: %d passed, %d failed' "$PASS_COUNT" "$FAIL_COUNT"
if [ "$SKIP_COUNT" -gt 0 ]; then
  printf ', %d skipped' "$SKIP_COUNT"
fi
printf '\n'

if [ "$FAIL_COUNT" -ne 0 ] || [ "$PASS_COUNT" -eq 0 ]; then
  exit 1
fi
exit 0
