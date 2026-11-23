#!/usr/bin/env bash
# P0-c/P0-d1/P0-d2 artifact manifest tests.
#
# Runs entirely offline: no Linux, root, mmdebstrap, mkfs.ext4, mkfs.vfat,
# sgdisk, mcopy, grub-mkstandalone, mksquashfs, xorriso, qemu-img or qemu is
# required. It builds fixture rootfs/images, sources lib.sh (which defines
# functions only), and calls the pure artifact_json()/artifact_iso_json()/
# plan_build_mode()/compute_disk_size_mb()/grub_cfg_text()/
# iso_grub_cfg_text()/desktop-detection helpers. The result is validated with
# python3 (jq fallback).
#
# Covered:
#   - P0-c UEFI artifact: boot.mode/disk/grub, two partitions, vda2 cmdline
#   - P0-d1 no-DM artifact: graphical=false, memory_mb=1024, no desktop object
#   - P0-d1 DM artifact: desktop/lightdm + xfce, graphical=true, memory_mb=2048,
#     graphical.target + journald-forwarding cmdline
#   - DM/session detection priority and the unknown-session fallback
#   - graphical boot evidence unit text (Xorg + real DM process marker)
#   - P0-d2 iso-only artifact: mode/iso/cmdline/images, no partitions
#   - P0-d2 desktop ISO artifact: desktop/graphical/2048, no partitions
#   - P0-d2 iso+disk artifact: ISO boot mode, all three images, partitions
#   - P0-d2 runtime package deduplication against plan.packages
#   - P0-d2 plan output mode selection (iso / iso-disk / disk)
#   - P0-d2 live GRUB config (search/live-media-path/boot=live, actual versions)
#   - P0-b kernel fallback when the GRUB outputs are absent (mode defaults)
#   - images raw+qcow2 with sha256/size, kernel/initrd selection
#   - missing kernel/initrd still fail (build.sh maps that to exit 6)
#   - P0-c disk sizing formula and GRUB config rendering (both cmdlines)
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

assert_contains() {
  local pattern=$1
  local file=$2
  local label=$3

  if grep -Fq -- "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label (pattern '$pattern' not found in $file)"
  fi
}

assert_not_contains() {
  local pattern=$1
  local file=$2
  local label=$3

  if grep -Fq -- "$pattern" "$file"; then
    fail "$label (unexpected pattern '$pattern' found in $file)"
  else
    pass "$label"
  fi
}

assert_fails() {
  local label=$1
  shift

  if "$@" >/dev/null 2>&1; then
    fail "$label (command unexpectedly succeeded)"
  else
    pass "$label"
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

json_boot_cmdline() {
  if [ "$json_backend" = "python3" ]; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["boot"]["cmdline"])' "$1"
  else
    jq -r '.boot.cmdline' "$1"
  fi
}

grub_kernel_cmdline() {
  sed -n 's/^  linux \/boot\/[^ ]* //p' "$1" | head -n 1
}

# ---------------------------------------------------------------------------
# Fixture: a rootfs with two kernel/initrd versions, a 4096 MiB disk image
# (the P0-c minimum), a fake qcow2, and the P0-c ESP/GRUB outputs.
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
truncate -s 4096M "$OUT/disk.img"

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

KERNEL_NAME="vmlinuz-6.12.3"
INITRD_NAME="initrd.img-6.12.3"

# The real build writes <out>/grub.cfg and stages a copy under esp/. The
# artifact helper only requires both paths to exist and the config to be
# non-empty.
mkdir -p "$OUT/esp/EFI/BOOT" "$OUT/esp/boot/grub"
grub_cfg_text "$KERNEL_NAME" "$INITRD_NAME" >"$OUT/grub.cfg"
cp "$OUT/grub.cfg" "$OUT/esp/boot/grub/grub.cfg"
printf 'fake BOOTX64.EFI\n' >"$OUT/esp/EFI/BOOT/BOOTX64.EFI"

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
# GRUB config rendering (input to grub-mkstandalone)
# ---------------------------------------------------------------------------

assert_contains "set timeout=3" "$OUT/grub.cfg" "grub.cfg sets a boot timeout"
assert_contains "serial --unit=0 --speed=115200" "$OUT/grub.cfg" "grub.cfg configures serial console"
assert_contains "terminal_input serial" "$OUT/grub.cfg" "grub.cfg uses serial input"
assert_contains "terminal_output serial" "$OUT/grub.cfg" "grub.cfg uses serial output"
assert_contains "menuentry \"Sysemble\"" "$OUT/grub.cfg" "grub.cfg has the Sysemble menu entry"
assert_contains "set root=(hd0,gpt2)" "$OUT/grub.cfg" "grub.cfg selects (hd0,gpt2)"
assert_contains "linux /boot/$KERNEL_NAME root=/dev/vda2 rw console=ttyS0" "$OUT/grub.cfg" \
  "grub.cfg linux line has the real kernel and vda2 cmdline"
assert_contains "initrd /boot/$INITRD_NAME" "$OUT/grub.cfg" \
  "grub.cfg initrd line has the real initrd"
assert_contains "rootfstype=ext4 systemd.unit=multi-user.target" "$OUT/grub.cfg" \
  "grub.cfg cmdline is the frozen P0-c cmdline"
assert_not_contains "graphical.target" "$OUT/grub.cfg" \
  "no-DM grub.cfg does not target graphical.target"

# P0-d1: the third argument selects the desktop kernel cmdline. The journald
# forwarding flag is required so LightDM/Xorg messages reach the serial console.
GRAPHICAL_GRUB="$TMP_DIR/grub-graphical.cfg"
if grub_cfg_text "$KERNEL_NAME" "$INITRD_NAME" 1 >"$GRAPHICAL_GRUB"; then
  pass "grub_cfg_text renders the graphical cmdline"
else
  fail "grub_cfg_text failed for the graphical cmdline"
fi
assert_contains "linux /boot/$KERNEL_NAME root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=graphical.target systemd.journald.forward_to_console=1" \
  "$GRAPHICAL_GRUB" "graphical grub.cfg kernel line targets graphical.target and forwards journald"
assert_not_contains "systemd.unit=multi-user.target" "$GRAPHICAL_GRUB" \
  "graphical grub.cfg does not keep multi-user.target"
assert_fails "grub_cfg_text rejects an invalid graphical flag" \
  grub_cfg_text "$KERNEL_NAME" "$INITRD_NAME" 2

if grub_cfg_text "" "$INITRD_NAME" >/dev/null 2>&1; then
  fail "grub_cfg_text must reject an empty kernel name"
else
  pass "grub_cfg_text rejects an empty kernel name"
fi
if grub_cfg_text "/boot/$KERNEL_NAME" "$INITRD_NAME" >/dev/null 2>&1; then
  fail "grub_cfg_text must reject a kernel path with a slash"
else
  pass "grub_cfg_text rejects a kernel path instead of a basename"
fi

# ---------------------------------------------------------------------------
# P0-d2 live ISO GRUB config rendering
# ---------------------------------------------------------------------------

ISO_GRUB="$TMP_DIR/grub-iso.cfg"
ISO_GRAPHICAL_GRUB="$TMP_DIR/grub-iso-graphical.cfg"
if iso_grub_cfg_text "$KERNEL_NAME" "$INITRD_NAME" >"$ISO_GRUB"; then
  pass "iso_grub_cfg_text renders the live ISO menu"
else
  fail "iso_grub_cfg_text failed"
fi
iso_grub_cfg_text "$KERNEL_NAME" "$INITRD_NAME" 1 >"$ISO_GRAPHICAL_GRUB"

assert_contains "menuentry \"Sysemble Live\"" "$ISO_GRUB" "ISO grub.cfg uses the Sysemble Live menu entry"
assert_contains "search --no-floppy --file --set=root /live/vmlinuz" "$ISO_GRUB" \
  "ISO grub.cfg searches for /live/vmlinuz"
assert_contains "linux /live/vmlinuz boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1" \
  "$ISO_GRUB" "ISO grub.cfg linux line is the frozen multi-user live cmdline"
assert_contains "initrd /live/initrd.img" "$ISO_GRUB" "ISO grub.cfg loads /live/initrd.img"
assert_contains "source kernel=$KERNEL_NAME initrd=$INITRD_NAME" "$ISO_GRUB" \
  "ISO grub.cfg records the actual kernel/initrd versions"
assert_not_contains "set root=(hd0,gpt2)" "$ISO_GRUB" "ISO grub.cfg has no disk root"
assert_not_contains "root=/dev/vda2" "$ISO_GRUB" "ISO grub.cfg has no disk root= cmdline"
assert_not_contains "graphical.target" "$ISO_GRUB" "no-DM ISO grub.cfg keeps multi-user.target"
assert_not_contains "sysemble.install" "$ISO_GRUB" \
  "plain ISO grub.cfg has no installer parameter"
assert_contains "linux /live/vmlinuz boot=live live-media-path=/live console=ttyS0 systemd.unit=graphical.target systemd.journald.forward_to_console=1" \
  "$ISO_GRAPHICAL_GRUB" "graphical ISO grub.cfg targets graphical.target"
assert_not_contains "systemd.unit=multi-user.target" "$ISO_GRAPHICAL_GRUB" \
  "graphical ISO grub.cfg does not keep multi-user.target"
assert_fails "iso_grub_cfg_text rejects an invalid graphical flag" \
  iso_grub_cfg_text "$KERNEL_NAME" "$INITRD_NAME" 2

# P0-d3: installer ISO cmdline appends sysemble.install=/dev/vda.
ISO_INSTALL_GRUB="$TMP_DIR/grub-iso-installer.cfg"
if iso_grub_cfg_text "$KERNEL_NAME" "$INITRD_NAME" 0 1 >"$ISO_INSTALL_GRUB"; then
  pass "iso_grub_cfg_text renders the installer ISO menu"
else
  fail "iso_grub_cfg_text failed for the installer flag"
fi
assert_contains "linux /live/vmlinuz boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1 sysemble.install=/dev/vda" \
  "$ISO_INSTALL_GRUB" "installer ISO grub.cfg appends sysemble.install=/dev/vda"
assert_contains "search --no-floppy --file --set=root /live/vmlinuz" "$ISO_INSTALL_GRUB" \
  "installer ISO grub.cfg still searches for /live/vmlinuz"
assert_fails "iso_grub_cfg_text rejects an invalid installer flag" \
  iso_grub_cfg_text "$KERNEL_NAME" "$INITRD_NAME" 0 2

# P0-e1: the TUI installer ISO uses sysemble.install.tui=1 and no disk.
ISO_TUI_GRUB="$TMP_DIR/grub-iso-installer-tui.cfg"
if iso_grub_cfg_text "$KERNEL_NAME" "$INITRD_NAME" 0 1 1 >"$ISO_TUI_GRUB"; then
  pass "iso_grub_cfg_text renders the TUI installer ISO menu"
else
  fail "iso_grub_cfg_text failed for the TUI installer flag"
fi
assert_contains "linux /live/vmlinuz boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1 sysemble.install.tui=1" \
  "$ISO_TUI_GRUB" "TUI installer ISO grub.cfg appends sysemble.install.tui=1"
assert_not_contains "sysemble.install=/dev/vda" "$ISO_TUI_GRUB" \
  "TUI installer ISO grub.cfg has no install_device parameter"
assert_not_contains "install_device" "$ISO_TUI_GRUB" \
  "TUI installer ISO grub.cfg carries no install_device text"
assert_contains "search --no-floppy --file --set=root /live/vmlinuz" "$ISO_TUI_GRUB" \
  "TUI installer ISO grub.cfg still searches /live/vmlinuz"
assert_fails "iso_grub_cfg_text rejects an invalid TUI installer flag" \
  iso_grub_cfg_text "$KERNEL_NAME" "$INITRD_NAME" 0 1 2
assert_fails "iso_grub_cfg_text rejects a TUI flag without the installer flag" \
  iso_grub_cfg_text "$KERNEL_NAME" "$INITRD_NAME" 0 0 1
if iso_grub_cfg_text "" "$INITRD_NAME" >/dev/null 2>&1; then
  fail "iso_grub_cfg_text must reject an empty kernel name"
else
  pass "iso_grub_cfg_text rejects an empty kernel name"
fi
if iso_grub_cfg_text "$KERNEL_NAME" "/boot/$INITRD_NAME" >/dev/null 2>&1; then
  fail "iso_grub_cfg_text must reject an initrd path with a slash"
else
  pass "iso_grub_cfg_text rejects an initrd path instead of a basename"
fi

# ---------------------------------------------------------------------------
# P0-d2 live ISO artifact (iso-only, graphical, and iso+disk)
# ---------------------------------------------------------------------------

ISO_OUT="$TMP_DIR/iso-out"
ISO_ROOTFS="$ISO_OUT/rootfs"
mkdir -p "$ISO_ROOTFS/boot"
printf 'iso kernel\n' >"$ISO_ROOTFS/boot/$KERNEL_NAME"
printf 'iso initrd\n' >"$ISO_ROOTFS/boot/$INITRD_NAME"
printf 'fake live iso\n' >"$ISO_OUT/live.iso"
# 1 MiB is enough: artifact_iso_json hashes the file but does not inspect it.
truncate -s 1048576 "$ISO_OUT/live.iso"

ISO_JSON="$TMP_DIR/artifact-iso.json"
if artifact_iso_json "$ISO_OUT" "minimal-debian-live" "trixie" "2026-11-01" \
  "x86_64" "$CREATED_AT" 0 "${PACKAGES[@]}" >"$ISO_JSON"; then
  pass "artifact_iso_json exits 0 for an iso-only build"
else
  fail "artifact_iso_json failed for an iso-only build"
fi

if [ "$json_backend" = "python3" ]; then
  if python3 - "$ISO_JSON" "$ISO_OUT" "$CREATED_AT" <<'PY'
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

ISO_CMDLINE = (
    "boot=live live-media-path=/live console=ttyS0 "
    "systemd.unit=multi-user.target systemd.journald.forward_to_console=1"
)
check(
    set(doc) == {
        "apiVersion", "createdAt", "spec", "base", "arch", "packages",
        "rootfs", "images", "boot", "builder",
    },
    "iso-only top-level keys omit partitions and desktop",
)
check(doc["apiVersion"] == "sysemble/artifact/v1", "apiVersion")
check(doc["createdAt"] == created_at, "createdAt")
check(doc["spec"] == "minimal-debian-live", "spec")
check(doc["base"] == {"kind": "debian", "release": "trixie", "pin": "2026-11-01"}, "base")
check(doc["arch"] == "x86_64", "arch")
check(doc["packages"] == ["apt", "ca-certificates", "systemd"], "artifact.packages keeps the plan list")
check(doc["rootfs"]["path"] == "rootfs", "rootfs.path")
check(doc["rootfs"]["size_mb"] >= 1, "rootfs.size_mb")
check(len(doc["images"]) == 1, "iso-only images has one entry")
image = doc["images"][0]
check(image["path"] == "live.iso", "image path is live.iso")
check(image["format"] == "iso", "image format is iso")
check(re.fullmatch(r"[0-9a-f]{64}", image["sha256"]) is not None, "iso sha256")
check(image["size_mb"] == 1, "iso size_mb is the 1 MiB fixture")
check(os.path.isfile(os.path.join(out, "live.iso")), "live.iso exists under <out>")
check(
    set(doc["boot"]) == {"mode", "iso", "cmdline", "memory_mb"},
    "iso-only boot keys are mode/iso/cmdline/memory_mb",
)
check(doc["boot"]["mode"] == "iso", "boot.mode is iso")
check(doc["boot"]["iso"] == "live.iso", "boot.iso is live.iso")
check(doc["boot"]["cmdline"] == ISO_CMDLINE, "boot.cmdline is the frozen ISO multi-user cmdline")
check("sysemble.install" not in doc["boot"]["cmdline"], "plain ISO cmdline has no installer parameter")
check("install_device" not in doc["boot"], "plain ISO artifact has no install_device")
check(doc["boot"]["memory_mb"] == 1024, "boot.memory_mb is 1024")
check("partitions" not in doc, "iso-only artifact omits partitions")
check("desktop" not in doc, "iso-only artifact omits desktop")
check(doc["builder"] == {"name": "build.sh", "version": "0.1.0"}, "builder")
PY
  then
    pass "iso-only artifact JSON shape and values"
  else
    fail "iso-only artifact JSON shape and values"
  fi
else
  if jq -e '
      .apiVersion == "sysemble/artifact/v1" and
      .spec == "minimal-debian-live" and
      .arch == "x86_64" and
      .packages == ["apt","ca-certificates","systemd"] and
      .rootfs.path == "rootfs" and
      (.images | length == 1) and
      .images[0].path == "live.iso" and
      .images[0].format == "iso" and
      (.images[0].sha256 | test("^[0-9a-f]{64}$")) and
      .images[0].size_mb == 1 and
      (has("partitions") | not) and
      (has("desktop") | not) and
      (.boot | has("install_device") | not) and
      (.boot.cmdline | contains("sysemble.install") | not) and
      .boot == {"mode":"iso","iso":"live.iso","cmdline":"boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1","memory_mb":1024}
    ' "$ISO_JSON" >/dev/null 2>&1; then
    pass "iso-only artifact JSON shape and values (jq)"
  else
    fail "iso-only artifact JSON shape and values (jq)"
  fi
fi

# ---------------------------------------------------------------------------
# P0-d3 installer artifact (boot.mode=install, ISO-only, headless)
# ---------------------------------------------------------------------------

INSTALL_JSON="$TMP_DIR/artifact-install.json"
if artifact_install_json "$ISO_OUT" "minimal-debian-live-install" "trixie" "2026-11-01" \
  "x86_64" "$CREATED_AT" "${PACKAGES[@]}" >"$INSTALL_JSON"; then
  pass "artifact_install_json exits 0 for an installer ISO"
else
  fail "artifact_install_json failed for an installer ISO"
fi
INSTALL_CMDLINE="boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1 sysemble.install=/dev/vda"
if [ "$json_backend" = "python3" ]; then
  if python3 - "$INSTALL_JSON" "$ISO_OUT" "$INSTALL_CMDLINE" <<'PY'
import json
import os
import re
import sys

path, out, install_cmdline = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    doc = json.load(fh)

def check(condition, message):
    if not condition:
        sys.exit("FAIL: " + message)
    print("ok - " + message)

check(
    set(doc) == {
        "apiVersion", "createdAt", "spec", "base", "arch", "packages",
        "rootfs", "images", "boot", "builder",
    },
    "installer top-level keys omit partitions and desktop",
)
check(doc["apiVersion"] == "sysemble/artifact/v1", "apiVersion")
check(doc["spec"] == "minimal-debian-live-install", "spec")
check(doc["packages"] == ["apt", "ca-certificates", "systemd"], "artifact.packages keeps the plan list")
check(len(doc["images"]) == 1, "installer images keeps exactly one entry")
check(doc["images"][0]["path"] == "live.iso", "installer image is live.iso")
check(doc["images"][0]["format"] == "iso", "installer image format is iso")
check(
    set(doc["boot"]) == {"mode", "iso", "install_device", "cmdline", "memory_mb"},
    "installer boot keys are mode/iso/install_device/cmdline/memory_mb",
)
check(doc["boot"]["mode"] == "install", "boot.mode is install")
check(doc["boot"]["iso"] == "live.iso", "boot.iso is live.iso")
check(doc["boot"]["install_device"] == "/dev/vda", "boot.install_device is /dev/vda")
check(doc["boot"]["cmdline"] == install_cmdline, "installer boot.cmdline appends the install parameter")
check(doc["boot"]["cmdline"].endswith("sysemble.install=/dev/vda"), "installer cmdline ends with sysemble.install=/dev/vda")
check(doc["boot"]["memory_mb"] == 1024, "installer boot.memory_mb is 1024")
check("graphical" not in doc["boot"], "installer boot has no graphical flag")
check("partitions" not in doc, "installer artifact omits partitions")
check("desktop" not in doc, "installer artifact omits desktop")
check(doc["builder"] == {"name": "build.sh", "version": "0.1.0"}, "builder")
check(os.path.isfile(os.path.join(out, "live.iso")), "live.iso exists under <out>")
PY
  then
    pass "installer artifact JSON shape and values"
  else
    fail "installer artifact JSON shape and values"
  fi
else
  if jq -e --arg cmdline "$INSTALL_CMDLINE" '
      .apiVersion == "sysemble/artifact/v1" and
      .spec == "minimal-debian-live-install" and
      .packages == ["apt","ca-certificates","systemd"] and
      (.images | length == 1) and
      .images[0].path == "live.iso" and
      .images[0].format == "iso" and
      (has("partitions") | not) and
      (has("desktop") | not) and
      .boot == {"mode":"install","iso":"live.iso","install_device":"/dev/vda","cmdline":$cmdline,"memory_mb":1024}
    ' "$INSTALL_JSON" >/dev/null 2>&1; then
    pass "installer artifact JSON shape and values (jq)"
  else
    fail "installer artifact JSON shape and values (jq)"
  fi
fi

# A display manager cannot turn an installer ISO graphical: it stays 1024 MB,
# multi-user, and without a desktop object (headless install contract).
INSTALL_DM_JSON="$TMP_DIR/artifact-install-dm.json"
artifact_install_json "$ISO_OUT" "debian-live-xfce-install" "trixie" "" \
  "x86_64" "$CREATED_AT" apt lightdm xfce4 >"$INSTALL_DM_JSON"
if [ "$json_backend" = "python3" ]; then
  if python3 - "$INSTALL_DM_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)
if doc["boot"]["memory_mb"] != 1024:
    sys.exit("installer memory_mb must stay 1024")
if "graphical" in doc["boot"]:
    sys.exit("installer boot must not be graphical")
if "desktop" in doc:
    sys.exit("installer artifact must not have a desktop object")
if doc["boot"]["cmdline"].find("systemd.unit=multi-user.target") < 0:
    sys.exit("installer cmdline must stay multi-user")
PY
  then
    pass "installer artifact ignores display-manager packages (headless 1024 MB)"
  else
    fail "installer artifact changed the headless contract for a DM plan"
  fi
else
  if jq -e '
      .boot.memory_mb == 1024 and
      (.boot | has("graphical") | not) and
      (has("desktop") | not) and
      (.boot.cmdline | contains("systemd.unit=multi-user.target"))
    ' "$INSTALL_DM_JSON" >/dev/null 2>&1; then
    pass "installer artifact ignores display-manager packages (headless 1024 MB) (jq)"
  else
    fail "installer artifact changed the headless contract for a DM plan (jq)"
  fi
fi

if artifact_install_json "$TMP_DIR/no-such" "spec" "trixie" "" "x86_64" "$CREATED_AT" \
  "${PACKAGES[@]}" >/dev/null 2>&1; then
  fail "artifact_install_json must fail without rootfs"
else
  pass "artifact_install_json fails without rootfs"
fi

# ---------------------------------------------------------------------------
# P0-e1 TUI installer artifact (boot.mode=install, install_tui=true, no disk)
# ---------------------------------------------------------------------------

INSTALL_TUI_JSON="$TMP_DIR/artifact-install-tui.json"
if artifact_install_tui_json "$ISO_OUT" "minimal-debian-live-install-tui" "trixie" "2026-11-01" \
  "x86_64" "$CREATED_AT" "${PACKAGES[@]}" >"$INSTALL_TUI_JSON"; then
  pass "artifact_install_tui_json exits 0 for a TUI installer ISO"
else
  fail "artifact_install_tui_json failed for a TUI installer ISO"
fi
INSTALL_TUI_CMDLINE="boot=live live-media-path=/live console=ttyS0 systemd.unit=multi-user.target systemd.journald.forward_to_console=1 sysemble.install.tui=1"
if [ "$json_backend" = "python3" ]; then
  if python3 - "$INSTALL_TUI_JSON" "$ISO_OUT" "$INSTALL_TUI_CMDLINE" <<'PY'
import json
import os
import re
import sys

path, out, tui_cmdline = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    doc = json.load(fh)

def check(condition, message):
    if not condition:
        sys.exit("FAIL: " + message)
    print("ok - " + message)

check(
    set(doc) == {
        "apiVersion", "createdAt", "spec", "base", "arch", "packages",
        "rootfs", "images", "boot", "builder",
    },
    "TUI installer top-level keys omit partitions and desktop",
)
check(doc["apiVersion"] == "sysemble/artifact/v1", "TUI apiVersion")
check(doc["spec"] == "minimal-debian-live-install-tui", "TUI spec")
check(doc["packages"] == ["apt", "ca-certificates", "systemd"], "TUI artifact.packages keeps the plan list")
check(len(doc["images"]) == 1, "TUI installer images keeps exactly one entry")
check(doc["images"][0]["path"] == "live.iso", "TUI image is live.iso")
check(doc["images"][0]["format"] == "iso", "TUI image format is iso")
check(
    set(doc["boot"]) == {"mode", "iso", "install_tui", "cmdline", "memory_mb"},
    "TUI boot keys are mode/iso/install_tui/cmdline/memory_mb",
)
check(doc["boot"]["mode"] == "install", "TUI boot.mode is install")
check(doc["boot"]["iso"] == "live.iso", "TUI boot.iso is live.iso")
check(doc["boot"]["install_tui"] is True, "TUI boot.install_tui is true")
check("install_device" not in doc["boot"], "TUI artifact has no install_device")
check(doc["boot"]["cmdline"] == tui_cmdline, "TUI boot.cmdline ends with the TUI marker")
check(doc["boot"]["cmdline"].endswith("sysemble.install.tui=1"), "TUI cmdline suffix")
check("sysemble.install=/dev/vda" not in doc["boot"]["cmdline"], "TUI cmdline has no install device")
check(doc["boot"]["memory_mb"] == 1024, "TUI boot.memory_mb is 1024")
check("graphical" not in doc["boot"], "TUI boot has no graphical flag")
check("partitions" not in doc, "TUI artifact omits partitions")
check("desktop" not in doc, "TUI artifact omits desktop")
check(doc["builder"] == {"name": "build.sh", "version": "0.1.0"}, "TUI builder")
check(os.path.isfile(os.path.join(out, "live.iso")), "TUI live.iso exists under <out>")
PY
  then
    pass "TUI installer artifact JSON shape and values"
  else
    fail "TUI installer artifact JSON shape and values"
  fi
else
  if jq -e --arg cmdline "$INSTALL_TUI_CMDLINE" '
      .apiVersion == "sysemble/artifact/v1" and
      .spec == "minimal-debian-live-install-tui" and
      .packages == ["apt","ca-certificates","systemd"] and
      (.images | length == 1) and
      .images[0].path == "live.iso" and
      .images[0].format == "iso" and
      (has("partitions") | not) and
      (has("desktop") | not) and
      (.boot | has("install_device") | not) and
      .boot == {"mode":"install","iso":"live.iso","install_tui":true,"cmdline":$cmdline,"memory_mb":1024}
    ' "$INSTALL_TUI_JSON" >/dev/null 2>&1; then
    pass "TUI installer artifact JSON shape and values (jq)"
  else
    fail "TUI installer artifact JSON shape and values (jq)"
  fi
fi

if artifact_install_tui_json "$TMP_DIR/no-such" "spec" "trixie" "" "x86_64" "$CREATED_AT" \
  "${PACKAGES[@]}" >/dev/null 2>&1; then
  fail "artifact_install_tui_json must fail without rootfs"
else
  pass "artifact_install_tui_json fails without rootfs"
fi

ISO_DM_JSON="$TMP_DIR/artifact-iso-desktop.json"
if artifact_iso_json "$ISO_OUT" "debian-live-xfce" "trixie" "2026-11-01" \
  "x86_64" "$CREATED_AT" 0 apt ca-certificates lightdm xfce4 >"$ISO_DM_JSON"; then
  pass "artifact_iso_json exits 0 for a DM live plan"
else
  fail "artifact_iso_json failed for a DM live plan"
fi
if [ "$json_backend" = "python3" ]; then
  if python3 - "$ISO_DM_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)
if doc.get("desktop") != {"session": "xfce", "display_manager": "lightdm"}:
    sys.exit("desktop inference changed for ISO")
if doc["boot"].get("graphical") is not True:
    sys.exit("ISO DM boot.graphical must be true")
if doc["boot"].get("memory_mb") != 2048:
    sys.exit("ISO DM memory_mb must be 2048")
if not doc["boot"]["cmdline"].endswith("systemd.unit=graphical.target systemd.journald.forward_to_console=1"):
    sys.exit("ISO DM cmdline must target graphical.target")
if "partitions" in doc:
    sys.exit("iso-only DM artifact must omit partitions")
PY
  then
    pass "iso-only DM artifact keeps desktop/graphical/2048 and no partitions"
  else
    fail "iso-only DM artifact changed the desktop contract"
  fi
else
  if jq -e '
      .desktop == {"session":"xfce","display_manager":"lightdm"} and
      .boot.graphical == true and
      .boot.memory_mb == 2048 and
      (.boot.cmdline | endswith("systemd.unit=graphical.target systemd.journald.forward_to_console=1")) and
      (has("partitions") | not)
    ' "$ISO_DM_JSON" >/dev/null 2>&1; then
    pass "iso-only DM artifact keeps desktop/graphical/2048 and no partitions (jq)"
  else
    fail "iso-only DM artifact changed the desktop contract (jq)"
  fi
fi

BOTH_OUT="$TMP_DIR/iso-disk-out"
mkdir -p "$BOTH_OUT/rootfs"
cp "$ISO_ROOTFS/boot/$KERNEL_NAME" "$BOTH_OUT/rootfs/kernel"
printf 'fake iso\n' >"$BOTH_OUT/live.iso"
truncate -s 1024M "$BOTH_OUT/disk.img"
printf 'fake qcow2\n' >"$BOTH_OUT/disk.qcow2"
BOTH_JSON="$TMP_DIR/artifact-iso-disk.json"
if artifact_iso_json "$BOTH_OUT" "debian-minimal-both" "trixie" "" \
  "x86_64" "$CREATED_AT" 1 "${PACKAGES[@]}" >"$BOTH_JSON"; then
  pass "artifact_iso_json exits 0 for an iso+disk build"
else
  fail "artifact_iso_json failed for an iso+disk build"
fi
if [ "$json_backend" = "python3" ]; then
  if python3 - "$BOTH_JSON" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)
if doc["boot"]["mode"] != "iso" or doc["boot"]["iso"] != "live.iso":
    sys.exit("iso+disk boot mode must stay iso")
images = {image["format"]: image for image in doc["images"]}
if set(images) != {"iso", "raw", "qcow2"}:
    sys.exit("iso+disk images must include iso/raw/qcow2")
if doc["partitions"] != [
    {"index": 1, "role": "esp", "size_mb": 512, "fs": "vfat32"},
    {"index": 2, "role": "root", "size_mb": 512, "fs": "ext4"},
]:
    sys.exit("iso+disk partitions are wrong")
if doc["base"]["pin"] is not None:
    sys.exit("missing pin must be null")
if not os.path.isfile(os.path.join(os.path.dirname(sys.argv[1]), "iso-disk-out", "live.iso")):
    sys.exit("live.iso fixture missing")
PY
  then
    pass "iso+disk artifact keeps ISO boot mode, all images, and partitions"
  else
    fail "iso+disk artifact shape is wrong"
  fi
else
  if jq -e '
      .boot.mode == "iso" and .boot.iso == "live.iso" and
      ([.images[].format] | sort == ["iso","qcow2","raw"]) and
      .partitions == [
        {"index":1,"role":"esp","size_mb":512,"fs":"vfat32"},
        {"index":2,"role":"root","size_mb":512,"fs":"ext4"}
      ]
    ' "$BOTH_JSON" >/dev/null 2>&1; then
    pass "iso+disk artifact keeps ISO boot mode and partitions (jq)"
  else
    fail "iso+disk artifact shape is wrong (jq)"
  fi
fi

# artifact_iso_json must fail without live.iso / rootfs.
if artifact_iso_json "$TMP_DIR/no-such" "spec" "trixie" "" "x86_64" "$CREATED_AT" 0 \
  "${PACKAGES[@]}" >/dev/null 2>&1; then
  fail "artifact_iso_json must fail without rootfs"
else
  pass "artifact_iso_json fails without rootfs"
fi
if artifact_iso_json "$ISO_OUT" "spec" "trixie" "" "x86_64" "$CREATED_AT" 2 \
  "${PACKAGES[@]}" >/dev/null 2>&1; then
  fail "artifact_iso_json must reject include_disk other than 0/1"
else
  pass "artifact_iso_json rejects an invalid include_disk flag"
fi

# ---------------------------------------------------------------------------
# P0-d2 plan output mode selection
# ---------------------------------------------------------------------------

PLAN_OUTPUTS_VALUES=(iso)
assert_eq "iso" "$(plan_build_mode)" "outputs [iso] selects iso-only"
PLAN_OUTPUTS_VALUES=(qcow2 iso)
assert_eq "iso-disk" "$(plan_build_mode)" "outputs [qcow2, iso] selects iso+disk"
PLAN_OUTPUTS_VALUES=(raw iso)
assert_eq "iso-disk" "$(plan_build_mode)" "outputs [raw, iso] selects iso+disk"
PLAN_OUTPUTS_VALUES=(qcow2)
assert_eq "disk" "$(plan_build_mode)" "outputs [qcow2] keeps the disk path"
PLAN_OUTPUTS_VALUES=()
assert_eq "disk" "$(plan_build_mode)" "missing outputs keep the legacy disk path"
assert_eq "live-boot live-boot-initramfs-tools" "${ISO_RUNTIME_PACKAGES[*]}" \
  "ISO runtime packages are live-boot and live-boot-initramfs-tools"

# Runtime packages are deduplicated against plan.packages and each other.
PLAN_PACKAGES_VALUES=(apt live-boot)
assert_eq "live-boot-initramfs-tools" "$(runtime_packages_for 1 0)" \
  "ISO runtime packages do not duplicate live-boot from the plan"
assert_eq "1" "$(runtime_package_count_for 1 0)" \
  "ISO runtime count reflects the deduplicated list"
PLAN_PACKAGES_VALUES=(apt live-boot live-boot-initramfs-tools)
assert_eq "" "$(runtime_packages_for 1 0)" \
  "both live packages present in the plan add no runtime packages"
PLAN_PACKAGES_VALUES=(apt)
assert_eq "xserver-xorg,procps,accountsservice,live-boot,live-boot-initramfs-tools" \
  "$(runtime_packages_for 1 1)" "desktop ISO runtime list keeps desktop then live packages"
assert_eq "5" "$(runtime_package_count_for 1 1)" "desktop ISO runtime count is 5"

# P0-d3 installer packages are appended after the live runtime list and
# deduplicated against plan.packages (e2fsprogs is commonly already planned).
assert_eq "rsync grub-efi-amd64 grub-efi-amd64-bin dosfstools gdisk e2fsprogs" \
  "${INSTALLER_RUNTIME_PACKAGES[*]}" \
  "installer runtime packages are rsync/grub/dosfstools/gdisk/e2fsprogs"
PLAN_PACKAGES_VALUES=(apt e2fsprogs)
assert_eq "live-boot,live-boot-initramfs-tools,rsync,grub-efi-amd64,grub-efi-amd64-bin,dosfstools,gdisk" \
  "$(runtime_packages_for 1 0 1)" \
  "installer runtime packages append after live-boot and dedupe e2fsprogs"
assert_eq "7" "$(runtime_package_count_for 1 0 1)" \
  "installer runtime count reflects the deduplicated list"
PLAN_PACKAGES_VALUES=(apt)
assert_eq "8" "$(runtime_package_count_for 1 0 1)" \
  "installer runtime count includes e2fsprogs when the plan omits it"
assert_eq "live-boot,live-boot-initramfs-tools" "$(runtime_packages_for 1 0 0)" \
  "installer flag 0 keeps the P0-d2 live runtime list unchanged"
PLAN_PACKAGES_VALUES=()

# ---------------------------------------------------------------------------
# P0-d1 desktop inference (pure helpers used by build.sh and artifact_json)
# ---------------------------------------------------------------------------

assert_eq "gdm" "$(detect_display_manager gdm3 sddm lightdm)" \
  "display-manager priority: gdm3 wins over sddm and lightdm"
assert_eq "sddm" "$(detect_display_manager sddm lightdm)" \
  "display-manager priority: sddm wins over lightdm"
assert_eq "lightdm" "$(detect_display_manager apt lightdm xfce4)" \
  "display-manager detection: lightdm"
assert_fails "display-manager detection fails without a DM" \
  detect_display_manager apt ca-certificates systemd
DM_EMPTY=$(detect_display_manager apt systemd 2>/dev/null || true)
assert_eq "" "$DM_EMPTY" "display-manager detection prints nothing without a DM"
assert_eq "plasma" "$(detect_desktop_session plasma-desktop gnome-shell xfce4)" \
  "session priority: plasma-desktop wins"
assert_eq "gnome" "$(detect_desktop_session gnome-shell xfce4)" \
  "session priority: gnome-shell wins over xfce4"
assert_eq "xfce" "$(detect_desktop_session apt xfce4)" "session detection: xfce"
assert_eq "unknown" "$(detect_desktop_session lightdm)" \
  "a DM without a recognized session falls back to 'unknown'"

# P0-d1 boot evidence unit: the marker text must contain Xorg and the actual
# Debian display-manager process name so boot-check can match it unchanged.
EVIDENCE_LIGHTDM="$TMP_DIR/evidence-lightdm.service"
EVIDENCE_SDDM="$TMP_DIR/evidence-sddm.service"
EVIDENCE_GDM="$TMP_DIR/evidence-gdm.service"
if boot_evidence_service_text lightdm >"$EVIDENCE_LIGHTDM"; then
  pass "boot_evidence_service_text renders the lightdm unit"
else
  fail "boot_evidence_service_text failed for lightdm"
fi
boot_evidence_service_text sddm >"$EVIDENCE_SDDM"
boot_evidence_service_text gdm >"$EVIDENCE_GDM"
assert_eq "xserver-xorg procps accountsservice" "${GRAPHICAL_RUNTIME_PACKAGES[*]}" \
  "graphical runtime packages are xserver-xorg, procps, and accountsservice"
assert_contains "Description=Sysemble boot evidence markers" "$EVIDENCE_LIGHTDM" \
  "evidence unit has the Sysemble description"
assert_contains "After=graphical.target" "$EVIDENCE_LIGHTDM" \
  "evidence unit runs after graphical.target"
assert_contains "WantedBy=graphical.target" "$EVIDENCE_LIGHTDM" \
  "evidence unit is wanted by graphical.target"
assert_contains "Type=oneshot" "$EVIDENCE_LIGHTDM" "evidence unit is oneshot"
assert_contains "SYMBLE: Xorg ready" "$EVIDENCE_LIGHTDM" \
  "evidence unit emits the Xorg marker"
assert_contains "SYMBLE: lightdm ready" "$EVIDENCE_LIGHTDM" \
  "evidence unit emits the lightdm marker"
assert_contains "SYMBLE: sddm ready" "$EVIDENCE_SDDM" \
  "evidence unit emits the sddm marker"
assert_contains "SYMBLE: gdm3 ready" "$EVIDENCE_GDM" \
  "gdm maps to the Debian gdm3 process and marker"
assert_not_contains "SYMBLE: gdm ready" "$EVIDENCE_GDM" \
  "gdm marker uses gdm3, not the artifact string gdm"
assert_contains "pgrep -x Xorg" "$EVIDENCE_LIGHTDM" \
  "evidence unit probes the Xorg process"
assert_contains 'i=0; while [ $$i -lt 60 ]' "$EVIDENCE_LIGHTDM" \
  "evidence unit retries the markers for up to 60 seconds"
assert_contains 'i=$$((i+1)); sleep 1' "$EVIDENCE_LIGHTDM" \
  "evidence unit waits one second between marker polls"
assert_not_contains 'while [ $i -lt 60 ]' "$EVIDENCE_LIGHTDM" \
  "evidence unit escapes systemd dollar substitution in the loop condition"
assert_not_contains 'i=$((i+1))' "$EVIDENCE_LIGHTDM" \
  "evidence unit escapes systemd dollar substitution in the loop increment"
assert_contains "TimeoutStartSec=90" "$EVIDENCE_LIGHTDM" \
  "evidence unit has a 90 second systemd start timeout"
assert_fails "boot_evidence_service_text rejects an unknown display manager" \
  boot_evidence_service_text nope

# ---------------------------------------------------------------------------
# JSON shape / values (P0-c UEFI artifact, no display manager)
# ---------------------------------------------------------------------------

if [ "$json_backend" = "python3" ]; then
  if python3 - "$JSON" "$OUT" "$CREATED_AT" "$KERNEL_NAME" "$INITRD_NAME" <<'PY'
import json
import os
import re
import sys

path, out, created_at, kernel_name, initrd_name = (
    sys.argv[1],
    sys.argv[2],
    sys.argv[3],
    sys.argv[4],
    sys.argv[5],
)
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
        "rootfs", "images", "boot", "partitions", "builder",
    },
    "top-level keys match sysemble/artifact/v1 plus P0-c partitions",
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
check("desktop" not in doc, "no-DM artifact has no top-level desktop object")
check(
    set(boot) == {
        "mode", "disk", "kernel", "initrd", "graphical", "memory_mb",
        "cmdline", "grub",
    },
    "no-DM boot object has the P0-c keys plus graphical/memory_mb",
)
check(boot["mode"] == "uefi", "boot.mode is uefi")
check(boot["disk"] == "disk.img", "boot.disk is disk.img")
check(boot["kernel"] == "rootfs/boot/" + kernel_name, "highest kernel version wins (6.12.3)")
check(boot["initrd"] == "rootfs/boot/" + initrd_name, "highest initrd version wins (6.12.3)")
check(boot["graphical"] is False, "no-DM boot.graphical is false")
check(boot["memory_mb"] == 1024, "no-DM boot.memory_mb is 1024")
check(
    boot["cmdline"] == "root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=multi-user.target",
    "no-DM boot.cmdline is the frozen P0-c UEFI cmdline",
)
check(boot["cmdline"].startswith("root=/dev/vda2"), "boot.cmdline starts with root=/dev/vda2")
check(
    boot["grub"] == {"efi": "esp/EFI/BOOT/BOOTX64.EFI", "config": "grub.cfg"},
    "boot.grub points at the generated EFI and config",
)
check(os.path.isfile(os.path.join(out, boot["kernel"])), "boot.kernel exists under <out>")
check(os.path.isfile(os.path.join(out, boot["initrd"])), "boot.initrd exists under <out>")
check(os.path.isfile(os.path.join(out, boot["grub"]["efi"])), "boot.grub.efi exists under <out>")
check(os.path.isfile(os.path.join(out, boot["grub"]["config"])), "boot.grub.config exists under <out>")

check(
    doc["partitions"] == [
        {"index": 1, "role": "esp", "size_mb": 512, "fs": "vfat32"},
        {"index": 2, "role": "root", "size_mb": 3584, "fs": "ext4"},
    ],
    "partitions are exactly the P0-c ESP 512 / root 3584 layout",
)
check(doc["builder"] == {"name": "build.sh", "version": "0.1.0"}, "builder name/version")
PY
  then
    pass "artifact JSON shape and values (P0-c UEFI)"
  else
    fail "artifact JSON shape and values (P0-c UEFI)"
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
      (has("desktop") | not) and
      .boot.mode == "uefi" and
      .boot.disk == "disk.img" and
      .boot.kernel == "rootfs/boot/vmlinuz-6.12.3" and
      .boot.initrd == "rootfs/boot/initrd.img-6.12.3" and
      .boot.graphical == false and
      .boot.memory_mb == 1024 and
      .boot.cmdline == "root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=multi-user.target" and
      .boot.grub == {"efi":"esp/EFI/BOOT/BOOTX64.EFI","config":"grub.cfg"} and
      .partitions == [
        {"index":1,"role":"esp","size_mb":512,"fs":"vfat32"},
        {"index":2,"role":"root","size_mb":3584,"fs":"ext4"}
      ] and
      .builder == {"name":"build.sh","version":"0.1.0"}
    ' "$JSON" >/dev/null 2>&1; then
    pass "artifact JSON shape and values (P0-c UEFI, jq)"
  else
    fail "artifact JSON shape and values (P0-c UEFI, jq)"
  fi
fi

# ---------------------------------------------------------------------------
# P0-d1 graphical artifact: lightdm + xfce4 -> lightdm/xfce, 2048 MB
# ---------------------------------------------------------------------------

DM_PACKAGES=(apt ca-certificates lightdm xfce4)
DM_JSON="$TMP_DIR/artifact-desktop.json"
if artifact_json "$OUT" "debian-xfce" "trixie" "2026-11-01" "x86_64" \
  "$CREATED_AT" "${DM_PACKAGES[@]}" >"$DM_JSON"; then
  pass "artifact_json exits 0 for a DM plan"
else
  fail "artifact_json failed for a DM plan"
fi

assert_eq "$(json_boot_cmdline "$JSON")" "$(grub_kernel_cmdline "$OUT/grub.cfg")" \
  "no-DM grub.cfg kernel line matches the artifact cmdline byte for byte"
assert_eq "$(json_boot_cmdline "$DM_JSON")" "$(grub_kernel_cmdline "$GRAPHICAL_GRUB")" \
  "graphical grub.cfg kernel line matches the artifact cmdline byte for byte"

if [ "$json_backend" = "python3" ]; then
  if python3 - "$DM_JSON" "$OUT" <<'PY'
import json
import os
import sys

path, out = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as fh:
    doc = json.load(fh)

def check(condition, message):
    if not condition:
        sys.exit("FAIL: " + message)
    print("ok - " + message)

DESKTOP_CMDLINE = (
    "root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 "
    "systemd.unit=graphical.target systemd.journald.forward_to_console=1"
)
check(
    set(doc) == {
        "apiVersion", "createdAt", "spec", "base", "arch", "packages",
        "rootfs", "images", "desktop", "boot", "partitions", "builder",
    },
    "DM artifact top-level keys add desktop to the P0-c shape",
)
check(doc["desktop"] == {"session": "xfce", "display_manager": "lightdm"},
      "desktop infers session=xfce and display_manager=lightdm")
check(doc["spec"] == "debian-xfce", "DM artifact keeps plan.spec")
check(len(doc["packages"]) == 4, "DM artifact keeps the package list")
check(
    set(doc["boot"]) == {
        "mode", "disk", "kernel", "initrd", "graphical", "memory_mb",
        "cmdline", "grub",
    },
    "DM boot object has the P0-c keys plus graphical/memory_mb",
)
check(doc["boot"]["graphical"] is True, "DM boot.graphical is true")
check(doc["boot"]["memory_mb"] == 2048, "DM boot.memory_mb is 2048")
check(doc["boot"]["cmdline"] == DESKTOP_CMDLINE,
      "DM boot.cmdline targets graphical.target and forwards journald")
check(doc["boot"]["cmdline"].endswith("systemd.journald.forward_to_console=1"),
      "DM cmdline ends with the journald console-forwarding flag")
check(doc["boot"]["mode"] == "uefi", "DM boot.mode stays uefi")
check(
    doc["partitions"] == [
        {"index": 1, "role": "esp", "size_mb": 512, "fs": "vfat32"},
        {"index": 2, "role": "root", "size_mb": 3584, "fs": "ext4"},
    ],
    "DM artifact keeps the P0-c partitions unchanged",
)
check([image["format"] for image in doc["images"]] == ["raw", "qcow2"],
      "DM artifact keeps the raw+qcow2 images unchanged")
check(os.path.isfile(os.path.join(out, doc["boot"]["grub"]["efi"])),
      "DM boot.grub.efi exists under <out>")
PY
  then
    pass "artifact JSON shape and values (P0-d1 graphical)"
  else
    fail "artifact JSON shape and values (P0-d1 graphical)"
  fi
else
  if jq -e '
      .desktop == {"session":"xfce","display_manager":"lightdm"} and
      .boot.graphical == true and
      .boot.memory_mb == 2048 and
      .boot.mode == "uefi" and
      .boot.cmdline == "root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=graphical.target systemd.journald.forward_to_console=1" and
      .partitions == [
        {"index":1,"role":"esp","size_mb":512,"fs":"vfat32"},
        {"index":2,"role":"root","size_mb":3584,"fs":"ext4"}
      ]
    ' "$DM_JSON" >/dev/null 2>&1; then
    pass "artifact JSON shape and values (P0-d1 graphical, jq)"
  else
    fail "artifact JSON shape and values (P0-d1 graphical, jq)"
  fi
fi

# The desktop object must stay absent when the same packages have no DM.
NODM_XFCE_JSON="$TMP_DIR/artifact-xfce-no-dm.json"
if artifact_json "$OUT" "debian-xfce" "trixie" "2026-11-01" "x86_64" \
  "$CREATED_AT" apt xfce4 >"$NODM_XFCE_JSON" 2>/dev/null; then
  pass "artifact_json accepts an XFCE session without a display manager"
else
  fail "artifact_json failed for an XFCE session without a display manager"
fi
if [ "$json_backend" = "python3" ]; then
  if python3 - "$NODM_XFCE_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)
if "desktop" in doc:
    sys.exit("session-only plan must not add desktop")
if doc["boot"]["graphical"] is not False or doc["boot"]["memory_mb"] != 1024:
    sys.exit("session-only plan must stay non-graphical")
if not doc["boot"]["cmdline"].endswith("systemd.unit=multi-user.target"):
    sys.exit("session-only plan must keep the multi-user cmdline")
PY
  then
    pass "session without DM keeps graphical=false/memory 1024/no desktop"
  else
    fail "session without DM changed the no-DM contract"
  fi
else
  if jq -e '(has("desktop") | not) and .boot.graphical == false and .boot.memory_mb == 1024' \
    "$NODM_XFCE_JSON" >/dev/null 2>&1; then
    pass "session without DM keeps graphical=false/memory 1024/no desktop (jq)"
  else
    fail "session without DM changed the no-DM contract (jq)"
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
if doc["boot"]["mode"] != "uefi":
    sys.exit("UEFI mode lost on the escaped-spec artifact")
PY
  then
    pass "escaped spec round-trips and missing pin is null"
  else
    fail "escaped spec round-trips and missing pin is null"
  fi
else
  if jq -e '.base.pin == null and .boot.mode == "uefi"' "$WEIRD_JSON" >/dev/null 2>&1; then
    pass "missing pin is null (jq)"
  else
    fail "missing pin is null (jq)"
  fi
fi

# ---------------------------------------------------------------------------
# P0-b backward compatibility: without GRUB outputs the helper must emit the
# historical direct-kernel shape (boot.mode absent means kernel).
# ---------------------------------------------------------------------------

mkdir -p "$TMP_DIR/uefi-held"
mv "$OUT/esp" "$TMP_DIR/uefi-held/esp"
mv "$OUT/grub.cfg" "$TMP_DIR/uefi-held/grub.cfg"
# The legacy shape has no partitions, so a small raw file is enough and keeps
# the extra SHA-256 fast.
truncate -s 3M "$OUT/disk.img"

LEGACY_JSON="$TMP_DIR/artifact-kernel.json"
if artifact_json "$OUT" "minimal-debian" "trixie" "2026-11-01" "x86_64" \
  "$CREATED_AT" "${PACKAGES[@]}" >"$LEGACY_JSON" 2>"$TMP_DIR/legacy.err"; then
  pass "artifact_json still emits the P0-b kernel shape without ESP outputs"
else
  fail "artifact_json failed for the P0-b kernel fallback"
fi

if [ "$json_backend" = "python3" ]; then
  if python3 - "$LEGACY_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    doc = json.load(fh)
if "partitions" in doc:
    sys.exit("kernel-mode artifact must not contain partitions")
if "desktop" in doc:
    sys.exit("kernel-mode artifact must not contain the P0-d1 desktop object")
if "mode" in doc["boot"]:
    sys.exit("kernel-mode artifact must omit boot.mode (defaults to kernel)")
if "disk" in doc["boot"] or "grub" in doc["boot"]:
    sys.exit("kernel-mode artifact must not contain UEFI boot fields")
if "graphical" in doc["boot"] or "memory_mb" in doc["boot"]:
    sys.exit("kernel-mode artifact must keep the historical P0-b boot shape")
if doc["boot"]["cmdline"] != "console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target":
    sys.exit("kernel-mode cmdline changed")
PY
  then
    pass "kernel fallback omits mode/disk/grub/partitions and keeps the P0-b cmdline"
  else
    fail "kernel fallback shape is wrong"
  fi
else
  if jq -e 'has("partitions") | not' "$LEGACY_JSON" >/dev/null 2>&1 &&
    jq -e '.boot | has("mode") | not' "$LEGACY_JSON" >/dev/null 2>&1; then
    pass "kernel fallback omits mode and partitions (jq)"
  else
    fail "kernel fallback shape is wrong (jq)"
  fi
fi

mv "$TMP_DIR/uefi-held/esp" "$OUT/esp"
mv "$TMP_DIR/uefi-held/grub.cfg" "$OUT/grub.cfg"
truncate -s 4096M "$OUT/disk.img"

# ---------------------------------------------------------------------------
# Incomplete UEFI outputs must fail instead of guessing a boot mode
# ---------------------------------------------------------------------------

mv "$OUT/grub.cfg" "$TMP_DIR/uefi-held/grub.cfg"
if artifact_json "$OUT" "minimal-debian" "trixie" "2026-11-01" "x86_64" \
  "$CREATED_AT" "${PACKAGES[@]}" >"$TMP_DIR/incomplete.json" 2>"$TMP_DIR/incomplete.err"; then
  fail "artifact_json must fail when only one UEFI output exists"
else
  if grep -q 'incomplete UEFI outputs' "$TMP_DIR/incomplete.err"; then
    pass "incomplete UEFI outputs fail with a readable error"
  else
    fail "incomplete UEFI error is not readable"
  fi
fi
mv "$TMP_DIR/uefi-held/grub.cfg" "$OUT/grub.cfg"

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
# Disk sizing formula (P0-c)
# ---------------------------------------------------------------------------

assert_eq "4096" "$(compute_disk_size_mb 1)" "1 MB rootfs clamps to the 4096 MB floor"
assert_eq "4096" "$(compute_disk_size_mb 100)" "100 MB rootfs clamps to 4096 MB"
assert_eq "4096" "$(compute_disk_size_mb 500)" "500 MB rootfs clamps to 4096 MB"
assert_eq "4096" "$(compute_disk_size_mb 1000)" "1000 MB rootfs clamps to the 4096 MB floor"
assert_eq "4096" "$(compute_disk_size_mb 1920)" "1920 MB rootfs -> exactly 4096 MB"
assert_eq "4352" "$(compute_disk_size_mb 2000)" "2000 MB rootfs -> 4352 MB"
assert_eq "5888" "$(compute_disk_size_mb 3000)" "3000 MB rootfs -> 5888 MB"
assert_eq "7680" "$(compute_disk_size_mb 4096)" "4096 MB rootfs -> 7680 MB"
assert_eq "9216" "$(compute_disk_size_mb 5000)" "5000 MB rootfs -> 9216 MB (rounded to 256)"

if compute_disk_size_mb "not-a-number" >/dev/null 2>&1; then
  fail "compute_disk_size_mb rejects non-numeric input"
else
  pass "compute_disk_size_mb rejects non-numeric input"
fi

# The explicit ext4 block count keeps the filesystem inside GPT p2 and leaves
# the final 1 MiB (backup GPT) untouched.
assert_eq "916992" "$(compute_root_fs_blocks 4096)" "4096 MB disk -> 916992 ext4 blocks (3582 MiB)"
assert_eq "982528" "$(compute_root_fs_blocks 4352)" "4352 MB disk -> 982528 ext4 blocks"
if compute_root_fs_blocks "not-a-number" >/dev/null 2>&1; then
  fail "compute_root_fs_blocks rejects non-numeric input"
else
  pass "compute_root_fs_blocks rejects non-numeric input"
fi
if compute_root_fs_blocks 513 >/dev/null 2>&1; then
  fail "compute_root_fs_blocks rejects a disk smaller than the P0-c layout"
else
  pass "compute_root_fs_blocks rejects a disk smaller than the P0-c layout"
fi
ROOT_BYTES=$((916992 * 4096))
PART2_MIN_BYTES=$(((4096 - 513) * 1024 * 1024 - 1024 * 1024))
if [ "$ROOT_BYTES" -le "$PART2_MIN_BYTES" ]; then
  pass "the explicit root filesystem fits inside GPT partition 2 with a 1 MiB margin"
else
  fail "the explicit root filesystem does not fit inside GPT partition 2"
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
