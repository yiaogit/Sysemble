#!/usr/bin/env bash
# P0-b artifact manifest tests.
#
# Runs entirely offline: no Linux, root, mmdebstrap, mkfs.ext4, qemu-img or
# qemu is required. It builds a fixture rootfs, sources lib.sh (which defines
# functions only), calls the pure artifact_json()/compute_disk_size_mb()
# helpers, and validates the result with python3.
#
# Usage: bash builders/debian/tests/artifact_test.sh

set -euo pipefail

case "$0" in
  */*) TEST_DIR=${0%/*} ;;
  *) TEST_DIR=. ;;
esac
TEST_DIR=$(cd "$TEST_DIR" && pwd)
BUILDER_DIR=$(cd "$TEST_DIR/.." && pwd)

# shellcheck source=builders/debian/lib.sh
. "$BUILDER_DIR/lib.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sysemble-artifact-test.XXXXXX") || {
  printf 'FAIL: cannot create a temporary directory\n' >&2
  exit 1
}
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

PASS=0
FAILURES=0

pass() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "$PASS" "$*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'not ok %d - %s\n' "$((PASS + FAILURES))" "$*" >&2
}

assert_eq() {
  local expected=$1
  local actual=$2
  local label=$3

  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

json_backend=python3
if ! command -v python3 >/dev/null 2>&1; then
  if command -v jq >/dev/null 2>&1; then
    json_backend=jq
  else
    printf 'FAIL: artifact_test.sh needs python3 or jq to validate JSON\n' >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Fixture: a rootfs with two kernel/initrd versions plus the disk images.
# ---------------------------------------------------------------------------

OUT="$TMP_DIR/out"
ROOTFS="$OUT/rootfs"
mkdir -p "$ROOTFS/boot" "$ROOTFS/etc" "$ROOTFS/usr/bin" "$ROOTFS/var/lib/dpkg"

printf 'kernel 6.1.0\n' >"$ROOTFS/boot/vmlinuz-6.1.0"
printf 'kernel 6.12.3\n' >"$ROOTFS/boot/vmlinuz-6.12.3"
printf 'initrd 6.1.0\n' >"$ROOTFS/boot/initrd.img-6.1.0"
printf 'initrd 6.12.3\n' >"$ROOTFS/boot/initrd.img-6.12.3"
# These must be ignored by the versioned lookup.
printf 'not a versioned kernel\n' >"$ROOTFS/boot/vmlinuz"
printf 'not a versioned initrd\n' >"$ROOTFS/boot/initrd.img"
printf 'config\n' >"$ROOTFS/boot/config-6.12.3"
printf 'sysemble\n' >"$ROOTFS/etc/hostname"
printf '#!/bin/sh\n' >"$ROOTFS/usr/bin/sysemble-fixture"

printf 'raw-image\n' >"$OUT/disk.img"
truncate -s 3M "$OUT/disk.img"

# Fake qemu-img: only the artifact test needs a qcow2 file, not a real
# conversion. This mirrors how the CI fake toolchain produces disk.qcow2.
FAKEBIN="$TMP_DIR/bin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/qemu-img" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" != "convert" ] || [ "${2:-}" != "-O" ] || [ "${3:-}" != "qcow2" ]; then
  echo "fake qemu-img: unexpected argv: $*" >&2
  exit 1
fi
last=""
for arg in "$@"; do
  last=$arg
done
printf 'qcow2-image\n' >"$last"
SH
chmod +x "$FAKEBIN/qemu-img"
"$FAKEBIN/qemu-img" convert -O qcow2 "$OUT/disk.img" "$OUT/disk.qcow2"

PACKAGES=(apt ca-certificates systemd)
JSON="$TMP_DIR/artifact.json"
CREATED_AT="2026-11-23T12:00:00Z"

if artifact_json "$OUT" "minimal-debian" "trixie" "2026-11-01" \
  "x86_64" "$CREATED_AT" "${PACKAGES[@]}" >"$JSON"; then
  pass "artifact_json exits 0"
else
  fail "artifact_json exited non-zero"
fi

# ---------------------------------------------------------------------------
# JSON shape / values
# ---------------------------------------------------------------------------

if [ "$json_backend" = "python3" ]; then
  if python3 - "$JSON" "$OUT" "$CREATED_AT" <<'PY'
import json
import os
import re
import sys

path, out, created_at = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    doc = json.load(fh)

def check(condition, message):
    if not condition:
        sys.exit("FAIL: " + message)
    print("ok - " + message)

check(isinstance(doc, dict), "artifact is a JSON object")
check(
    set(doc) == {
        "apiVersion", "createdAt", "spec", "base", "arch", "packages",
        "rootfs", "images", "boot", "builder",
    },
    "top-level keys match sysemble/artifact/v1",
)
check(doc["apiVersion"] == "sysemble/artifact/v1", "apiVersion is sysemble/artifact/v1")
check(doc["createdAt"] == created_at, "createdAt is the supplied timestamp")
check(doc["spec"] == "minimal-debian", "spec comes from plan.spec")
check(
    doc["base"] == {"kind": "debian", "release": "trixie", "pin": "2026-11-01"},
    "base has kind/release/pin",
)
check(doc["arch"] == "x86_64", "arch comes from plan.target.arch")
check(doc["packages"] == ["apt", "ca-certificates", "systemd"], "packages match the argument list")
check(doc["rootfs"]["path"] == "rootfs", "rootfs.path is rootfs")
check(
    isinstance(doc["rootfs"]["size_mb"], int) and doc["rootfs"]["size_mb"] >= 1,
    "rootfs.size_mb is a positive integer",
)

images = doc["images"]
check(isinstance(images, list) and len(images) == 2, "images has two entries")
by_format = {image["format"]: image for image in images}
check(set(by_format) == {"raw", "qcow2"}, "images formats are raw and qcow2")
check(by_format["raw"]["path"] == "disk.img", "raw image path is disk.img")
check(by_format["qcow2"]["path"] == "disk.qcow2", "qcow2 image path is disk.qcow2")

for image in images:
    check(
        isinstance(image["sha256"], str)
        and re.fullmatch(r"[0-9a-f]{64}", image["sha256"]) is not None,
        "%s sha256 is 64 lowercase hex chars" % image["format"],
    )
    expected_mb = (os.path.getsize(os.path.join(out, image["path"])) + 1048575) // 1048576
    check(image["size_mb"] == expected_mb, "%s size_mb matches the file size" % image["format"])

boot = doc["boot"]
check(boot["kernel"] == "rootfs/boot/vmlinuz-6.12.3", "highest kernel version wins (6.12.3)")
check(boot["initrd"] == "rootfs/boot/initrd.img-6.12.3", "highest initrd version wins (6.12.3)")
check(
    boot["cmdline"] == "console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target",
    "boot.cmdline is the frozen P0-b cmdline",
)
check(os.path.isfile(os.path.join(out, boot["kernel"])), "boot.kernel exists under <out>")
check(os.path.isfile(os.path.join(out, boot["initrd"])), "boot.initrd exists under <out>")
check(doc["builder"] == {"name": "build.sh", "version": "0.1.0"}, "builder name/version")
PY
  then
    pass "artifact JSON shape and values"
  else
    fail "artifact JSON shape and values"
  fi
else
  # jq fallback keeps the test runnable on hosts without python3.
  if jq -e '
      .apiVersion == "sysemble/artifact/v1" and
      .spec == "minimal-debian" and
      .base == {"kind":"debian","release":"trixie","pin":"2026-11-01"} and
      .arch == "x86_64" and
      .packages == ["apt","ca-certificates","systemd"] and
      .rootfs.path == "rootfs" and
      (.rootfs.size_mb >= 1) and
      (.images | length == 2) and
      ([.images[].format] | sort == ["qcow2","raw"]) and
      ([.images[].sha256 | test("^[0-9a-f]{64}$")] | all) and
      .boot.kernel == "rootfs/boot/vmlinuz-6.12.3" and
      .boot.initrd == "rootfs/boot/initrd.img-6.12.3" and
      .boot.cmdline == "console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target" and
      .builder == {"name":"build.sh","version":"0.1.0"}
    ' "$JSON" >/dev/null 2>&1; then
    pass "artifact JSON shape and values (jq)"
  else
    fail "artifact JSON shape and values (jq)"
  fi
fi

# ---------------------------------------------------------------------------
# JSON escaping (spec values from a plan are not character-class validated)
# ---------------------------------------------------------------------------

WEIRD_SPEC='odd"spec\path'
WEIRD_JSON="$TMP_DIR/artifact-weird.json"
if artifact_json "$OUT" "$WEIRD_SPEC" "trixie" "" "x86_64" "$CREATED_AT" "${PACKAGES[@]}" \
  >"$WEIRD_JSON" 2>/dev/null; then
  pass "artifact_json handles a quote/backslash spec"
else
  fail "artifact_json failed for a quote/backslash spec"
fi

if [ "$json_backend" = "python3" ]; then
  if python3 - "$WEIRD_JSON" "$WEIRD_SPEC" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)
if doc["spec"] != sys.argv[2]:
    sys.exit("spec round-trip mismatch")
if doc["base"]["pin"] is not None:
    sys.exit("missing pin must be null")
PY
  then
    pass "escaped spec round-trips and missing pin is null"
  else
    fail "escaped spec round-trips and missing pin is null"
  fi
else
  if jq -e '.base.pin == null' "$WEIRD_JSON" >/dev/null 2>&1; then
    pass "missing pin is null (jq)"
  else
    fail "missing pin is null (jq)"
  fi
fi

# ---------------------------------------------------------------------------
# Missing kernel / initrd must fail (build.sh maps this to exit 6)
# ---------------------------------------------------------------------------

mkdir -p "$TMP_DIR/held"
mv "$ROOTFS/boot/vmlinuz-6.1.0" "$ROOTFS/boot/vmlinuz-6.12.3" "$TMP_DIR/held/"

if artifact_json "$OUT" "minimal-debian" "trixie" "2026-11-01" "x86_64" \
  "$CREATED_AT" "${PACKAGES[@]}" >"$TMP_DIR/no-kernel.json" 2>"$TMP_DIR/no-kernel.err"; then
  fail "artifact_json must fail when no kernel exists"
else
  if grep -q 'no kernel found' "$TMP_DIR/no-kernel.err"; then
    pass "missing kernel fails with a readable error"
  else
    fail "missing kernel error is not readable"
  fi
fi

mv "$TMP_DIR/held/vmlinuz-6.1.0" "$TMP_DIR/held/vmlinuz-6.12.3" "$ROOTFS/boot/"
mv "$ROOTFS/boot/initrd.img-6.1.0" "$ROOTFS/boot/initrd.img-6.12.3" "$TMP_DIR/held/"

if artifact_json "$OUT" "minimal-debian" "trixie" "2026-11-01" "x86_64" \
  "$CREATED_AT" "${PACKAGES[@]}" >"$TMP_DIR/no-initrd.json" 2>"$TMP_DIR/no-initrd.err"; then
  fail "artifact_json must fail when no initrd exists"
else
  if grep -q 'no initrd found' "$TMP_DIR/no-initrd.err"; then
    pass "missing initrd fails with a readable error"
  else
    fail "missing initrd error is not readable"
  fi
fi
mv "$TMP_DIR/held/initrd.img-6.1.0" "$TMP_DIR/held/initrd.img-6.12.3" "$ROOTFS/boot/"

# ---------------------------------------------------------------------------
# Disk sizing formula
# ---------------------------------------------------------------------------

assert_eq "2048" "$(compute_disk_size_mb 1)" "1 MB rootfs clamps to the 2048 MB floor"
assert_eq "2048" "$(compute_disk_size_mb 500)" "500 MB rootfs clamps to the 2048 MB floor"
assert_eq "2304" "$(compute_disk_size_mb 1000)" "1000 MB rootfs -> 2304 MB (1600+512 rounded to 256)"
assert_eq "3840" "$(compute_disk_size_mb 2000)" "2000 MB rootfs -> 3840 MB"
assert_eq "2048" "$(compute_disk_size_mb 100)" "100 MB rootfs clamps to 2048 MB"

if compute_disk_size_mb "not-a-number" >/dev/null 2>&1; then
  fail "compute_disk_size_mb rejects non-numeric input"
else
  pass "compute_disk_size_mb rejects non-numeric input"
fi

ROOTFS_MB=$(rootfs_size_mb "$ROOTFS")
case "$ROOTFS_MB" in
  '' | *[!0-9]*) fail "rootfs_size_mb returns an integer (got '$ROOTFS_MB')" ;;
  *) pass "rootfs_size_mb returns $ROOTFS_MB MB for the fixture" ;;
esac

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf '\nartifact_test.sh: %d failure(s), %d passed check(s)\n' "$FAILURES" "$PASS" >&2
  exit 1
fi
printf '\nartifact_test.sh: all %d checks passed\n' "$PASS"
