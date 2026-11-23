#!/usr/bin/env bash
# P0-b native `--execute` command-sequence test.
#
# macOS has no Linux, root, mmdebstrap, mkfs.ext4, or qemu-img, so this test
# fakes only the *tools* (uname/id/mmdebstrap/mkfs.ext4/qemu-img/chroot) and
# runs the real build.sh end to end. It verifies:
#   - the rootfs -> disk.img -> disk.qcow2 -> artifact.json call order
#   - the mmdebstrap customize hook writes /etc/hostname and enables the serial
#     getty (with a non-fatal warning when that enable fails)
#   - artifact.json paths/sizes/sha256 values
#   - failure cleanup keeps rootfs/ + build.log and removes partial images
#   - an existing <out>/rootfs is still refused with exit 6
#
# It does NOT prove the real commands work; the authoritative check is the CI
# boot-smoke job on ubuntu-latest.
#
# Usage: bash builders/debian/tests/build_exec_test.sh

set -euo pipefail

case "$0" in
  */*) TEST_DIR=${0%/*} ;;
  *) TEST_DIR=. ;;
esac
TEST_DIR=$(cd "$TEST_DIR" && pwd)
BUILDER_DIR=$(cd "$TEST_DIR/.." && pwd)
BUILD_SH="$BUILDER_DIR/build.sh"
PLAN="$BUILDER_DIR/testdata/plan.example.json"

if [ ! -f "$PLAN" ]; then
  printf 'FAIL: fixture plan not found: %s\n' "$PLAN" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'FAIL: build_exec_test.sh needs python3 to validate artifact.json\n' >&2
  exit 1
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sysemble-exec-test.XXXXXX") || {
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

FAKEBIN="$TMP_DIR/bin"
mkdir -p "$FAKEBIN"

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
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3 (expected '$1', got '$2')"
  fi
}

assert_contains() {
  if grep -Fq -- "$1" "$2"; then
    pass "$3"
  else
    fail "$3 (pattern '$1' not found in $2)"
  fi
}

assert_absent() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    fail "$2 (unexpected path exists: $1)"
  else
    pass "$2"
  fi
}

# ---------------------------------------------------------------------------
# Fake toolchain. Every fake logs its argv to $FAKE_LOG/calls.log so the test
# can assert the order, and the fixtures are shaped like the real outputs.
# ---------------------------------------------------------------------------

cat >"$FAKEBIN/uname" <<'SH'
#!/bin/sh
printf 'Linux\n'
SH

cat >"$FAKEBIN/id" <<'SH'
#!/bin/sh
printf '0\n'
SH

cat >"$FAKEBIN/chroot" <<'SH'
#!/bin/sh
: "${FAKE_LOG:?FAKE_LOG is required}"
printf 'chroot %s\n' "$*" >>"$FAKE_LOG/calls.log"
exit "${FAKE_CHROOT_RC:-0}"
SH

cat >"$FAKEBIN/mmdebstrap" <<'SH'
#!/bin/sh
set -eu
: "${FAKE_LOG:?FAKE_LOG is required}"
printf 'mmdebstrap %s\n' "$*" >>"$FAKE_LOG/calls.log"

hook=""
variant=""
include=""
rootfs=""
for arg in "$@"; do
  case "$arg" in
    --customize-hook=*) hook=${arg#--customize-hook=} ;;
    --variant=*) variant=${arg#--variant=} ;;
    --include=*) include=${arg#--include=} ;;
  esac
  rootfs=$arg
done

if [ "$variant" != "minbase" ]; then
  echo "fake mmdebstrap: unexpected --variant '$variant'" >&2
  exit 1
fi
case ",$include," in
  *,linux-image-amd64,*) ;;
  *)
    echo "fake mmdebstrap: --include does not contain linux-image-amd64" >&2
    exit 1
    ;;
esac
if [ ! -d "$rootfs" ]; then
  mkdir -p "$rootfs"
fi
mkdir -p "$rootfs/boot" "$rootfs/etc" "$rootfs/usr/bin" "$rootfs/var/lib/dpkg"
printf 'kernel 6.1.0\n' >"$rootfs/boot/vmlinuz-6.1.0"
printf 'kernel 6.12.3\n' >"$rootfs/boot/vmlinuz-6.12.3"
printf 'initrd 6.1.0\n' >"$rootfs/boot/initrd.img-6.1.0"
printf 'initrd 6.12.3\n' >"$rootfs/boot/initrd.img-6.12.3"
printf 'PRETTY_NAME="Debian GNU/Linux trixie/sid"\n' >"$rootfs/etc/os-release"
printf 'fake rootfs\n' >"$rootfs/usr/bin/sysemble-fixture"
echo "fake mmdebstrap: rootfs at $rootfs"

if [ -n "$hook" ]; then
  sh -c "$hook" mmdebstrap "$rootfs"
fi
SH

cat >"$FAKEBIN/mkfs.ext4" <<'SH'
#!/bin/sh
set -eu
: "${FAKE_LOG:?FAKE_LOG is required}"
printf 'mkfs.ext4 %s\n' "$*" >>"$FAKE_LOG/calls.log"

rootfs=""
label=""
img=""
prev=""
for arg in "$@"; do
  case "$prev" in
    -d) rootfs=$arg ;;
    -L) label=$arg ;;
    -F) img=$arg ;;
  esac
  prev=$arg
done

if [ -z "$rootfs" ] || [ ! -d "$rootfs" ]; then
  echo "fake mkfs.ext4: -d rootfs is missing or not a directory" >&2
  exit 1
fi
if [ "$label" != "SYMBLE" ]; then
  echo "fake mkfs.ext4: expected -L SYMBLE, got '$label'" >&2
  exit 1
fi
if [ -z "$img" ] || [ ! -f "$img" ]; then
  echo "fake mkfs.ext4: -F image is missing" >&2
  exit 1
fi

# Write a marker without changing the truncated image size.
printf 'EXT4' | dd of="$img" bs=1 count=4 conv=notrunc 2>/dev/null
echo "fake mkfs.ext4: label SYMBLE, rootfs $rootfs"
SH

cat >"$FAKEBIN/qemu-img" <<'SH'
#!/bin/sh
set -eu
: "${FAKE_LOG:?FAKE_LOG is required}"
printf 'qemu-img %s\n' "$*" >>"$FAKE_LOG/calls.log"

if [ "${1:-}" != "convert" ] || [ "${2:-}" != "-O" ] || [ "${3:-}" != "qcow2" ]; then
  echo "fake qemu-img: unexpected argv: $*" >&2
  exit 1
fi
prev=""
last=""
for arg in "$@"; do
  prev=$last
  last=$arg
done
raw=$prev
qcow=$last
if [ ! -f "$raw" ]; then
  echo "fake qemu-img: raw image is missing: $raw" >&2
  exit 1
fi

if [ "${FAKE_QEMU_FAIL:-0}" = "1" ]; then
  printf 'partial qcow2\n' >"$qcow"
  echo "fake qemu-img: injected failure" >&2
  exit 1
fi

printf 'QCOW2\n' >"$qcow"
echo "fake qemu-img: $raw -> $qcow"
SH

chmod +x "$FAKEBIN"/*

# ---------------------------------------------------------------------------
# Run helper. PATH is prefixed only for the build.sh process, so the test
# itself keeps the real uname/id/tools.
# ---------------------------------------------------------------------------

run_build() {
  local out=$1
  local log=$2
  shift 2

  PATH="$FAKEBIN:$PATH" bash "$BUILD_SH" --plan "$PLAN" --out "$out" "$@" \
    >"$log" 2>&1
}

# artifact.json checker used by both successful builds.
validate_artifact() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import os
import re
import sys

path, out, expected_spec = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    doc = json.load(fh)

def check(condition, message):
    if not condition:
        sys.exit("FAIL: " + message)

check(doc["apiVersion"] == "sysemble/artifact/v1", "apiVersion")
check(doc["spec"] == expected_spec, "spec")
check(doc["arch"] == "x86_64", "arch")
check(doc["base"]["kind"] == "debian", "base.kind")
check(doc["base"]["release"] == "trixie", "base.release")
check(doc["base"]["pin"] == "2026-11-01", "base.pin")
check(len(doc["packages"]) == 43, "packages count (fixture plan)")
check(doc["rootfs"]["path"] == "rootfs", "rootfs.path")
check(doc["rootfs"]["size_mb"] >= 1, "rootfs.size_mb")
check(len(doc["images"]) == 2, "images count")
by_format = {image["format"]: image for image in doc["images"]}
check(set(by_format) == {"raw", "qcow2"}, "image formats")
for image in doc["images"]:
    check(re.fullmatch(r"[0-9a-f]{64}", image["sha256"]) is not None, "sha256 " + image["format"])
    check(os.path.isfile(os.path.join(out, image["path"])), "image exists " + image["path"])
check(by_format["raw"]["size_mb"] == 2048, "raw size is the 2048 MB floor")
check(by_format["qcow2"]["size_mb"] == 1, "qcow2 fake size")
check(doc["boot"]["kernel"] == "rootfs/boot/vmlinuz-6.12.3", "kernel 6.12.3")
check(doc["boot"]["initrd"] == "rootfs/boot/initrd.img-6.12.3", "initrd 6.12.3")
check(
    doc["boot"]["cmdline"]
    == "console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target",
    "cmdline",
)
check(re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", doc["createdAt"]) is not None, "createdAt")
check(doc["builder"] == {"name": "build.sh", "version": "0.1.0"}, "builder")
PY
}

# ---------------------------------------------------------------------------
# Case 1: full successful --execute path
# ---------------------------------------------------------------------------

export FAKE_CHROOT_RC=0
export FAKE_QEMU_FAIL=0

OUT1="$TMP_DIR/out-main"
LOG1="$TMP_DIR/run-main.log"
FAKE_LOG="$TMP_DIR/fake-main"
export FAKE_LOG
mkdir -p "$FAKE_LOG"

if run_build "$OUT1" "$LOG1" --execute; then
  pass "--execute exits 0 with the fake toolchain"
else
  cat "$LOG1" >&2
  fail "--execute did not exit 0"
fi

if [ -f "$OUT1/artifact.json" ]; then
  pass "artifact.json exists"
  if validate_artifact "$OUT1/artifact.json" "$OUT1" "debian-kde-dev"; then
    pass "artifact.json paths, sizes, shas, boot entries are valid"
  else
    fail "artifact.json validation failed"
  fi
else
  fail "artifact.json was not written"
fi

assert_eq "debian-kde-dev" "$(cat "$OUT1/rootfs/etc/hostname" 2>/dev/null || true)" \
  "customize hook writes plan.spec to /etc/hostname"

RAW_BYTES=$(wc -c <"$OUT1/disk.img" 2>/dev/null | tr -d ' ' || true)
assert_eq "2147483648" "$RAW_BYTES" "truncate created a 2048 MiB raw image"

CALLS="$FAKE_LOG/calls.log"
if [ -f "$CALLS" ]; then
  pass "fake tools recorded calls"
else
  fail "fake tools did not record calls"
fi

M_LINE=$(grep -n '^mmdebstrap ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
K_LINE=$(grep -n '^mkfs.ext4 ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
Q_LINE=$(grep -n '^qemu-img ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
C_LINE=$(grep -n '^chroot ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)

if [ -n "$M_LINE" ] && [ -n "$K_LINE" ] && [ -n "$Q_LINE" ] &&
  [ "$M_LINE" -lt "$K_LINE" ] && [ "$K_LINE" -lt "$Q_LINE" ]; then
  pass "call order is mmdebstrap -> mkfs.ext4 -> qemu-img ($M_LINE < $K_LINE < $Q_LINE)"
else
  fail "call order is wrong (mmdebstrap=$M_LINE mkfs.ext4=$K_LINE qemu-img=$Q_LINE)"
fi

if [ -n "$C_LINE" ] && [ -n "$M_LINE" ] && [ "$C_LINE" -gt "$M_LINE" ]; then
  pass "customize hook ran chroot after mmdebstrap started"
else
  fail "customize hook/chroot was not invoked (chroot line: ${C_LINE:-missing})"
fi

assert_contains "serial-getty@ttyS0.service" "$CALLS" "hook enables serial-getty@ttyS0.service"
assert_contains "include=apt,ca-certificates" "$CALLS" "mmdebstrap received the plan package list"
assert_contains "-L SYMBLE" "$CALLS" "mkfs.ext4 received -L SYMBLE"
OUT1_ABS=$(cd "$OUT1" && pwd -P)
assert_contains "-d $OUT1_ABS/rootfs" "$CALLS" "mkfs.ext4 received -d <out>/rootfs"
assert_contains "convert -O qcow2 $OUT1_ABS/disk.img $OUT1_ABS/disk.qcow2" "$CALLS" \
  "qemu-img converted raw to qcow2"

assert_contains "fake mmdebstrap: rootfs at" "$OUT1/build.log" "build.log tees mmdebstrap output"
assert_contains "fake mkfs.ext4: label SYMBLE" "$OUT1/build.log" "build.log tees mkfs.ext4 output"
assert_contains "fake qemu-img:" "$OUT1/build.log" "build.log tees qemu-img output"
assert_contains "stage 6/6: write artifact manifest" "$OUT1/build.log" "build.log records all stages"

# ---------------------------------------------------------------------------
# Case 2: serial getty enable failure is non-fatal and lands in build.log
# ---------------------------------------------------------------------------

OUT2="$TMP_DIR/out-warn"
LOG2="$TMP_DIR/run-warn.log"
FAKE_LOG="$TMP_DIR/fake-warn"
export FAKE_LOG
mkdir -p "$FAKE_LOG"

export FAKE_CHROOT_RC=1

if run_build "$OUT2" "$LOG2"; then
  pass "failed systemctl enable does not fail the build (no --execute flag either)"
else
  cat "$LOG2" >&2
  fail "failed systemctl enable broke the build"
fi
export FAKE_CHROOT_RC=0
assert_eq "debian-kde-dev" "$(cat "$OUT2/rootfs/etc/hostname" 2>/dev/null || true)" \
  "hostname is still written when serial getty enable fails"
assert_contains "could not enable serial-getty@ttyS0.service (non-fatal)" "$OUT2/build.log" \
  "build.log records the non-fatal serial getty warning"
if [ -f "$OUT2/artifact.json" ]; then
  pass "artifact.json is still written after the warning path"
else
  fail "artifact.json missing after the warning path"
fi

# ---------------------------------------------------------------------------
# Case 3: qemu-img failure cleans partial images, keeps rootfs/ + build.log
# ---------------------------------------------------------------------------

OUT3="$TMP_DIR/out-fail"
LOG3="$TMP_DIR/run-fail.log"
FAKE_LOG="$TMP_DIR/fake-fail"
export FAKE_LOG
mkdir -p "$FAKE_LOG"

export FAKE_QEMU_FAIL=1
RC3=0
if run_build "$OUT3" "$LOG3" --execute; then
  RC3=0
else
  RC3=$?
fi
export FAKE_QEMU_FAIL=0
assert_eq "6" "$RC3" "qemu-img failure exits 6"
assert_absent "$OUT3/disk.img" "failed build removes partial disk.img"
assert_absent "$OUT3/disk.qcow2" "failed build removes partial disk.qcow2"
if [ -d "$OUT3/rootfs" ]; then
  pass "failed build keeps rootfs/"
else
  fail "failed build removed rootfs/"
fi
if [ -f "$OUT3/build.log" ]; then
  pass "failed build keeps build.log"
else
  fail "failed build removed build.log"
fi
assert_contains "qemu-img convert failed" "$OUT3/build.log" "failed build logs the qemu-img error"

# ---------------------------------------------------------------------------
# Case 4: an existing <out>/rootfs is refused with exit 6
# ---------------------------------------------------------------------------

OUT4="$TMP_DIR/out-existing"
LOG4="$TMP_DIR/run-existing.log"
mkdir -p "$OUT4/rootfs"
FAKE_LOG="$TMP_DIR/fake-existing"
export FAKE_LOG
mkdir -p "$FAKE_LOG"

RC4=0
if run_build "$OUT4" "$LOG4" --execute; then
  RC4=0
else
  RC4=$?
fi
assert_eq "6" "$RC4" "existing <out>/rootfs exits 6"
assert_contains "refusing to overwrite existing path" "$OUT4/build.log" \
  "existing rootfs refusal is recorded in build.log"

# ---------------------------------------------------------------------------
# Case 5: --dry-run and --execute are mutually exclusive
# ---------------------------------------------------------------------------

RC5=0
if bash "$BUILD_SH" --plan "$PLAN" --out "$TMP_DIR/out-both" --dry-run --execute \
  >"$TMP_DIR/run-both.log" 2>&1; then
  RC5=0
else
  RC5=$?
fi
assert_eq "2" "$RC5" "--dry-run + --execute exits 2"

# ---------------------------------------------------------------------------
# Case 6: docker + --execute is rejected instead of pretending to be P0-b
# ---------------------------------------------------------------------------

RC6=0
if bash "$BUILD_SH" --plan "$PLAN" --out "$TMP_DIR/out-docker-exec" \
  --engine docker --execute >"$TMP_DIR/run-docker-exec.log" 2>&1; then
  RC6=0
else
  RC6=$?
fi
assert_eq "2" "$RC6" "--engine docker + --execute exits 2"
assert_contains "native-only" "$TMP_DIR/run-docker-exec.log" \
  "docker + --execute explains that assembly is native-only"
assert_absent "$TMP_DIR/out-docker-exec" "docker + --execute creates no output directory"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf '\nbuild_exec_test.sh: %d failure(s), %d passed check(s)\n' "$FAILURES" "$PASS" >&2
  exit 1
fi
printf '\nbuild_exec_test.sh: all %d checks passed\n' "$PASS"
