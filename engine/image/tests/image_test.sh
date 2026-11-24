#!/usr/bin/env bash
# Sysemble engine image tests (P1-e2a).
#
# Static (default, no docker and no daemon required):
#   - engine/image/version is the frozen 0.1.0
#   - the Dockerfile pins debian:trixie-slim by sha256 digest and linux/amd64
#   - every build/boot package the container contract needs is installed by the
#     single apt-get layer
#   - OCI labels, WORKDIR, CMD, and the absence of ENTRYPOINT
#   - build-image.sh / image_test.sh / container_smoke.sh pass `bash -n`
#   - build-image.sh --help, unknown-argument (exit 2), and --verify failures
#     (exit 1 with a readable message)
#   - the smoke test and CI snippet expose the frozen flags/contract
#
# --docker (requires a built image and a running daemon):
#   - the image exists, --verify passes, .Os is linux and .Architecture amd64
#   - every contract tool prints a non-empty version inside the container
#   - dpkg -l lists mmdebstrap/qemu-system-x86/grub-efi-amd64-bin/ovmf/
#     xorriso/rsync
#
# Each check prints PASS or FAIL; the suite exits non-zero if any check fails.
#
# Requires bash 3.2+ (macOS /bin/bash). Do not use bash 4 features.

set -u

case "$0" in
  */*) TEST_DIR=${0%/*} ;;
  *) TEST_DIR=. ;;
esac
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
IMAGE_DIR=$(cd "$TEST_DIR/.." && pwd -P)
REPO_ROOT=$(cd "$IMAGE_DIR/../.." && pwd -P)

VERSION_FILE="$IMAGE_DIR/version"
DOCKERFILE="$IMAGE_DIR/Dockerfile"
BUILD_IMAGE="$IMAGE_DIR/build-image.sh"
CONTAINER_SMOKE="$IMAGE_DIR/tests/container_smoke.sh"
README="$IMAGE_DIR/README.md"
CI_SNIPPET="$IMAGE_DIR/ci-snippet.yml"

PLATFORM="linux/amd64"
VERSION="0.1.0"
if [ -f "$VERSION_FILE" ]; then
  VERSION=$(tr -d '[:space:]' <"$VERSION_FILE" 2>/dev/null || true)
  [ -n "$VERSION" ] || VERSION="0.1.0"
fi
IMAGE="${SYSEMBLE_ENGINE_IMAGE:-sysemble-engine:$VERSION}"
MANIFEST_DIR="$IMAGE_DIR/build"
MANIFEST="$MANIFEST_DIR/sysemble-engine.json"

DOCKER_MODE=0
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# shellcheck disable=SC2016
REQUIRED_PACKAGES="mmdebstrap debian-archive-keyring qemu-system-x86 qemu-utils \
e2fsprogs gdisk dosfstools mtools grub-efi-amd64-bin grub-common ovmf xorriso \
squashfs-tools rsync jq expect curl ca-certificates file procps util-linux bash \
coreutils grep sed gawk findutils tar gzip xz-utils zstd"

TOOL_NAMES="mmdebstrap qemu-system-x86_64 grub-mkstandalone xorriso rsync"
DPKG_PACKAGES="mmdebstrap qemu-system-x86 grub-efi-amd64-bin ovmf xorriso rsync"

usage() {
  cat <<EOF
Usage: engine/image/tests/image_test.sh [options]

Run the engine image checks. Without options only the static checks run and no
docker daemon is required. --docker additionally requires a built and loaded
image.

Options:
  --docker               also run the container checks against the local image
  --image <ref>          image reference to check (default: sysemble-engine:$VERSION)
  --manifest-dir <dir>   directory holding sysemble-engine.json
                         (default: engine/image/build)
  -h, --help             show this help and exit 0

Environment:
  SYSEMBLE_ENGINE_IMAGE  image reference, overridden by --image

Exit codes: 0 all checks passed, 1 at least one check failed, 2 usage error.
EOF
}

usage_error() {
  printf 'image-test: error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --docker)
        DOCKER_MODE=1
        shift
        ;;
      --image)
        [ "$#" -ge 2 ] || usage_error "--image requires a value"
        IMAGE=$2
        shift 2
        ;;
      --manifest-dir)
        [ "$#" -ge 2 ] || usage_error "--manifest-dir requires a directory"
        MANIFEST_DIR=$2
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

# Words installed by the single apt-get layer (continuation lines included).
dockerfile_apt_tokens() {
  awk '/^RUN apt-get update/,/rm -rf \/var\/lib\/apt\/lists/' "$DOCKERFILE" 2>/dev/null |
    grep -oE '[a-z0-9][a-z0-9.+-]*' | sort -u
}

is_word_in() {
  printf '%s\n' "$2" | grep -qx -- "$1"
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

static_dockerfile_base() {
  if [ ! -f "$DOCKERFILE" ]; then
    fail "Dockerfile exists" "missing $DOCKERFILE"
    return
  fi
  pass "Dockerfile exists"

  local from_image=""
  from_image=$(awk '$1 == "FROM" { for (i = 2; i <= NF; i++) if ($i !~ /^--platform=/) { print $i; exit } }' "$DOCKERFILE")
  case "$from_image" in
    debian:trixie-slim@sha256:*) pass "Dockerfile base is debian:trixie-slim@sha256:<digest>" ;;
    *) fail "Dockerfile base is debian:trixie-slim@sha256:<digest>" "got [$from_image]" ;;
  esac
  if printf '%s' "$from_image" | grep -Eq '^debian:trixie-slim@sha256:[0-9a-f]{64}$'; then
    pass "Dockerfile base digest is a full 64-character sha256"
  else
    fail "Dockerfile base digest is a full 64-character sha256" "got [$from_image]"
  fi
  if grep -Eq '^FROM --platform=linux/amd64 ' "$DOCKERFILE"; then
    pass "Dockerfile FROM pins --platform=linux/amd64"
  else
    fail "Dockerfile FROM pins --platform=linux/amd64"
  fi

  check_file_contains "Dockerfile declares ARG SOURCE_DATE_EPOCH" "ARG SOURCE_DATE_EPOCH" "$DOCKERFILE"
  if grep -Eq "^ARG SYSEMBLE_ENGINE_VERSION=$VERSION$" "$DOCKERFILE"; then
    pass "Dockerfile ARG SYSEMBLE_ENGINE_VERSION matches the version file"
  else
    fail "Dockerfile ARG SYSEMBLE_ENGINE_VERSION matches the version file" \
      "expected ARG SYSEMBLE_ENGINE_VERSION=$VERSION"
  fi
  check_file_contains "Dockerfile sets DEBIAN_FRONTEND=noninteractive" "DEBIAN_FRONTEND=noninteractive" "$DOCKERFILE"
  check_file_contains "Dockerfile sets LANG=C.UTF-8" "LANG=C.UTF-8" "$DOCKERFILE"
  check_file_contains "Dockerfile sets LC_ALL=C.UTF-8" "LC_ALL=C.UTF-8" "$DOCKERFILE"
  check_eq "Dockerfile has exactly one apt-get update" "1" "$(grep -c 'apt-get update' "$DOCKERFILE" | tr -d '[:space:]')"
  check_file_contains "Dockerfile installs with --no-install-recommends" "--no-install-recommends" "$DOCKERFILE"
  if grep -Fq -- 'rm -rf /var/lib/apt/lists/*' "$DOCKERFILE"; then
    pass "Dockerfile removes /var/lib/apt/lists"
  else
    fail "Dockerfile removes /var/lib/apt/lists"
  fi
  check_file_contains "Dockerfile declares WORKDIR /work" "WORKDIR /work" "$DOCKERFILE"
  check_file_contains "Dockerfile declares CMD [\"bash\"]" 'CMD ["bash"]' "$DOCKERFILE"
  if grep -Eq '^[[:space:]]*ENTRYPOINT' "$DOCKERFILE"; then
    fail "Dockerfile has no ENTRYPOINT (CI calls bash explicitly)"
  else
    pass "Dockerfile has no ENTRYPOINT (CI calls bash explicitly)"
  fi

  check_file_contains "Dockerfile label title" 'org.opencontainers.image.title=' "$DOCKERFILE"
  check_file_contains "Dockerfile label version" 'org.opencontainers.image.version=' "$DOCKERFILE"
  check_file_contains "Dockerfile label revision" 'org.opencontainers.image.revision=' "$DOCKERFILE"
  check_file_contains "Dockerfile label source" 'org.opencontainers.image.source=' "$DOCKERFILE"
  check_file_contains "Dockerfile label base.name" 'org.opencontainers.image.base.name=' "$DOCKERFILE"
}

static_packages() {
  local tokens=""
  tokens=$(dockerfile_apt_tokens)
  local package=""
  for package in $REQUIRED_PACKAGES; do
    if is_word_in "$package" "$tokens"; then
      pass "Dockerfile installs $package"
    else
      fail "Dockerfile installs $package" "package not found in the apt-get install block"
    fi
  done
}

static_scripts() {
  local script=""
  for script in "$BUILD_IMAGE" "$IMAGE_DIR/tests/image_test.sh" "$CONTAINER_SMOKE"; do
    if [ ! -f "$script" ]; then
      fail "bash -n $(basename "$script")" "missing $script"
    elif bash -n "$script" 2>/dev/null; then
      pass "bash -n $(basename "$script")"
    else
      fail "bash -n $(basename "$script")" "syntax error (run: bash -n $script)"
    fi
  done

  if [ -x "$BUILD_IMAGE" ]; then
    pass "build-image.sh is executable"
  else
    fail "build-image.sh is executable" "chmod +x $BUILD_IMAGE"
  fi
}

static_build_script_cli() {
  local help_output=""
  local help_rc=0
  help_output=$("$BUILD_IMAGE" --help 2>&1)
  help_rc=$?
  check_eq "build-image.sh --help exits 0" "0" "$help_rc"
  check_contains "build-image.sh --help documents --ref" "--ref" "$help_output"
  check_contains "build-image.sh --help documents --out" "--out" "$help_output"
  check_contains "build-image.sh --help documents --platform" "--platform" "$help_output"
  check_contains "build-image.sh --help documents --no-cache" "--no-cache" "$help_output"
  check_contains "build-image.sh --help documents --verify" "--verify" "$help_output"
  check_contains "build-image.sh --help shows the default ref" "sysemble-engine:$VERSION" "$help_output"

  local bogus_rc=0
  "$BUILD_IMAGE" --definitely-not-a-flag >/dev/null 2>&1
  bogus_rc=$?
  check_eq "build-image.sh unknown argument exits 2" "2" "$bogus_rc"

  local verify_output=""
  local verify_rc=0
  verify_output=$("$BUILD_IMAGE" --verify /nonexistent 2>&1)
  verify_rc=$?
  check_eq "build-image.sh --verify /nonexistent exits 1" "1" "$verify_rc"
  check_contains "build-image.sh --verify failure is readable" "manifest directory not found" "$verify_output"

  check_file_contains "build-image.sh writes sysemble-engine.json" 'sysemble-engine.json' "$BUILD_IMAGE"
  local platform_count=0
  platform_count=$(grep -c -F -- '--platform "$PLATFORM"' "$BUILD_IMAGE" 2>/dev/null | tr -d '[:space:]')
  if [ "${platform_count:-0}" -ge 2 ]; then
    pass "build-image.sh passes --platform to docker build and docker run"
  else
    fail "build-image.sh passes --platform to docker build and docker run" \
      "expected at least 2 --platform \"\$PLATFORM\" call sites, found ${platform_count:-0}"
  fi
}

static_container_smoke() {
  if [ ! -f "$CONTAINER_SMOKE" ]; then
    fail "container_smoke.sh exists" "missing $CONTAINER_SMOKE"
    return
  fi
  pass "container_smoke.sh exists"

  local help_output=""
  local help_rc=0
  help_output=$("$CONTAINER_SMOKE" --help 2>&1)
  help_rc=$?
  check_eq "container_smoke.sh --help exits 0" "0" "$help_rc"
  check_contains "container_smoke.sh --help documents --image" "--image" "$help_output"
  check_contains "container_smoke.sh --help documents --repo" "--repo" "$help_output"
  check_contains "container_smoke.sh --help documents --out" "--out" "$help_output"
  check_contains "container_smoke.sh --help documents --boot-timeout" "--boot-timeout" "$help_output"

  local run_count=0
  run_count=$(grep -c -F -- 'docker run --rm --init --privileged --platform linux/amd64' "$CONTAINER_SMOKE" 2>/dev/null | tr -d '[:space:]')
  if [ "${run_count:-0}" -ge 2 ]; then
    pass "container_smoke.sh uses the frozen docker run flags for build and boot"
  else
    fail "container_smoke.sh uses the frozen docker run flags for build and boot" \
      "expected 2 matches of 'docker run --rm --init --privileged --platform linux/amd64', found ${run_count:-0}"
  fi
  check_file_contains "container_smoke.sh runs the v2 container entry script" \
    "engine/runtime/container-entry.sh" "$CONTAINER_SMOKE"
  local ro_count=0
  ro_count=$(grep -c -F -- '":/work:ro' "$CONTAINER_SMOKE" 2>/dev/null | tr -d '[:space:]')
  if [ "${ro_count:-0}" -ge 2 ]; then
    pass "container_smoke.sh mounts the repo read-only in both phases"
  else
    fail "container_smoke.sh mounts the repo read-only in both phases" \
      "expected 2 matches of ':/work:ro', found ${ro_count:-0}"
  fi
  check_file_contains "container_smoke.sh plans from /export/plan.json" "--plan /export/plan.json" "$CONTAINER_SMOKE"
  check_file_contains "container_smoke.sh builds in the container-local /out" "--out /out" "$CONTAINER_SMOKE"
  check_file_contains "container_smoke.sh exports to /export" "--export /export" "$CONTAINER_SMOKE"
  check_file_contains "container_smoke.sh asserts disk.img for the UEFI boot-check" "disk.img" "$CONTAINER_SMOKE"
  if grep -Fq -- 'bash builders/debian/build.sh' "$CONTAINER_SMOKE"; then
    fail "container_smoke.sh does not invoke the builder directly (v2 uses the entry script)"
  else
    pass "container_smoke.sh does not invoke the builder directly (v2 uses the entry script)"
  fi
  check_file_contains "container_smoke.sh prints CONTAINER-SMOKE: pass" "CONTAINER-SMOKE: pass" "$CONTAINER_SMOKE"
}

static_docs_and_ci() {
  if [ -f "$README" ]; then
    pass "README.md exists"
  else
    fail "README.md exists" "missing $README"
  fi
  check_file_contains "README.md documents --privileged" "--privileged" "$README"
  check_file_contains "README.md documents Rosetta" "Rosetta" "$README"
  check_file_contains "README.md documents bit-for-bit limits" "bit-for-bit" "$README"
  check_file_contains "README.md documents the linux/amd64 contract" "linux/amd64" "$README"

  if [ -f "$CI_SNIPPET" ]; then
    pass "ci-snippet.yml exists"
  else
    fail "ci-snippet.yml exists" "missing $CI_SNIPPET"
  fi
  check_file_contains "ci-snippet.yml defines engine-check" "engine-check:" "$CI_SNIPPET"
  check_file_contains "ci-snippet.yml uses a 45 minute timeout" "timeout-minutes: 45" "$CI_SNIPPET"
  check_file_contains "ci-snippet.yml uploads the engine manifest" "engine/image/build/sysemble-engine.json" "$CI_SNIPPET"
  check_file_contains "ci-snippet.yml uploads boot evidence" "boot-evidence.json" "$CI_SNIPPET"
  check_file_contains "ci-snippet.yml runs container_smoke.sh" "container_smoke.sh" "$CI_SNIPPET"
}

# ---------------------------------------------------------------------------
# Docker checks
# ---------------------------------------------------------------------------

docker_image_exists() {
  local image_id=""
  if ! image_id=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null); then
    fail "image $IMAGE exists locally" \
      "not found; run: bash engine/image/build-image.sh --ref $IMAGE --out $MANIFEST_DIR"
    return 1
  fi
  pass "image $IMAGE exists locally ($image_id)"
  return 0
}

docker_verify() {
  if [ ! -f "$MANIFEST" ]; then
    fail "manifest $MANIFEST exists" "missing; run build-image.sh first"
    return
  fi
  pass "manifest $MANIFEST exists"
  local output=""
  local rc=0
  output=$("$BUILD_IMAGE" --verify "$MANIFEST_DIR" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "build-image.sh --verify $MANIFEST_DIR exits 0"
  else
    fail "build-image.sh --verify $MANIFEST_DIR exits 0" "$output"
    return
  fi
  printf '%s\n' "$output" | sed 's/^/      /'
  if grep -Fq '"verified": true' "$MANIFEST"; then
    pass "manifest records verified=true after --verify"
  else
    fail "manifest records verified=true after --verify"
  fi
}

docker_platform() {
  local os=""
  local arch=""
  os=$(docker image inspect --format '{{.Os}}' "$IMAGE" 2>/dev/null || true)
  arch=$(docker image inspect --format '{{.Architecture}}' "$IMAGE" 2>/dev/null || true)
  check_eq "image .Os is linux" "linux" "$os"
  check_eq "image .Architecture is amd64" "amd64" "$arch"
}

# On Apple Silicon, Rosetta keeps fds 3..9 open, so mmdebstrap's apt hook
# (`cat >&<fd>`) lands above fd 9 and dash rejects it. The image must use bash
# as /bin/sh for the container build to work there.
docker_shell() {
  local resolved=""
  resolved=$(docker run --rm --platform linux/amd64 "$IMAGE" readlink -f /bin/sh 2>/dev/null || true)
  check_eq "container /bin/sh is bash (Rosetta fd > 9 workaround)" "/usr/bin/bash" "$resolved"
}

docker_tool_versions() {
  local script=""
  script=$(cat <<'TOOLS'
for tool in mmdebstrap qemu-system-x86_64 grub-mkstandalone xorriso rsync; do
  out=""
  if out=$("$tool" --version 2>&1); then
    :
  elif out=$("$tool" -version 2>&1); then
    :
  else
    out=""
  fi
  printf '%s=%s\n' "$tool" "${out%%$'\n'*}"
done
TOOLS
)
  local output=""
  local rc=0
  output=$(docker run --rm --platform linux/amd64 "$IMAGE" bash -c "$script" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "container runs the tool version probe" "exit $rc: $output"
    return
  fi
  pass "container runs the tool version probe"
  local tool=""
  local value=""
  for tool in $TOOL_NAMES; do
    value=$(printf '%s\n' "$output" | sed -n "s/^$tool=//p" | head -n 1)
    value=$(printf '%s' "$value" | sed 's/[[:space:]]*$//')
    if [ -n "$value" ]; then
      pass "container: $tool --version is non-empty ($value)"
    else
      fail "container: $tool --version is non-empty" "empty output"
    fi
  done
}

docker_dpkg_packages() {
  local output=""
  local rc=0
  output=$(docker run --rm --platform linux/amd64 "$IMAGE" bash -c 'dpkg -l' 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "container runs dpkg -l" "exit $rc: $output"
    return
  fi
  pass "container runs dpkg -l"
  local names=""
  names=$(printf '%s\n' "$output" | awk '$1 == "ii" { print $2 }')
  local package=""
  for package in $DPKG_PACKAGES; do
    if printf '%s\n' "$names" | grep -qx -- "$package"; then
      pass "dpkg -l lists $package"
    else
      fail "dpkg -l lists $package" "package not installed in the image"
    fi
  done
}

run_docker_checks() {
  if ! command -v docker >/dev/null 2>&1; then
    fail "docker CLI is available" "docker not found on PATH"
    return
  fi
  pass "docker CLI is available"
  if ! docker_image_exists; then
    return
  fi
  docker_verify
  docker_platform
  docker_shell
  docker_tool_versions
  docker_dpkg_packages
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

parse_args "$@"

printf 'engine image tests (image: %s)\n' "$IMAGE"
printf -- '----------------------------------------------------------------\n'

static_version
static_dockerfile_base
static_packages
static_scripts
static_build_script_cli
static_container_smoke
static_docs_and_ci

if [ "$DOCKER_MODE" -eq 1 ]; then
  printf -- '----------------------------------------------------------------\n'
  run_docker_checks
else
  skip "docker checks (pass --docker to run them)"
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
