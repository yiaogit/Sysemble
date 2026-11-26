#!/usr/bin/env bash
# Sysemble P1-e6a Rosetta for Linux spike (guest side).
#
# Runs as root inside the E3a Debian trixie arm64 guest. The macOS host places
# this file and a static amd64 busybox in --out (shared at /export), boots with
# `sysemble-vm run --rosetta --job rosetta-spike.sh`, and the guest agent runs
# this script as `bash /export/rosetta-spike.sh`.
#
# What it proves (docs/plan/P1-e6a-workplan.md R2-R5):
#   1. the `rosetta` virtiofs share mounts and contains the Rosetta binary;
#   2. binfmt_misc registers it with the x86_64 ELF magic/mask and shows
#      `enabled`;
#   3. an amd64 ELF executes: `busybox-amd64 uname -m` prints x86_64;
#   4. a 64 MiB sha256sum benchmark compares native arm64 with the translated
#      amd64 busybox and prints the overhead ratio.
#
# It installs binfmt-support + file with apt from the VZ NAT network. Those
# packages live only in this run's cloned VM disk; the base image is unchanged.
#
# Success prints "ROSETTA-SPIKE: pass"; a failure prints diagnostics (binfmt
# status, share listing, dmesg tail) and exits 1.
#
# This is a developer-Mac spike: GitHub macOS runners cannot nest
# Virtualization.framework, so CI never runs it.

set -euxo pipefail

EXPORT_DIR="/export"
BUSYBOX_AMD64="$EXPORT_DIR/busybox-amd64"
BUSYBOX_ARM64="$EXPORT_DIR/busybox-arm64"
ROSETTA_MOUNT="/mnt/rosetta"
ROSETTA_BIN="$ROSETTA_MOUNT/rosetta"
BENCH_FILE="/tmp/sysemble-rosetta-bench.bin"
BENCH_MIB=64
SUMMARY="$EXPORT_DIR/rosetta-spike-summary.txt"

log() {
  printf 'ROSETTA-SPIKE: %s\n' "$*"
}

diagnostics() {
  set +e
  printf '%s\n' '---- ROSETTA-SPIKE diagnostics ----'
  echo "uid=$(id -u) kernel=$(uname -r) arch=$(uname -m)"
  echo "binfmt_misc mounted: $(mountpoint -q /proc/sys/fs/binfmt_misc && echo yes || echo no)"
  echo "rosetta mount:"
  ls -la "$ROSETTA_MOUNT" 2>&1
  echo "rosetta binary:"
  file "$ROSETTA_BIN" 2>&1
  ls -l "$ROSETTA_BIN" 2>&1
  echo "/proc/sys/fs/binfmt_misc:"
  ls -la /proc/sys/fs/binfmt_misc 2>&1
  echo "binfmt rosetta entry:"
  cat /proc/sys/fs/binfmt_misc/rosetta 2>&1
  echo "busybox-amd64:"
  file "$BUSYBOX_AMD64" 2>&1
  echo "binfmt-support service:"
  systemctl status binfmt-support --no-pager 2>&1 | tail -n 20
  echo "dmesg tail:"
  dmesg 2>/dev/null | tail -n 40
  echo "---- end ROSETTA-SPIKE diagnostics ----"
  set -e
}

on_err() {
  local status=$1 line=$2 command=$3
  printf 'ROSETTA-SPIKE: failed: status=%s line=%s command=%s\n' \
    "$status" "$line" "$command" >&2
  diagnostics
  exit 1
}

trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

now_ns() {
  date +%s%N
}

# timed <command...>: run a benchmark once, print elapsed nanoseconds.
timed() {
  local start_ns end_ns
  start_ns=$(now_ns)
  "$@" >/dev/null
  end_ns=$(now_ns)
  printf '%s' "$((end_ns - start_ns))"
}

ns_to_ms() {
  local ns=$1
  printf '%d.%03d' "$((ns / 1000000))" "$(((ns / 1000) % 1000))"
}

main() {
  [ "$(id -u)" -eq 0 ] || {
    log "this script must run as root in the guest"
    exit 1
  }
  [ -f "$BUSYBOX_AMD64" ] || {
    log "missing $BUSYBOX_AMD64 on the /export share"
    exit 1
  }

  log "stage 1/5: install binfmt-support and file"
  apt-get -o DPkg::Lock::Timeout=120 update
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y \
    --no-install-recommends binfmt-support file

  log "stage 2/5: mount the Rosetta virtiofs share"
  mkdir -p "$ROSETTA_MOUNT"
  if mountpoint -q "$ROSETTA_MOUNT"; then
    log "$ROSETTA_MOUNT is already mounted"
  else
    mount -t virtiofs rosetta "$ROSETTA_MOUNT"
  fi
  ls -l "$ROSETTA_BIN"
  [ -x "$ROSETTA_BIN" ] || {
    log "$ROSETTA_BIN is missing or not executable (was the VM started with --rosetta?)"
    exit 1
  }

  # binfmt-support's postinst normally mounts this. Do it explicitly so the
  # registration below does not depend on service startup ordering.
  if ! mountpoint -q /proc/sys/fs/binfmt_misc; then
    modprobe binfmt_misc || true
    mkdir -p /proc/sys/fs/binfmt_misc
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || true
  fi
  mountpoint -q /proc/sys/fs/binfmt_misc || {
    log "binfmt_misc is not mounted at /proc/sys/fs/binfmt_misc"
    exit 1
  }

  log "stage 3/5: register x86_64 ELF with the Rosetta interpreter"
  if [ -e /proc/sys/fs/binfmt_misc/rosetta ]; then
    update-binfmts --uninstall rosetta || true
  fi
  update-binfmts --install rosetta "$ROSETTA_BIN" \
    --magic '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00' \
    --mask '\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' \
    --credentials yes --preserve yes --fix-binary yes

  cat /proc/sys/fs/binfmt_misc/rosetta
  grep -qx 'enabled' /proc/sys/fs/binfmt_misc/rosetta || {
    log "the binfmt_misc rosetta entry is not enabled"
    exit 1
  }

  log "stage 4/5: execute x86_64 busybox through Rosetta"
  file "$BUSYBOX_AMD64"
  local file_output
  file_output=$(file "$BUSYBOX_AMD64")
  case "$file_output" in
    *"x86-64"*) ;;
    *)
      log "busybox-amd64 is not an x86-64 ELF: $file_output"
      exit 1
      ;;
  esac
  case "$file_output" in
    *"statically linked"*) ;;
    *)
      log "busybox-amd64 is not statically linked; the guest has no x86_64 loader: $file_output"
      exit 1
      ;;
  esac

  local uname_m
  uname_m=$("$BUSYBOX_AMD64" uname -m)
  log "busybox-amd64 uname -m: $uname_m"
  [ "$uname_m" = "x86_64" ] || {
    log "expected x86_64 from the translated binary, got '$uname_m'"
    exit 1
  }

  log "stage 5/5: 64 MiB sha256sum benchmark (native arm64 vs translated amd64)"
  dd if=/dev/zero of="$BENCH_FILE" bs=1M count="$BENCH_MIB" status=none
  sync
  local bench_size
  bench_size=$(stat -c %s "$BENCH_FILE")
  [ "$bench_size" -eq $((BENCH_MIB * 1024 * 1024)) ] || {
    log "benchmark file has unexpected size: $bench_size"
    exit 1
  }

  local arm_ns_1 arm_ns_2 arm_ns
  arm_ns_1=$(timed sha256sum "$BENCH_FILE")
  arm_ns_2=$(timed sha256sum "$BENCH_FILE")
  arm_ns=$((arm_ns_1 < arm_ns_2 ? arm_ns_1 : arm_ns_2))

  local rosetta_ns_1 rosetta_ns_2 rosetta_ns
  rosetta_ns_1=$(timed "$BUSYBOX_AMD64" sha256sum "$BENCH_FILE")
  rosetta_ns_2=$(timed "$BUSYBOX_AMD64" sha256sum "$BENCH_FILE")
  rosetta_ns=$((rosetta_ns_1 < rosetta_ns_2 ? rosetta_ns_1 : rosetta_ns_2))

  [ "$arm_ns" -gt 0 ] || {
    log "arm64 sha256sum timing was zero; cannot compute the overhead ratio"
    exit 1
  }

  local overhead_x100
  overhead_x100=$(((rosetta_ns * 100 + arm_ns / 2) / arm_ns))
  local under_10x=no
  [ "$overhead_x100" -lt 1000 ] && under_10x=yes

  printf 'ROSETTA-SPIKE: bench arm64_sha256_ms=%s rosetta_sha256_ms=%s overhead=%d.%02dx under_10x=%s\n' \
    "$(ns_to_ms "$arm_ns")" "$(ns_to_ms "$rosetta_ns")" \
    "$((overhead_x100 / 100))" "$((overhead_x100 % 100))" "$under_10x"

  # Optional like-for-like control: the same Debian busybox build for arm64.
  # The primary ratio above follows the P1-e6a workplan (coreutils sha256sum
  # vs busybox sha256sum); this control removes the implementation difference
  # so the number isolates Rosetta's translation cost.
  local busybox_arm_ns=""
  local busybox_arm_ns_1 busybox_arm_ns_2
  local busybox_amd64_ns=""
  local busybox_amd64_ns_1 busybox_amd64_ns_2
  local same_impl_overhead_x100=""
  if [ -x "$BUSYBOX_ARM64" ]; then
    busybox_arm_ns_1=$(timed "$BUSYBOX_ARM64" sha256sum "$BENCH_FILE")
    busybox_arm_ns_2=$(timed "$BUSYBOX_ARM64" sha256sum "$BENCH_FILE")
    busybox_arm_ns=$((busybox_arm_ns_1 < busybox_arm_ns_2 ? busybox_arm_ns_1 : busybox_arm_ns_2))
    busybox_amd64_ns_1=$(timed "$BUSYBOX_AMD64" sha256sum "$BENCH_FILE")
    busybox_amd64_ns_2=$(timed "$BUSYBOX_AMD64" sha256sum "$BENCH_FILE")
    busybox_amd64_ns=$((busybox_amd64_ns_1 < busybox_amd64_ns_2 ? busybox_amd64_ns_1 : busybox_amd64_ns_2))
    if [ "$busybox_arm_ns" -gt 0 ]; then
      same_impl_overhead_x100=$(((busybox_amd64_ns * 100 + busybox_arm_ns / 2) / busybox_arm_ns))
      printf 'ROSETTA-SPIKE: bench busybox_arm64_sha256_ms=%s busybox_amd64_sha256_ms=%s same_impl_overhead=%d.%02dx\n' \
        "$(ns_to_ms "$busybox_arm_ns")" "$(ns_to_ms "$busybox_amd64_ns")" \
        "$((same_impl_overhead_x100 / 100))" "$((same_impl_overhead_x100 % 100))"
    fi
  fi

  {
    echo "result=pass"
    echo "uname_m=$uname_m"
    echo "busybox_file=$file_output"
    echo "bench_bytes=$bench_size"
    echo "arm64_sha256_ns=$arm_ns"
    echo "rosetta_sha256_ns=$rosetta_ns"
    echo "overhead_x100=$overhead_x100"
    echo "under_10x=$under_10x"
    if [ -n "$busybox_arm_ns" ]; then
      echo "busybox_arm64_sha256_ns=$busybox_arm_ns"
      echo "busybox_amd64_sha256_ns=$busybox_amd64_ns"
      echo "same_impl_overhead_x100=$same_impl_overhead_x100"
    fi
    echo "kernel=$(uname -r)"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$SUMMARY"
  log "summary: $SUMMARY"
  log "pass"
}

main "$@"
