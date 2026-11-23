#!/usr/bin/env bash
# P0-c/P0-d1 native `--execute` command-sequence test.
#
# macOS has no Linux, root, mmdebstrap, sgdisk, mkfs.ext4, mkfs.vfat, mcopy,
# grub-mkstandalone, dd (as a controllable fake), or qemu-img, so this test
# fakes only the *tools* and runs the real build.sh end to end. It verifies:
#   - the rootfs -> sgdisk -> mkfs.ext4 -> mkfs.vfat -> grub-mkstandalone ->
#     mcopy -> dd -> qemu-img call order
#   - the frozen GPT partition arguments, ext4 offset/label, ESP size, dd seek
#   - the generated grub.cfg (hd0,gpt2), root=/dev/vda2, console=ttyS0, and
#     the actual kernel/initrd versions
#   - the grub-mkstandalone module list and embedded config argument
#   - the UEFI artifact fields: mode/disk/grub/partitions/cmdline/images
#   - P0-d1: a DM plan (KDE: sddm+plasma-desktop) produces the graphical
#     desktop object, graphical=true, memory_mb=2048, and a graphical.target +
#     journald-forwarding cmdline; grub.cfg and artifact.json agree byte for
#     byte
#   - P0-d1: a graphical build adds xserver-xorg/procps and installs + enables
#     the sysemble-boot-evidence.service marker unit; a no-DM build adds none
#     of them
#   - P0-d1: a no-DM plan keeps graphical=false, memory_mb=1024, no desktop
#     object, and the frozen multi-user cmdline; grub.cfg agrees
#   - failure cleanup keeps rootfs + disk.img + build.log, removes esp.img and
#     partial qcow2 (GRUB and qemu-img failure paths)
#   - preflight reports every missing P0-c tool
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
# KDE fixture: a display manager (sddm) + session (plasma-desktop) -> graphical.
PLAN="$BUILDER_DIR/testdata/plan.example.json"
# Minimal fixture with no display manager -> frozen P0-c multi-user behavior.
PLAN_NODM="$BUILDER_DIR/testdata/plan.no-desktop.json"

# shellcheck source=builders/debian/lib.sh
. "$BUILDER_DIR/lib.sh"

if [ ! -f "$PLAN" ]; then
  printf 'FAIL: fixture plan not found: %s\n' "$PLAN" >&2
  exit 1
fi
if [ ! -f "$PLAN_NODM" ]; then
  printf 'FAIL: no-desktop fixture plan not found: %s\n' "$PLAN_NODM" >&2
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

assert_not_contains() {
  if grep -Fq -- "$1" "$2"; then
    fail "$3 (unexpected pattern '$1' found in $2)"
  else
    pass "$3"
  fi
}

assert_file() {
  if [ -f "$1" ]; then
    pass "$2"
  else
    fail "$2 (missing file: $1)"
  fi
}

artifact_boot_cmdline() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["boot"]["cmdline"])' "$1"
}

grub_kernel_cmdline() {
  sed -n 's/^  linux \/boot\/[^ ]* //p' "$1" | head -n 1
}

# ---------------------------------------------------------------------------
# Fake toolchain. Every fake logs its argv to $FAKE_LOG/calls.log so the test
# can assert the order, and validates the exact P0-c arguments.
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

cat >"$FAKEBIN/sgdisk" <<'SH'
#!/bin/sh
set -eu
: "${FAKE_LOG:?FAKE_LOG is required}"
printf 'sgdisk %s\n' "$*" >>"$FAKE_LOG/calls.log"

if [ "${1:-}" = "-Z" ]; then
  if [ "$#" -ne 2 ] || [ ! -f "${2:-}" ]; then
    echo "fake sgdisk: bad -Z invocation: $*" >&2
    exit 1
  fi
  echo "fake sgdisk: wiped GPT on $2"
  exit 0
fi

if [ "${1:-}" = "-n" ] &&
  [ "${2:-}" = "1:2048:+512M" ] &&
  [ "${3:-}" = "-t" ] &&
  [ "${4:-}" = "1:ef00" ] &&
  [ "${5:-}" = "-n" ] &&
  [ "${6:-}" = "2:0:0" ] &&
  [ "${7:-}" = "-t" ] &&
  [ "${8:-}" = "2:8300" ] &&
  [ "$#" -eq 9 ] && [ -f "${9:-}" ]; then
  echo "fake sgdisk: ESP + root partitions on $9"
  exit 0
fi

echo "fake sgdisk: bad partition invocation: $*" >&2
exit 1
SH

cat >"$FAKEBIN/mkfs.ext4" <<'SH'
#!/bin/sh
set -eu
: "${FAKE_LOG:?FAKE_LOG is required}"
printf 'mkfs.ext4 %s\n' "$*" >>"$FAKE_LOG/calls.log"

rootfs=""
label=""
offset=""
blocksize=""
force=0
second_last=""
last=""
for arg in "$@"; do
  case "$arg" in
    -F) force=1 ;;
  esac
  second_last=$last
  last=$arg
done
img=$second_last
blocks=$last
# The -d/-L/-E/-b values are still parsed with a small state machine below.
prev=""
for arg in "$@"; do
  case "$prev" in
    -d) rootfs=$arg ;;
    -L) label=$arg ;;
    -E) offset=$arg ;;
    -b) blocksize=$arg ;;
  esac
  prev=$arg
done

if [ "$force" -ne 1 ]; then
  echo "fake mkfs.ext4: -F was not passed" >&2
  exit 1
fi
if [ "$offset" != "offset=537919488" ]; then
  echo "fake mkfs.ext4: expected -E offset=537919488 (513 MiB), got '$offset'" >&2
  exit 1
fi
if [ "$blocksize" != "4096" ]; then
  echo "fake mkfs.ext4: expected -b 4096, got '$blocksize'" >&2
  exit 1
fi
if [ -z "$rootfs" ] || [ ! -d "$rootfs" ]; then
  echo "fake mkfs.ext4: -d rootfs is missing or not a directory" >&2
  exit 1
fi
if [ "$label" != "SYMBLE" ]; then
  echo "fake mkfs.ext4: expected -L SYMBLE, got '$label'" >&2
  exit 1
fi
if [ -z "$img" ] || [ ! -f "$img" ]; then
  echo "fake mkfs.ext4: ext4 image is missing (img='$img' blocks='$blocks')" >&2
  exit 1
fi
case "$blocks" in
  '' | *[!0-9]*)
    echo "fake mkfs.ext4: expected an explicit 4 KiB block count, got '$blocks'" >&2
    exit 1
    ;;
esac
if [ "$blocks" -ne 916992 ]; then
  echo "fake mkfs.ext4: expected 916992 blocks for the 4096 MiB disk, got $blocks" >&2
  exit 1
fi
# The explicit size must keep ext4 inside GPT partition 2 (and leave the last
# 1 MiB, which holds the backup GPT, untouched).
img_bytes=$(wc -c <"$img" | tr -d ' ')
if [ $((blocks * 4096 + 537919488)) -gt "$img_bytes" ]; then
  echo "fake mkfs.ext4: filesystem extends past disk.img" >&2
  exit 1
fi

echo "fake mkfs.ext4: offset 513 MiB, $blocks blocks, label SYMBLE, rootfs $rootfs"
SH

cat >"$FAKEBIN/mkfs.vfat" <<'SH'
#!/bin/sh
set -eu
: "${FAKE_LOG:?FAKE_LOG is required}"
printf 'mkfs.vfat %s\n' "$*" >>"$FAKE_LOG/calls.log"

if [ "$#" -ne 7 ] ||
  [ "${1:-}" != "-F" ] || [ "${2:-}" != "32" ] ||
  [ "${3:-}" != "-C" ] || [ "${4:-}" != "-n" ] || [ "${5:-}" != "ESP" ] ||
  [ "${7:-}" != "524288" ]; then
  echo "fake mkfs.vfat: expected -F 32 -C -n ESP <img> 524288, got: $*" >&2
  exit 1
fi

img=${6}
case "$img" in
  /*) ;;
  *)
    echo "fake mkfs.vfat: expected an absolute esp.img path, got '$img'" >&2
    exit 1
    ;;
esac
# Match the real mkfs.vfat -C file: exactly 524288 KiB = 512 MiB.
size=536870912
if [ "${FAKE_VFAT_BAD_SIZE:-0}" = "1" ]; then
  # 513 MiB: one MiB too large to fit GPT partition 1.
  size=537919488
fi
truncate -s "$size" "$img"
echo "fake mkfs.vfat: $img ($((size / 1024 / 1024)) MiB)"
SH

cat >"$FAKEBIN/grub-mkstandalone" <<'SH'
#!/bin/sh
set -eu
: "${FAKE_LOG:?FAKE_LOG is required}"
printf 'grub-mkstandalone %s\n' "$*" >>"$FAKE_LOG/calls.log"

if [ "${1:-}" != "-O" ] || [ "${2:-}" != "x86_64-efi" ]; then
  echo "fake grub-mkstandalone: expected -O x86_64-efi, got: $*" >&2
  exit 1
fi

out=""
modules=""
embedded=""
source=""
for arg in "$@"; do
  case "$arg" in
    --modules=*) modules=${arg#--modules=} ;;
    boot/grub/grub.cfg=*) embedded=$arg; source=${arg#boot/grub/grub.cfg=} ;;
  esac
done
# -o is the value after the -o flag.
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then
    out=$arg
  fi
  prev=$arg
done

expected="part_gpt part_msdos fat ext2 normal linux search search_fs_uuid configfile serial terminal echo test"
if [ "$modules" != "$expected" ]; then
  echo "fake grub-mkstandalone: unexpected --modules: '$modules'" >&2
  exit 1
fi
if [ -z "$embedded" ] || [ -z "$source" ] || [ ! -f "$source" ]; then
  echo "fake grub-mkstandalone: embedded grub.cfg argument is missing or unreadable" >&2
  exit 1
fi
if ! grep -Fq 'set root=(hd0,gpt2)' "$source"; then
  echo "fake grub-mkstandalone: embedded grub.cfg lacks (hd0,gpt2)" >&2
  exit 1
fi
if ! grep -Fq 'root=/dev/vda2' "$source"; then
  echo "fake grub-mkstandalone: embedded grub.cfg lacks root=/dev/vda2" >&2
  exit 1
fi
if [ -z "$out" ]; then
  echo "fake grub-mkstandalone: -o BOOTX64.EFI path is missing" >&2
  exit 1
fi

if [ "${FAKE_GRUB_FAIL:-0}" = "1" ]; then
  printf 'partial BOOTX64.EFI\n' >"$out"
  echo "fake grub-mkstandalone: injected failure" >&2
  exit 1
fi

printf 'fake BOOTX64.EFI\n' >"$out"
echo "fake grub-mkstandalone: wrote $out"
SH

cat >"$FAKEBIN/mcopy" <<'SH'
#!/bin/sh
set -eu
: "${FAKE_LOG:?FAKE_LOG is required}"
printf 'mcopy %s\n' "$*" >>"$FAKE_LOG/calls.log"

if [ "${1:-}" != "-i" ] || [ "${3:-}" != "-s" ] || [ "${5:-}" != "::/" ]; then
  echo "fake mcopy: expected -i <img> -s <EFI> ::/, got: $*" >&2
  exit 1
fi
img=$2
src=$4

if [ ! -f "$img" ]; then
  echo "fake mcopy: ESP image is missing: $img" >&2
  exit 1
fi
case "$src" in
  */EFI) stage_root=${src%/EFI} ;;
  *)
    echo "fake mcopy: expected a staging .../EFI source, got '$src'" >&2
    exit 1
    ;;
esac
if [ ! -f "$src/BOOT/BOOTX64.EFI" ]; then
  echo "fake mcopy: staging BOOTX64.EFI is missing under $src" >&2
  exit 1
fi
if [ ! -f "$stage_root/boot/grub/grub.cfg" ]; then
  echo "fake mcopy: staging grub.cfg is missing under $stage_root" >&2
  exit 1
fi

echo "fake mcopy: $src -> $img ::/"
SH

cat >"$FAKEBIN/dd" <<'SH'
#!/bin/sh
set -eu
: "${FAKE_LOG:?FAKE_LOG is required}"
printf 'dd %s\n' "$*" >>"$FAKE_LOG/calls.log"

ifile=""
ofile=""
bs=""
seek=""
conv=""
for arg in "$@"; do
  case "$arg" in
    if=*) ifile=${arg#if=} ;;
    of=*) ofile=${arg#of=} ;;
    bs=*) bs=${arg#bs=} ;;
    seek=*) seek=${arg#seek=} ;;
    conv=*) conv=${arg#conv=} ;;
  esac
done

if [ "$bs" != "1M" ] || [ "$seek" != "1" ] || [ "$conv" != "notrunc" ]; then
  echo "fake dd: expected bs=1M seek=1 conv=notrunc, got: $*" >&2
  exit 1
fi
if [ -z "$ifile" ] || [ ! -f "$ifile" ]; then
  echo "fake dd: ESP input is missing: '${ifile}'" >&2
  exit 1
fi
if [ -z "$ofile" ] || [ ! -f "$ofile" ]; then
  echo "fake dd: disk output is missing: '${ofile}'" >&2
  exit 1
fi

echo "fake dd: $ifile -> $ofile at 1 MiB"
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
  local plan=$1
  local out=$2
  local log=$3
  shift 3

  PATH="$FAKEBIN:$PATH" bash "$BUILD_SH" --plan "$plan" --out "$out" "$@" \
    >"$log" 2>&1
}

# artifact.json checker used by both successful builds.
# Usage: validate_artifact <json> <out_dir> <expected_spec> <package_count> <mode>
# mode is "graphical" (DM plan) or "plain" (no-DM plan).
validate_artifact() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json
import os
import re
import sys

path, out, expected_spec, expected_packages, mode = (
    sys.argv[1],
    sys.argv[2],
    sys.argv[3],
    sys.argv[4],
    sys.argv[5],
)
MULTIUSER_CMDLINE = (
    "root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 "
    "systemd.unit=multi-user.target"
)
GRAPHICAL_CMDLINE = (
    "root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 "
    "systemd.unit=graphical.target systemd.journald.forward_to_console=1"
)

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
check(len(doc["packages"]) == int(expected_packages), "packages count (fixture plan)")
check(doc["rootfs"]["path"] == "rootfs", "rootfs.path")
check(doc["rootfs"]["size_mb"] >= 1, "rootfs.size_mb")
check(len(doc["images"]) == 2, "images count")
by_format = {image["format"]: image for image in doc["images"]}
check(set(by_format) == {"raw", "qcow2"}, "image formats")
for image in doc["images"]:
    check(re.fullmatch(r"[0-9a-f]{64}", image["sha256"]) is not None, "sha256 " + image["format"])
    check(os.path.isfile(os.path.join(out, image["path"])), "image exists " + image["path"])
check(by_format["raw"]["size_mb"] == 4096, "raw size is the 4096 MB P0-c floor")
check(by_format["qcow2"]["size_mb"] == 1, "qcow2 fake size")

boot = doc["boot"]
check(boot["mode"] == "uefi", "boot.mode uefi")
check(boot["disk"] == "disk.img", "boot.disk")
check(boot["kernel"] == "rootfs/boot/vmlinuz-6.12.3", "kernel 6.12.3")
check(boot["initrd"] == "rootfs/boot/initrd.img-6.12.3", "initrd 6.12.3")
if mode == "graphical":
    check(doc.get("desktop") == {"session": "plasma", "display_manager": "sddm"},
          "desktop session/display manager")
    check(boot["graphical"] is True, "boot.graphical is true")
    check(boot["memory_mb"] == 2048, "boot.memory_mb is 2048")
    check(boot["cmdline"] == GRAPHICAL_CMDLINE, "graphical cmdline")
elif mode == "plain":
    check("desktop" not in doc, "no desktop object")
    check(boot["graphical"] is False, "boot.graphical is false")
    check(boot["memory_mb"] == 1024, "boot.memory_mb is 1024")
    check(boot["cmdline"] == MULTIUSER_CMDLINE, "multi-user cmdline")
else:
    sys.exit("FAIL: unknown artifact mode " + mode)
check(boot["cmdline"].startswith("root=/dev/vda2"), "cmdline starts with root=/dev/vda2")
check(boot["grub"] == {"efi": "esp/EFI/BOOT/BOOTX64.EFI", "config": "grub.cfg"}, "boot.grub")
check(os.path.isfile(os.path.join(out, boot["grub"]["efi"])), "grub.efi exists")
check(os.path.isfile(os.path.join(out, boot["grub"]["config"])), "grub.config exists")

check(
    doc["partitions"] == [
        {"index": 1, "role": "esp", "size_mb": 512, "fs": "vfat32"},
        {"index": 2, "role": "root", "size_mb": 3584, "fs": "ext4"},
    ],
    "partitions",
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
export FAKE_GRUB_FAIL=0

OUT1="$TMP_DIR/out-main"
LOG1="$TMP_DIR/run-main.log"
FAKE_LOG="$TMP_DIR/fake-main"
export FAKE_LOG
mkdir -p "$FAKE_LOG"

if run_build "$PLAN" "$OUT1" "$LOG1" --execute; then
  pass "--execute exits 0 with the fake UEFI toolchain"
else
  cat "$LOG1" >&2
  fail "--execute did not exit 0"
fi

if [ -f "$OUT1/artifact.json" ]; then
  pass "artifact.json exists"
  if validate_artifact "$OUT1/artifact.json" "$OUT1" "debian-kde-dev" 43 graphical; then
    pass "artifact.json UEFI + graphical desktop fields, partitions, sizes, shas, and boot entries are valid"
  else
    fail "artifact.json validation failed"
  fi
else
  fail "artifact.json was not written"
fi

assert_eq "debian-kde-dev" "$(cat "$OUT1/rootfs/etc/hostname" 2>/dev/null || true)" \
  "customize hook writes plan.spec to /etc/hostname"

RAW_BYTES=$(wc -c <"$OUT1/disk.img" 2>/dev/null | tr -d ' ' || true)
assert_eq "4294967296" "$RAW_BYTES" "truncate created a 4096 MiB raw image"

assert_file "$OUT1/esp/EFI/BOOT/BOOTX64.EFI" "ESP staging keeps BOOTX64.EFI"
assert_file "$OUT1/esp/boot/grub/grub.cfg" "ESP staging keeps boot/grub/grub.cfg"
assert_absent "$OUT1/esp.img" "successful build removes the intermediate esp.img"

# P0-d1 boot evidence unit: installed only for the graphical build, with the
# real display-manager process name and an enable link for graphical.target.
EVIDENCE_UNIT="$OUT1/rootfs/etc/systemd/system/sysemble-boot-evidence.service"
EVIDENCE_LINK="$OUT1/rootfs/etc/systemd/system/graphical.target.wants/sysemble-boot-evidence.service"
assert_file "$EVIDENCE_UNIT" "graphical build installs the boot evidence unit"
assert_contains "SYMBLE: Xorg ready" "$EVIDENCE_UNIT" \
  "evidence unit contains the Xorg marker"
assert_contains "SYMBLE: sddm ready" "$EVIDENCE_UNIT" \
  "evidence unit contains the actual sddm marker"
assert_contains "pgrep -x Xorg" "$EVIDENCE_UNIT" \
  "evidence unit probes the Xorg process"
assert_contains "WantedBy=graphical.target" "$EVIDENCE_UNIT" \
  "evidence unit is wanted by graphical.target"
if [ -L "$EVIDENCE_LINK" ] &&
  [ "$(readlink "$EVIDENCE_LINK" 2>/dev/null || true)" = "../sysemble-boot-evidence.service" ]; then
  pass "evidence unit is enabled via graphical.target.wants symlink"
else
  fail "evidence unit graphical.target.wants symlink is missing or wrong"
fi

CALLS="$FAKE_LOG/calls.log"
if [ -f "$CALLS" ]; then
  pass "fake tools recorded calls"
else
  fail "fake tools did not record calls"
fi

M_LINE=$(grep -n '^mmdebstrap ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
Z_LINE=$(grep -n '^sgdisk -Z ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
N_LINE=$(grep -n '^sgdisk -n ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
K_LINE=$(grep -n '^mkfs.ext4 ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
V_LINE=$(grep -n '^mkfs.vfat ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
G_LINE=$(grep -n '^grub-mkstandalone ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
C_LINE=$(grep -n '^mcopy ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
D_LINE=$(grep -n '^dd ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
Q_LINE=$(grep -n '^qemu-img ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)
CH_LINE=$(grep -n '^chroot ' "$CALLS" 2>/dev/null | head -1 | cut -d: -f1 || true)

if [ -n "$M_LINE" ] && [ -n "$Z_LINE" ] && [ -n "$N_LINE" ] &&
  [ -n "$K_LINE" ] && [ -n "$V_LINE" ] && [ -n "$G_LINE" ] &&
  [ -n "$C_LINE" ] && [ -n "$D_LINE" ] && [ -n "$Q_LINE" ] &&
  [ "$M_LINE" -lt "$Z_LINE" ] && [ "$Z_LINE" -lt "$N_LINE" ] &&
  [ "$N_LINE" -lt "$K_LINE" ] && [ "$K_LINE" -lt "$V_LINE" ] &&
  [ "$V_LINE" -lt "$G_LINE" ] && [ "$G_LINE" -lt "$C_LINE" ] &&
  [ "$C_LINE" -lt "$D_LINE" ] && [ "$D_LINE" -lt "$Q_LINE" ]; then
  pass "call order is rootfs -> sgdisk -> mkfs.ext4 -> mkfs.vfat -> grub -> mcopy -> dd -> qemu-img ($M_LINE<$Z_LINE<$N_LINE<$K_LINE<$V_LINE<$G_LINE<$C_LINE<$D_LINE<$Q_LINE)"
else
  fail "call order is wrong (mmdebstrap=$M_LINE sgdisk-Z=$Z_LINE sgdisk-n=$N_LINE mkfs.ext4=$K_LINE mkfs.vfat=$V_LINE grub=$G_LINE mcopy=$C_LINE dd=$D_LINE qemu-img=$Q_LINE)"
fi

if [ -n "$CH_LINE" ] && [ -n "$M_LINE" ] && [ "$CH_LINE" -gt "$M_LINE" ]; then
  pass "customize hook ran chroot after mmdebstrap started"
else
  fail "customize hook/chroot was not invoked (chroot line: ${CH_LINE:-missing})"
fi

OUT1_ABS=$(cd "$OUT1" && pwd -P)
assert_contains "serial-getty@ttyS0.service" "$CALLS" "hook enables serial-getty@ttyS0.service"
assert_contains "include=apt,ca-certificates" "$CALLS" "mmdebstrap received the plan package list"
assert_contains "xserver-xorg,procps" "$CALLS" \
  "graphical mmdebstrap adds xserver-xorg and procps for Xorg/pgrep"
assert_contains "sgdisk -Z $OUT1_ABS/disk.img" "$CALLS" "sgdisk -Z wiped disk.img"
assert_contains "sgdisk -n 1:2048:+512M -t 1:ef00 -n 2:0:0 -t 2:8300 $OUT1_ABS/disk.img" "$CALLS" \
  "sgdisk created the frozen GPT ESP+root layout"
assert_contains "mkfs.ext4 -F -b 4096 -E offset=537919488 -d $OUT1_ABS/rootfs -L SYMBLE $OUT1_ABS/disk.img 916992" "$CALLS" \
  "mkfs.ext4 used -F -b 4096, the 513 MiB offset, -d rootfs, -L SYMBLE, and an explicit size"
assert_contains "mkfs.vfat -F 32 -C -n ESP $OUT1_ABS/esp.img 524288" "$CALLS" \
  "mkfs.vfat created a 512 MiB FAT32 ESP image"
assert_contains "grub-mkstandalone -O x86_64-efi -o $OUT1_ABS/esp/EFI/BOOT/BOOTX64.EFI" "$CALLS" \
  "grub-mkstandalone targets BOOTX64.EFI"
assert_contains "--modules=part_gpt part_msdos fat ext2 normal linux search search_fs_uuid configfile serial terminal echo test" "$CALLS" \
  "grub-mkstandalone received the frozen module list"
assert_contains "boot/grub/grub.cfg=$OUT1_ABS/esp/boot/grub/grub.cfg" "$CALLS" \
  "grub-mkstandalone embeds the staged grub.cfg"
assert_contains "mcopy -i $OUT1_ABS/esp.img -s $OUT1_ABS/esp/EFI ::/" "$CALLS" \
  "mcopy copied the ESP staging tree"
assert_contains "dd if=$OUT1_ABS/esp.img of=$OUT1_ABS/disk.img bs=1M seek=1 conv=notrunc" "$CALLS" \
  "dd merged the ESP at seek=1 MiB with conv=notrunc"
assert_contains "convert -O qcow2 $OUT1_ABS/disk.img $OUT1_ABS/disk.qcow2" "$CALLS" \
  "qemu-img converted raw to qcow2"

assert_contains "set timeout=3" "$OUT1/grub.cfg" "grub.cfg sets a timeout"
assert_contains "serial --unit=0 --speed=115200" "$OUT1/grub.cfg" "grub.cfg configures serial"
assert_contains "terminal_input serial" "$OUT1/grub.cfg" "grub.cfg uses serial input"
assert_contains "terminal_output serial" "$OUT1/grub.cfg" "grub.cfg uses serial output"
assert_contains "menuentry \"Sysemble\"" "$OUT1/grub.cfg" "grub.cfg has the menu entry"
assert_contains "set root=(hd0,gpt2)" "$OUT1/grub.cfg" "grub.cfg selects (hd0,gpt2)"
assert_contains "linux /boot/vmlinuz-6.12.3 root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=graphical.target systemd.journald.forward_to_console=1" \
  "$OUT1/grub.cfg" "grub.cfg linux line targets graphical.target and forwards journald"
assert_contains "initrd /boot/initrd.img-6.12.3" "$OUT1/grub.cfg" \
  "grub.cfg initrd line uses the actual initrd version"
assert_contains "console=ttyS0" "$OUT1/grub.cfg" "grub.cfg cmdline includes console=ttyS0"
assert_eq "$(artifact_boot_cmdline "$OUT1/artifact.json")" "$(grub_kernel_cmdline "$OUT1/grub.cfg")" \
  "artifact boot.cmdline matches the grub.cfg kernel line byte for byte"
if cmp -s "$OUT1/grub.cfg" "$OUT1/esp/boot/grub/grub.cfg"; then
  pass "staged grub.cfg is byte-identical to <out>/grub.cfg"
else
  fail "staged grub.cfg differs from <out>/grub.cfg"
fi

assert_contains "fake mmdebstrap: rootfs at" "$OUT1/build.log" "build.log tees mmdebstrap output"
assert_contains "fake sgdisk:" "$OUT1/build.log" "build.log tees sgdisk output"
assert_contains "fake mkfs.ext4: offset 513 MiB, 916992 blocks" "$OUT1/build.log" "build.log tees mkfs.ext4 output"
assert_contains "fake mkfs.vfat:" "$OUT1/build.log" "build.log tees mkfs.vfat output"
assert_contains "fake grub-mkstandalone: wrote" "$OUT1/build.log" "build.log tees grub-mkstandalone output"
assert_contains "fake mcopy:" "$OUT1/build.log" "build.log tees mcopy output"
assert_contains "fake dd:" "$OUT1/build.log" "build.log tees dd output"
assert_contains "fake qemu-img:" "$OUT1/build.log" "build.log tees qemu-img output"
assert_contains "stage 5/6: assemble GPT disk image" "$OUT1/build.log" "build.log records the GPT stage"
assert_contains "stage 6/6: write artifact manifest" "$OUT1/build.log" "build.log records the artifact stage"
assert_contains "desktop: session=plasma, display_manager=sddm (graphical boot, 2048 MB)" \
  "$OUT1/build.log" "build.log records the inferred graphical desktop"
assert_contains "boot evidence: install /etc/systemd/system/sysemble-boot-evidence.service" \
  "$OUT1/build.log" "build.log records the installed boot evidence unit"

# ---------------------------------------------------------------------------
# Case 1b: no-DM plan keeps the frozen P0-c multi-user behavior end to end
# ---------------------------------------------------------------------------

OUT_NODM="$TMP_DIR/out-no-desktop"
LOG_NODM="$TMP_DIR/run-no-desktop.log"
FAKE_LOG="$TMP_DIR/fake-no-desktop"
export FAKE_LOG
mkdir -p "$FAKE_LOG"

if run_build "$PLAN_NODM" "$OUT_NODM" "$LOG_NODM" --execute; then
  pass "no-DM --execute exits 0 with the fake UEFI toolchain"
else
  cat "$LOG_NODM" >&2
  fail "no-DM --execute did not exit 0"
fi

if [ -f "$OUT_NODM/artifact.json" ]; then
  pass "no-DM artifact.json exists"
  if validate_artifact "$OUT_NODM/artifact.json" "$OUT_NODM" "debian-minimal" 14 plain; then
    pass "no-DM artifact keeps graphical=false, memory_mb=1024, no desktop, and the multi-user cmdline"
  else
    fail "no-DM artifact.json validation failed"
  fi
else
  fail "no-DM artifact.json was not written"
fi

assert_eq "debian-minimal" "$(cat "$OUT_NODM/rootfs/etc/hostname" 2>/dev/null || true)" \
  "no-DM customize hook writes plan.spec to /etc/hostname"
assert_contains "linux /boot/vmlinuz-6.12.3 root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=multi-user.target" \
  "$OUT_NODM/grub.cfg" "no-DM grub.cfg keeps the frozen multi-user cmdline"
if grep -Fq -- "graphical.target" "$OUT_NODM/grub.cfg"; then
  fail "no-DM grub.cfg unexpectedly targets graphical.target"
else
  pass "no-DM grub.cfg does not target graphical.target"
fi
if grep -Fq -- "journald.forward_to_console" "$OUT_NODM/grub.cfg"; then
  fail "no-DM grub.cfg unexpectedly adds journald forwarding"
else
  pass "no-DM grub.cfg does not add journald forwarding"
fi
assert_eq "$(artifact_boot_cmdline "$OUT_NODM/artifact.json")" "$(grub_kernel_cmdline "$OUT_NODM/grub.cfg")" \
  "no-DM artifact boot.cmdline matches the grub.cfg kernel line byte for byte"
assert_contains "desktop: none detected (multi-user boot, 1024 MB)" \
  "$OUT_NODM/build.log" "build.log records the absence of a desktop"
assert_file "$OUT_NODM/esp/EFI/BOOT/BOOTX64.EFI" "no-DM build still stages BOOTX64.EFI"
assert_absent "$OUT_NODM/esp.img" "no-DM build still removes the intermediate esp.img"
assert_absent "$OUT_NODM/rootfs/etc/systemd/system/sysemble-boot-evidence.service" \
  "no-DM build does not install the boot evidence unit"
assert_absent "$OUT_NODM/rootfs/etc/systemd/system/graphical.target.wants/sysemble-boot-evidence.service" \
  "no-DM build does not enable the boot evidence unit"
NODM_CALLS="$TMP_DIR/calls-no-desktop.log"
cp "$FAKE_LOG/calls.log" "$NODM_CALLS"
assert_not_contains "xserver-xorg" "$NODM_CALLS" \
  "no-DM mmdebstrap does not add the graphical Xorg runtime package"
assert_not_contains "procps" "$NODM_CALLS" \
  "no-DM mmdebstrap does not add the graphical procps runtime package"
assert_not_contains "boot evidence:" "$OUT_NODM/build.log" \
  "no-DM build.log does not record a boot evidence unit"

# ---------------------------------------------------------------------------
# Case 2: serial getty enable failure is non-fatal and lands in build.log
# ---------------------------------------------------------------------------

OUT2="$TMP_DIR/out-warn"
LOG2="$TMP_DIR/run-warn.log"
FAKE_LOG="$TMP_DIR/fake-warn"
export FAKE_LOG
mkdir -p "$FAKE_LOG"

export FAKE_CHROOT_RC=1

if run_build "$PLAN" "$OUT2" "$LOG2"; then
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
# Case 3: qemu-img failure removes the partial qcow2 but keeps rootfs/,
# disk.img, and build.log (P0-c diagnosis rule)
# ---------------------------------------------------------------------------

OUT3="$TMP_DIR/out-fail"
LOG3="$TMP_DIR/run-fail.log"
FAKE_LOG="$TMP_DIR/fake-fail"
export FAKE_LOG
mkdir -p "$FAKE_LOG"

export FAKE_QEMU_FAIL=1
RC3=0
if run_build "$PLAN" "$OUT3" "$LOG3" --execute; then
  RC3=0
else
  RC3=$?
fi
export FAKE_QEMU_FAIL=0
assert_eq "6" "$RC3" "qemu-img failure exits 6"
assert_absent "$OUT3/disk.qcow2" "failed build removes the partial disk.qcow2"
assert_absent "$OUT3/esp.img" "failed build removes the intermediate esp.img"
assert_file "$OUT3/disk.img" "failed build keeps disk.img for diagnosis"
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
# Case 4: grub-mkstandalone failure exits 6 and keeps disk.img + build.log
# ---------------------------------------------------------------------------

OUT4="$TMP_DIR/out-grub-fail"
LOG4="$TMP_DIR/run-grub-fail.log"
FAKE_LOG="$TMP_DIR/fake-grub-fail"
export FAKE_LOG
mkdir -p "$FAKE_LOG"

export FAKE_GRUB_FAIL=1
RC4=0
if run_build "$PLAN" "$OUT4" "$LOG4" --execute; then
  RC4=0
else
  RC4=$?
fi
export FAKE_GRUB_FAIL=0
assert_eq "6" "$RC4" "grub-mkstandalone failure exits 6"
assert_contains "grub-mkstandalone failed" "$OUT4/build.log" "failed build logs the GRUB error"
assert_absent "$OUT4/esp.img" "failed GRUB build removes the intermediate esp.img"
assert_absent "$OUT4/disk.qcow2" "failed GRUB build leaves no qcow2"
assert_file "$OUT4/disk.img" "failed GRUB build keeps disk.img for diagnosis"
assert_file "$OUT4/grub.cfg" "failed GRUB build keeps grub.cfg"
if [ -d "$OUT4/rootfs" ]; then
  pass "failed GRUB build keeps rootfs/"
else
  fail "failed GRUB build removed rootfs/"
fi

# ---------------------------------------------------------------------------
# Case 5: an oversize ESP image is refused before dd can overwrite ext4/p2
# ---------------------------------------------------------------------------

OUT_ESP="$TMP_DIR/out-esp-bad"
LOG_ESP="$TMP_DIR/run-esp-bad.log"
FAKE_LOG="$TMP_DIR/fake-esp-bad"
export FAKE_LOG
mkdir -p "$FAKE_LOG"

export FAKE_VFAT_BAD_SIZE=1
RC_ESP=0
if run_build "$PLAN" "$OUT_ESP" "$LOG_ESP" --execute; then
  RC_ESP=0
else
  RC_ESP=$?
fi
export FAKE_VFAT_BAD_SIZE=0
assert_eq "6" "$RC_ESP" "oversize esp.img exits 6"
assert_contains "refusing to dd over partition 2" "$OUT_ESP/build.log" \
  "oversize esp.img error explains the p2 overwrite risk"
assert_absent "$OUT_ESP/esp.img" "oversize ESP failure removes esp.img"
assert_absent "$OUT_ESP/disk.qcow2" "oversize ESP failure leaves no qcow2"
assert_file "$OUT_ESP/disk.img" "oversize ESP failure keeps disk.img"
if [ -f "$OUT_ESP/build.log" ] && ! grep -Fq '^dd ' "$FAKE_LOG/calls.log"; then
  pass "dd was never called for the oversize ESP"
else
  fail "dd ran despite the oversize ESP guard"
fi

# ---------------------------------------------------------------------------
# Case 6: an existing <out>/rootfs is refused with exit 6
# ---------------------------------------------------------------------------

OUT5="$TMP_DIR/out-existing"
LOG5="$TMP_DIR/run-existing.log"
mkdir -p "$OUT5/rootfs"
FAKE_LOG="$TMP_DIR/fake-existing"
export FAKE_LOG
mkdir -p "$FAKE_LOG"

RC5=0
if run_build "$PLAN" "$OUT5" "$LOG5" --execute; then
  RC5=0
else
  RC5=$?
fi
assert_eq "6" "$RC5" "existing <out>/rootfs exits 6"
assert_contains "refusing to overwrite existing path" "$OUT5/build.log" \
  "existing rootfs refusal is recorded in build.log"

# ---------------------------------------------------------------------------
# Case 7: --dry-run and --execute are mutually exclusive
# ---------------------------------------------------------------------------

RC6=0
if bash "$BUILD_SH" --plan "$PLAN" --out "$TMP_DIR/out-both" --dry-run --execute \
  >"$TMP_DIR/run-both.log" 2>&1; then
  RC6=0
else
  RC6=$?
fi
assert_eq "2" "$RC6" "--dry-run + --execute exits 2"

# ---------------------------------------------------------------------------
# Case 8: docker + --execute is rejected instead of pretending to assemble
# ---------------------------------------------------------------------------

RC7=0
if bash "$BUILD_SH" --plan "$PLAN" --out "$TMP_DIR/out-docker-exec" \
  --engine docker --execute >"$TMP_DIR/run-docker-exec.log" 2>&1; then
  RC7=0
else
  RC7=$?
fi
assert_eq "2" "$RC7" "--engine docker + --execute exits 2"
assert_contains "native-only" "$TMP_DIR/run-docker-exec.log" \
  "docker + --execute explains that assembly is native-only"
assert_absent "$TMP_DIR/out-docker-exec" "docker + --execute creates no output directory"

# ---------------------------------------------------------------------------
# Case 9: native_preflight reports every missing P0-c tool
# ---------------------------------------------------------------------------

EMPTY_PATH="$TMP_DIR/empty-path"
mkdir -p "$EMPTY_PATH"
PREFLIGHT_LOG="$TMP_DIR/preflight-missing.log"
RC8=0
(
  PATH="$EMPTY_PATH"
  native_preflight
) >"$PREFLIGHT_LOG" 2>&1 || RC8=$?
assert_eq "1" "$RC8" "native_preflight fails when tools are missing"
assert_contains "requires Linux" "$PREFLIGHT_LOG" "preflight reports a non-Linux host"
assert_contains "requires root" "$PREFLIGHT_LOG" "preflight reports a non-root euid"
for tool in mmdebstrap mkfs.ext4 qemu-img sgdisk mkfs.vfat mcopy grub-mkstandalone dd; do
  assert_contains "'$tool' on PATH" "$PREFLIGHT_LOG" "preflight reports missing '$tool'"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf '\nbuild_exec_test.sh: %d failure(s), %d passed check(s)\n' "$FAILURES" "$PASS" >&2
  exit 1
fi
printf '\nbuild_exec_test.sh: all %d checks passed\n' "$PASS"
