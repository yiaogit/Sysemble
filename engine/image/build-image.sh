#!/usr/bin/env bash
# Sysemble engine image build + manifest (P1-e2a).
#
# Contract (frozen): docs/plan/P1-e2-workplan.md section 2.1.
#
#   build-image.sh [--ref <ref>] [--out <dir>] [--platform linux/amd64]
#                  [--no-cache] [--verify <dir>] [--help]
#
# Builds the pinned Debian engine image (engine/image/Dockerfile), collects the
# image id, the base digest, the tool versions, and the dpkg package list from
# the built image, and writes <out>/sysemble-engine.json (schema 1). --verify
# re-checks an existing manifest against the local Docker image and the
# Dockerfile digest, then rewrites "verified": true atomically.
#
# Everything the manifest records comes from the image itself, so the manifest
# describes the bytes that builders/debian/build.sh and tools/boot-check.sh will
# actually run. The base digest is parsed from the Dockerfile, which is the
# single source of truth for the pin.
#
# Requires bash 3.2+ (macOS /bin/bash / GitHub ubuntu-latest). Do not use bash 4
# features (mapfile, associative arrays, wait -n, ${var,,}, ...).
# Host requirements: docker CLI + daemon, python3 (manifest JSON only; jq is not
# required on the host), and the repo checked out at engine/image/../..

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths and defaults
# ---------------------------------------------------------------------------

case "$0" in
  */*) SCRIPT_DIR=${0%/*} ;;
  *) SCRIPT_DIR=. ;;
esac
SCRIPT_DIR=$(cd "$SCRIPT_DIR" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)

VERSION_FILE="$SCRIPT_DIR/version"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"
MANIFEST_NAME="sysemble-engine.json"
DEFAULT_SOURCE_DATE_EPOCH=1795478400

REF=""
OUT=""
PLATFORM="linux/amd64"
NO_CACHE=0
VERIFY_DIR=""
SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$DEFAULT_SOURCE_DATE_EPOCH}
REVISION=${SYSEMBLE_ENGINE_REVISION:-local}
VERSION=""
DOCKER_BASE=""
DOCKER_BASE_REPO=""
DOCKER_BASE_DIGEST=""
WORK_TMP=""
START_SECONDS=$SECONDS

cleanup() {
  if [ -n "${WORK_TMP:-}" ]; then
    case "$WORK_TMP" in
      */sysemble-image.*) rm -rf "$WORK_TMP" 2>/dev/null || true ;;
    esac
  fi
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
Usage: engine/image/build-image.sh [options]

Build the pinned Sysemble engine image and write <out>/$MANIFEST_NAME.
--verify checks an existing manifest instead of building.

Options:
  --ref <ref>         image reference to build (default: sysemble-engine:$help_version)
  --out <dir>         output directory for the manifest and build log
                      (default: engine/image/build)
  --platform <name>   target platform; only linux/amd64 is supported
                      (default: linux/amd64)
  --no-cache          pass --no-cache to docker build
  --verify <dir>      verify <dir>/$MANIFEST_NAME against the local image and
                      the Dockerfile base digest; does not build
  -h, --help          show this help and exit 0

Environment:
  SOURCE_DATE_EPOCH           build timestamp recorded in the manifest
                              (default: $DEFAULT_SOURCE_DATE_EPOCH)
  SYSEMBLE_ENGINE_REVISION    revision recorded in the OCI revision label
                              (default: local)

Exit codes: 0 success, 1 build/verify failure, 2 usage error.
EOF
}

# ---------------------------------------------------------------------------
# Arguments
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
        [ "$#" -ge 2 ] || usage_error "--out requires a value"
        OUT=$2
        shift 2
        ;;
      --platform)
        [ "$#" -ge 2 ] || usage_error "--platform requires a value"
        PLATFORM=$2
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

# ---------------------------------------------------------------------------
# Static inputs
# ---------------------------------------------------------------------------

load_version() {
  [ -f "$VERSION_FILE" ] || die "version file not found: $VERSION_FILE"
  VERSION=$(tr -d '[:space:]' <"$VERSION_FILE")
  [ -n "$VERSION" ] || die "version file is empty: $VERSION_FILE"
  case "$VERSION" in
    *[!0-9A-Za-z.+-]*) die "version file contains unsupported characters: '$VERSION'" ;;
  esac
}

load_dockerfile_base() {
  [ -f "$DOCKERFILE" ] || die "Dockerfile not found: $DOCKERFILE"
  # FROM --platform=linux/amd64 debian:trixie-slim@sha256:<digest>
  DOCKER_BASE=$(awk '$1 == "FROM" { for (i = 2; i <= NF; i++) if ($i !~ /^--platform=/) { print $i; exit } }' "$DOCKERFILE")
  [ -n "$DOCKER_BASE" ] || die "cannot find a FROM image in $DOCKERFILE"
  case "$DOCKER_BASE" in
    *@sha256:*) ;;
    *) die "Dockerfile FROM is not pinned by a sha256 digest: '$DOCKER_BASE'" ;;
  esac
  DOCKER_BASE_REPO=${DOCKER_BASE%%@*}
  DOCKER_BASE_DIGEST=${DOCKER_BASE##*@}
  case "$DOCKER_BASE_DIGEST" in
    sha256:*) ;;
    *) die "Dockerfile base digest is not sha256: '$DOCKER_BASE_DIGEST'" ;;
  esac
  case "${DOCKER_BASE_DIGEST#sha256:}" in
    *[!0-9a-f]*) die "Dockerfile base digest is not lowercase hex: '$DOCKER_BASE_DIGEST'" ;;
  esac
  [ "${#DOCKER_BASE_DIGEST}" -eq 71 ] || die "Dockerfile base digest is not 64 hex characters: '$DOCKER_BASE_DIGEST'"
}

validate_inputs() {
  load_version
  load_dockerfile_base

  [ -n "$REF" ] || REF="sysemble-engine:$VERSION"
  [ -n "$OUT" ] || OUT="$SCRIPT_DIR/build"

  case "$REF" in
    *[[:space:]]*) usage_error "--ref must not contain whitespace: '$REF'" ;;
    -*) usage_error "--ref must not start with '-': '$REF'" ;;
  esac

  case "$PLATFORM" in
    linux/amd64) ;;
    *)
      usage_error "unsupported --platform '$PLATFORM': the engine target architecture is fixed at linux/amd64 (P1-e2 decision; see docs/plan/P1-e2-workplan.md section 0)"
      ;;
  esac

  case "$SOURCE_DATE_EPOCH" in
    '' | *[!0-9]*) usage_error "SOURCE_DATE_EPOCH must be a positive integer, got '$SOURCE_DATE_EPOCH'" ;;
  esac
  [ "$SOURCE_DATE_EPOCH" -gt 0 ] || usage_error "SOURCE_DATE_EPOCH must be greater than zero"
}

require_python() {
  command -v python3 >/dev/null 2>&1 ||
    die "python3 is required to write and verify $MANIFEST_NAME (jq is not required on the host)"
}

require_docker() {
  command -v docker >/dev/null 2>&1 ||
    die "docker CLI not found on PATH; start Docker Desktop (or install docker) and retry"
}

# ---------------------------------------------------------------------------
# docker helpers
# ---------------------------------------------------------------------------

# docker image inspect does not accept --platform. The Dockerfile pins
# linux/amd64 and image_test.sh --docker asserts .Os/.Architecture, so the
# manifest stays tied to the amd64 image.
image_id_of() {
  docker image inspect --format '{{.Id}}' "$1" 2>/dev/null
}

# The in-image collector runs exactly once per build: it prints the version of
# every tool the contract requires plus the installed dpkg package list.
collect_script() {
  cat <<'COLLECT'
set -u
printf 'SYSEMBLE-COLLECT-V1\n'
printf '###TOOLS\n'
for tool in mmdebstrap qemu-system-x86_64 grub-mkstandalone xorriso rsync; do
  out=""
  if out=$("$tool" --version 2>&1); then
    :
  elif out=$("$tool" -version 2>&1); then
    :
  else
    out=""
  fi
  line=${out%%$'\n'*}
  printf '%s=%s\n' "$tool" "$line"
done
printf '###PACKAGES\n'
dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}=${Version}\n' \
  | awk -F'\t' '$1 ~ /^ii/ { print $2 }' \
  | sort
COLLECT
}

collect_from_image() {
  local raw_file=$1
  local script=""
  script=$(collect_script)
  if ! docker run --rm --platform "$PLATFORM" "$REF" bash -c "$script" \
    >"$raw_file" 2>"$raw_file.err"; then
    warn "in-image collection failed; last docker output:"
    tail -n 20 "$raw_file.err" >&2 2>/dev/null || true
    die "cannot collect tool versions and packages from image '$REF'"
  fi
  if ! grep -q '^###PACKAGES$' "$raw_file"; then
    warn "in-image collection output was incomplete; first lines:"
    sed -n '1,20p' "$raw_file" >&2 || true
    die "in-image collection did not complete for image '$REF'"
  fi
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build_image() {
  mkdir -p "$OUT" || die "cannot create output directory: $OUT"
  OUT=$(cd "$OUT" && pwd -P)
  local build_log="$OUT/build-image.log"

  local no_cache_arg=""
  if [ "$NO_CACHE" -eq 1 ]; then
    no_cache_arg="--no-cache"
  fi

  note "building $REF (platform $PLATFORM)"
  note "base: $DOCKER_BASE"
  note "log:  $build_log"

  # shellcheck disable=SC2086
  if ! docker build \
    --platform "$PLATFORM" \
    --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
    --build-arg "SYSEMBLE_ENGINE_VERSION=$VERSION" \
    --build-arg "SYSEMBLE_ENGINE_REVISION=$REVISION" \
    $no_cache_arg \
    --file "$DOCKERFILE" \
    --tag "$REF" \
    "$SCRIPT_DIR" 2>&1 | tee "$build_log"; then
    die "docker build failed (see $build_log)"
  fi

  local image_id=""
  if ! image_id=$(image_id_of "$REF"); then
    die "docker build succeeded but image '$REF' is not inspectable"
  fi
  [ -n "$image_id" ] || die "docker image inspect returned an empty image id for '$REF'"

  WORK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sysemble-image.XXXXXX") ||
    die "cannot create a temporary directory"

  local raw_collect="$WORK_TMP/collect.raw"
  local raw_tools="$WORK_TMP/tool-versions.raw"
  local raw_packages="$WORK_TMP/packages.raw"

  collect_from_image "$raw_collect"

  local in_tools=0
  local in_packages=0
  local line=""
  : >"$raw_tools"
  : >"$raw_packages"
  while IFS= read -r line; do
    case "$line" in
      SYSEMBLE-COLLECT-V1) continue ;;
      '###TOOLS')
        in_tools=1
        in_packages=0
        continue
        ;;
      '###PACKAGES')
        in_tools=0
        in_packages=1
        continue
        ;;
    esac
    if [ "$in_tools" -eq 1 ]; then
      printf '%s\n' "$line" >>"$raw_tools"
    elif [ "$in_packages" -eq 1 ]; then
      printf '%s\n' "$line" >>"$raw_packages"
    fi
  done <"$raw_collect"

  [ -s "$raw_tools" ] || die "no tool versions were collected from image '$REF'"
  [ -s "$raw_packages" ] || die "no dpkg packages were collected from image '$REF'"

  write_manifest "$OUT/$MANIFEST_NAME" "$image_id" "$raw_tools" "$raw_packages"

  local elapsed=$((SECONDS - START_SECONDS))
  note "built $REF"
  note "  image_id: $image_id"
  note "  base:     $DOCKER_BASE"
  note "  platform: $PLATFORM"
  note "  manifest: $OUT/$MANIFEST_NAME"
  note "  elapsed:  ${elapsed}s"
}

write_manifest() {
  local manifest=$1
  local image_id=$2
  local raw_tools=$3
  local raw_packages=$4

  python3 - "$manifest" "$image_id" "$DOCKER_BASE" "$VERSION" "$REF" \
    "$PLATFORM" "$SOURCE_DATE_EPOCH" "$raw_tools" "$raw_packages" <<'PY'
import datetime
import json
import os
import sys
import tempfile

(manifest_path, image_id, base, version, ref, platform,
 source_date_epoch, tools_path, packages_path) = sys.argv[1:10]

EXPECTED_TOOLS = [
    "mmdebstrap",
    "qemu-system-x86_64",
    "grub-mkstandalone",
    "xorriso",
    "rsync",
]


def read_lines(path):
    with open(path, encoding="utf-8") as handle:
        return [line.rstrip("\n") for line in handle if line.strip()]


versions = {}
for line in read_lines(tools_path):
    if "=" not in line:
        raise SystemExit("invalid tool line: %r" % line)
    name, value = line.split("=", 1)
    versions[name] = value.strip()

tool_versions = {}
for name in EXPECTED_TOOLS:
    value = versions.get(name, "")
    if not value:
        raise SystemExit(
            "the image did not report a version for '%s'; "
            "engine/image/Dockerfile is missing a tool or the collector failed" % name
        )
    tool_versions[name] = value

packages = sorted({line.strip() for line in read_lines(packages_path) if line.strip()})
if not packages:
    raise SystemExit("no installed dpkg packages were collected from the image")
malformed = [p for p in packages if "=" not in p or p.startswith("=") or " " in p]
if malformed:
    raise SystemExit(
        "collected dpkg packages are not 'name=version': %r" % malformed[:5]
    )

epoch = int(source_date_epoch)
created = datetime.datetime.fromtimestamp(
    epoch, datetime.timezone.utc
).strftime("%Y-%m-%dT%H:%M:%SZ")

manifest = {
    "schema": 1,
    "name": "sysemble-engine",
    "version": version,
    "ref": ref,
    "platform": platform,
    "base": base,
    "image_id": image_id,
    "source_date_epoch": epoch,
    "created": created,
    "tool_versions": tool_versions,
    "packages": packages,
    "verified": False,
}

directory = os.path.dirname(os.path.abspath(manifest_path)) or "."
fd, tmp_path = tempfile.mkstemp(
    prefix=".sysemble-engine.", suffix=".json", dir=directory
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    os.replace(tmp_path, manifest_path)
finally:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)

print("build-image: wrote manifest %s" % manifest_path)
print("build-image:   ref=%s" % ref)
print("build-image:   image_id=%s" % image_id)
print("build-image:   base=%s" % base)
print("build-image:   packages=%d" % len(packages))
print("build-image:   tool_versions=%s"
      % ", ".join("%s %s" % (name, tool_versions[name]) for name in EXPECTED_TOOLS))
PY
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

# Reads the manifest and prints "key<TAB>value" lines. A malformed manifest is
# reported through a parse_error line instead of a traceback.
read_manifest_fields() {
  python3 - "$1" <<'PY'
import json
import sys

EXPECTED_TOOLS = [
    "mmdebstrap",
    "qemu-system-x86_64",
    "grub-mkstandalone",
    "xorriso",
    "rsync",
]

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
    print("%s\t%s" % (key, str(value)))


emit("schema", manifest.get("schema"))
emit("name", manifest.get("name"))
emit("version", manifest.get("version"))
emit("ref", manifest.get("ref"))
emit("platform", manifest.get("platform"))
emit("base", manifest.get("base"))
emit("image_id", manifest.get("image_id"))
emit("source_date_epoch", manifest.get("source_date_epoch"))
emit("created", manifest.get("created"))
emit("verified", "true" if manifest.get("verified") is True else "false")

tools = manifest.get("tool_versions")
present = []
missing = []
if isinstance(tools, dict):
    for name in EXPECTED_TOOLS:
        value = tools.get(name)
        if isinstance(value, str) and value.strip():
            present.append(name)
        else:
            missing.append(name)
else:
    missing = list(EXPECTED_TOOLS)

emit("tool_missing", ",".join(missing))
emit("tool_count", len(present))
emit(
    "tool_summary",
    "; ".join("%s %s" % (name, tools[name].strip()) for name in present)
    if isinstance(tools, dict)
    else "",
)

packages = manifest.get("packages")
emit("package_count", len(packages) if isinstance(packages, list) else 0)
PY
}

# Atomic rewrite of "verified": true; every other field is preserved verbatim.
mark_verified() {
  python3 - "$1" <<'PY'
import json
import os
import sys
import tempfile

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["verified"] = True

directory = os.path.dirname(os.path.abspath(path)) or "."
fd, tmp_path = tempfile.mkstemp(
    prefix=".sysemble-engine.", suffix=".json", dir=directory
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    os.replace(tmp_path, path)
finally:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
PY
}

verify_manifest() {
  local dir=$1
  local manifest="$dir/$MANIFEST_NAME"

  [ -d "$dir" ] || die "verify: not a directory: $dir"
  [ -f "$manifest" ] || die "verify: manifest not found: $manifest (run build-image.sh first)"

  local fields=""
  fields=$(read_manifest_fields "$manifest")

  local schema="" name="" version="" m_ref="" platform="" m_base="" m_image_id=""
  local source_date_epoch="" created="" verified=""
  local tool_missing="" tool_count="" tool_summary="" package_count=""
  local key="" value="" parse_error=""
  while IFS=$'\t' read -r key value; do
    case "$key" in
      schema) schema=$value ;;
      name) name=$value ;;
      version) version=$value ;;
      ref) m_ref=$value ;;
      platform) platform=$value ;;
      base) m_base=$value ;;
      image_id) m_image_id=$value ;;
      source_date_epoch) source_date_epoch=$value ;;
      created) created=$value ;;
      verified) verified=$value ;;
      tool_missing) tool_missing=$value ;;
      tool_count) tool_count=$value ;;
      tool_summary) tool_summary=$value ;;
      package_count) package_count=$value ;;
      parse_error) parse_error=$value ;;
    esac
  done <<EOF
$fields
EOF

  [ -z "$parse_error" ] || die "verify: $parse_error ($manifest)"
  [ "$schema" = "1" ] || die "verify: manifest schema must be 1, got '$schema'"
  [ "$name" = "sysemble-engine" ] || die "verify: manifest name must be 'sysemble-engine', got '$name'"
  [ -n "$version" ] || die "verify: manifest version is empty"
  [ -n "$m_ref" ] || die "verify: manifest ref is empty"
  [ "$platform" = "$PLATFORM" ] ||
    die "verify: manifest platform '$platform' does not match '$PLATFORM'"
  [ -n "$m_image_id" ] || die "verify: manifest image_id is empty"

  # base digest: the manifest must pin the same digest as the Dockerfile.
  case "$m_base" in
    *@sha256:*) ;;
    *) die "verify: manifest base is not pinned by a sha256 digest: '$m_base'" ;;
  esac
  local m_base_repo=${m_base%%@*}
  local m_base_digest=${m_base##*@}
  [ "$m_base_digest" = "$DOCKER_BASE_DIGEST" ] ||
    die "verify: manifest base digest '$m_base_digest' does not match the Dockerfile digest '$DOCKER_BASE_DIGEST'"
  [ "$m_base_repo" = "$DOCKER_BASE_REPO" ] ||
    die "verify: manifest base repository '$m_base_repo' does not match the Dockerfile base '$DOCKER_BASE_REPO'"

  # tool_versions: all five contract tools must be present and non-empty.
  [ -z "$tool_missing" ] ||
    die "verify: manifest tool_versions is missing or empty for: $tool_missing"
  [ "${tool_count:-0}" -eq 5 ] ||
    die "verify: manifest tool_versions must contain 5 entries, got '${tool_count:-0}'"
  [ -n "$tool_summary" ] || die "verify: manifest tool_versions is empty"

  # The image reference must exist locally and match the recorded image id.
  local local_image_id=""
  if ! local_image_id=$(docker image inspect --format '{{.Id}}' "$m_ref" 2>/dev/null); then
    local inspect_error=""
    inspect_error=$(docker image inspect --format '{{.Id}}' "$m_ref" 2>&1 || true)
    die "verify: image '$m_ref' is not present locally (docker image inspect: $inspect_error)"
  fi
  [ -n "$local_image_id" ] || die "verify: docker image inspect returned an empty id for '$m_ref'"
  [ "$local_image_id" = "$m_image_id" ] ||
    die "verify: manifest image_id '$m_image_id' does not match local image '$local_image_id' (rebuild the image)"

  local verified_note=""
  if [ "$verified" = "true" ]; then
    verified_note=" (already true)"
  else
    mark_verified "$manifest" || die "verify: cannot rewrite $manifest with verified=true"
    verified_note=" (written"
    if [ -n "$created" ]; then
      verified_note="$verified_note, created $created"
    fi
    verified_note="$verified_note)"
  fi

  printf 'verify: OK  ref=%s present locally\n' "$m_ref"
  printf 'verify: OK  image_id=%s matches docker image inspect\n' "$m_image_id"
  printf 'verify: OK  base=%s matches the Dockerfile digest\n' "$m_base"
  printf 'verify: OK  tool_versions: %s\n' "$tool_summary"
  printf 'verify: OK  packages=%s\n' "$package_count"
  printf 'verify: OK  schema=%s name=%s version=%s platform=%s\n' \
    "$schema" "$name" "$version" "$platform"
  printf 'verify: manifest verified=true%s: %s\n' "$verified_note" "$manifest"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  validate_inputs

  if [ -n "$VERIFY_DIR" ]; then
    # Resolve the directory first so a bad --verify path reports the path, not
    # docker/python availability.
    local verify_dir_arg=$VERIFY_DIR
    VERIFY_DIR=$(cd "$VERIFY_DIR" 2>/dev/null && pwd -P) ||
      die "verify: manifest directory not found: $verify_dir_arg"
    require_python
    require_docker
    verify_manifest "$VERIFY_DIR"
    exit 0
  fi

  require_python
  require_docker
  build_image
  exit 0
}

main "$@"
