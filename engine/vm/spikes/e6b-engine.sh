#!/usr/bin/env bash
# Sysemble P1-e6b engine-in-VM spike (guest side).
#
# Runs as root inside the E3a Debian trixie arm64 guest. The macOS host boots
# the VM with
#
#   sysemble-vm run ... --rosetta --job e6b-engine.sh --timeout 3600 --json
#
# and stages in --out (shared at /export):
#   engine-image.tar   `docker save sysemble-engine:0.1.0` on the host
#   plan.json          `sysemble plan examples/minimal-debian.yaml` (x86_64)
#
# What it proves (P1-e6b):
#   1. podman (trixie) installs in the arm64 guest and uses overlay storage;
#   2. the host's Rosetta virtiofs share is mounted and registered with
#      binfmt_misc (magic/mask, credentials, preserve, fix-binary);
#   3. the amd64 engine image loads from the Docker archive and runs under
#      Rosetta (`uname -m` = x86_64);
#   4. the frozen engine entry point `engine/runtime/container-entry.sh`
#      executes `builders/debian/build.sh --execute` against the read-only
#      repository mount and exports artifact.json, disk.img and disk.qcow2 to
#      /export (the host output directory), exit code 0;
#   5. the guest recomputes the qcow2 sha256 and compares it with artifact.json.
#
# The `podman run` in step 4 does NOT use --rm: container-entry.sh deliberately
# does not export build.log, and dropping the container would also drop
# /out/build.log before we can copy it.  The container is named, its build.log
# and podman logs are copied to /export, and then it is removed with
# `podman rm -f`.  Everything else (image, options, exit semantics) matches the
# P1-e6b command.
#
# apt/podman installs and the loaded image live only in this run's cloned VM
# disk (the host APFS-clones disk.img to <out>/vm-disk.img).  The base image is
# not modified.  Nothing here is persisted for a future run.
#
# Success prints E6B: pass and writes /export/e6b-summary.txt plus
# /export/e6b-df.log (10 s disk monitor).  A failure prints diagnostics
# (podman info, df, journal/dmesg tails), writes a failed summary and exits 1.
#
# This is a developer-Mac spike: GitHub-hosted macOS runners cannot nest
# Virtualization.framework, so CI never runs it.

# -E (errtrace): without it the ERR trap is not inherited by the stage
# functions below, so a failed stage would skip diagnostics and the summary.
set -Eeuxo pipefail

EXPORT_DIR="/export"
IMAGE_TAR="$EXPORT_DIR/engine-image.tar"
PLAN="$EXPORT_DIR/plan.json"
ENGINE_IMAGE="sysemble-engine:0.1.0"
ENGINE_CTR="e6b-engine"
ROSETTA_MOUNT="/mnt/rosetta"
ROSETTA_BIN="$ROSETTA_MOUNT/rosetta"
SUMMARY="$EXPORT_DIR/e6b-summary.txt"
DF_LOG="$EXPORT_DIR/e6b-df.log"
TOTAL_START_NS=$(date +%s%N)

DISK_MON_PID=""
APT_SECONDS=""
LOAD_SECONDS=""
RUN_SECONDS=""
STORAGE_DRIVER=""
BUILD_RC=""
IMAGE_TAR_BYTES=""
GUEST_USED_BEFORE_KB=""
GUEST_AVAIL_BEFORE_KB=""
GUEST_USED_AFTER_KB=""
GUEST_AVAIL_AFTER_KB=""
STORAGE_DU=""
ARTIFACT_ARCH=""
ARTIFACT_BOOT_MODE=""
ARTIFACT_PKG_COUNT=""
QC_SHA_ARTIFACT=""
QC_SHA_ACTUAL=""
RAW_SHA_ARTIFACT=""
ROSETTA_FLAGS=""

log() {
  printf 'E6B: %s\n' "$*"
}

now_ns() {
  date +%s%N
}

# seconds_between <start-ns> <end-ns> -> decimal seconds, three fractional
# digits, e.g. 12.345.  Pure integer arithmetic (no bc).
seconds_between() {
  local ns=$(( $2 - $1 ))
  printf '%d.%03d' "$((ns / 1000000000))" "$(((ns % 1000000000) / 1000000))"
}

df_used_kb() {
  df -Pk / | awk 'NR == 2 { print $3 }'
}

df_avail_kb() {
  df -Pk / | awk 'NR == 2 { print $4 }'
}

# 10 s disk monitor: the build's peak usage is otherwise invisible because
# `podman run` blocks.  Each line is "timestamp used_kb=N avail_kb=N".
monitor_disk() {
  while :; do
    printf '%s used_kb=%s avail_kb=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(df_used_kb)" "$(df_avail_kb)"
    sleep 10
  done
}

start_monitor() {
  monitor_disk >"$DF_LOG" 2>&1 &
  DISK_MON_PID=$!
}

stop_monitor() {
  if [ -n "${DISK_MON_PID:-}" ]; then
    kill "$DISK_MON_PID" 2>/dev/null || true
    wait "$DISK_MON_PID" 2>/dev/null || true
    DISK_MON_PID=""
  fi
}

write_summary() {
  local result=$1
  local total_seconds peak_used_kb
  set +e
  total_seconds=$(seconds_between "$TOTAL_START_NS" "$(now_ns)")
  peak_used_kb=""
  if [ -f "$DF_LOG" ]; then
    peak_used_kb=$(awk '
      { for (i = 1; i <= NF; i++) if ($i ~ /^used_kb=/) { split($i, a, "="); if (a[2] + 0 > m) m = a[2] + 0 } }
      END { if (m > 0) print m }
    ' "$DF_LOG")
  fi
  {
    echo "result=$result"
    echo "kernel=$(uname -r)"
    echo "machine=$(uname -m)"
    echo "podman_version=$(podman --version 2>/dev/null || true)"
    echo "storage_driver=${STORAGE_DRIVER:-}"
    echo "engine_image=$ENGINE_IMAGE"
    echo "image_tar_bytes=${IMAGE_TAR_BYTES:-}"
    echo "apt_seconds=${APT_SECONDS:-}"
    echo "image_load_seconds=${LOAD_SECONDS:-}"
    echo "podman_run_seconds=${RUN_SECONDS:-}"
    echo "total_seconds=${total_seconds}"
    echo "build_rc=${BUILD_RC:-}"
    echo "guest_used_before_kb=${GUEST_USED_BEFORE_KB:-}"
    echo "guest_avail_before_kb=${GUEST_AVAIL_BEFORE_KB:-}"
    echo "guest_used_after_kb=${GUEST_USED_AFTER_KB:-}"
    echo "guest_avail_after_kb=${GUEST_AVAIL_AFTER_KB:-}"
    echo "guest_peak_used_kb=${peak_used_kb}"
    echo "containers_storage_du=${STORAGE_DU:-}"
    echo "rosetta_flags=${ROSETTA_FLAGS:-}"
    echo "artifact_arch=${ARTIFACT_ARCH:-}"
    echo "artifact_boot_mode=${ARTIFACT_BOOT_MODE:-}"
    echo "artifact_packages=${ARTIFACT_PKG_COUNT:-}"
    echo "qcow2_sha256_artifact=${QC_SHA_ARTIFACT:-}"
    echo "qcow2_sha256_actual=${QC_SHA_ACTUAL:-}"
    echo "raw_sha256_artifact=${RAW_SHA_ARTIFACT:-}"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$SUMMARY"
  set -e
}

diagnostics() {
  set +e
  printf '%s\n' '---- E6B diagnostics ----'
  date -u
  echo "--- df -h / /export ---"
  df -h / "$EXPORT_DIR" 2>&1
  echo "--- podman version ---"
  podman --version 2>&1
  echo "--- podman info ---"
  podman info 2>&1
  echo "--- podman images ---"
  podman images 2>&1
  echo "--- podman ps -a ---"
  podman ps -a 2>&1
  echo "--- podman system df ---"
  podman system df 2>&1
  echo "--- storage usage ---"
  du -sh /var/lib/containers/storage 2>&1
  echo "--- rosetta share ---"
  ls -la "$ROSETTA_MOUNT" 2>&1
  echo "--- binfmt rosetta ---"
  cat /proc/sys/fs/binfmt_misc/rosetta 2>&1
  echo "--- export listing ---"
  ls -lh "$EXPORT_DIR" 2>&1
  echo "--- journal tail ---"
  journalctl -n 80 --no-pager 2>&1
  echo "--- dmesg tail ---"
  dmesg 2>/dev/null | tail -n 40
  echo "--- end E6B diagnostics ----"
  set -e
}

fail() {
  local message=$1
  trap - ERR
  set +e
  stop_monitor
  printf 'E6B: FAILED: %s\n' "$message" >&2
  diagnostics
  write_summary "fail"
  exit 1
}

on_err() {
  local status=$1 line=$2 command=$3
  trap - ERR
  set +e
  stop_monitor
  printf 'E6B: FAILED: status=%s line=%s command=%s\n' \
    "$status" "$line" "$command" >&2
  diagnostics
  write_summary "fail"
  exit 1
}

trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

require_file() {
  [ -f "$1" ] || fail "missing $1 (stage it in --out before booting)"
}

install_podman() {
  local start_ns
  log "stage 1/7: install podman, binfmt-support and file"
  start_ns=$(now_ns)
  apt-get -o DPkg::Lock::Timeout=120 update
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y \
    --no-install-recommends podman binfmt-support file
  APT_SECONDS=$(seconds_between "$start_ns" "$(now_ns)")
  # The guest disk is the scarce resource (6 GiB image, ~5 GiB free): drop the
  # package lists and cached .debs before pulling a 500 MB image and building.
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  log "apt install took ${APT_SECONDS}s"
  podman --version
  modprobe overlay || true
  STORAGE_DRIVER=$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || true)
  if [ "$STORAGE_DRIVER" != "overlay" ]; then
    log "podman storage driver is '${STORAGE_DRIVER:-unknown}', not overlay; switching to vfs"
    mkdir -p /etc/containers
    cat >/etc/containers/storage.conf <<'EOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
EOF
    STORAGE_DRIVER=$(podman info --format '{{.Store.GraphDriverName}}' 2>/dev/null || true)
  fi
  log "podman storage driver: ${STORAGE_DRIVER:-unknown}"
}

mount_rosetta() {
  log "stage 2/7: mount the Rosetta virtiofs share and register binfmt"
  mkdir -p "$ROSETTA_MOUNT"
  if mountpoint -q "$ROSETTA_MOUNT"; then
    log "$ROSETTA_MOUNT is already mounted"
  else
    mount -t virtiofs rosetta "$ROSETTA_MOUNT"
  fi
  ls -la "$ROSETTA_MOUNT"
  file "$ROSETTA_BIN"
  [ -x "$ROSETTA_BIN" ] ||
    fail "$ROSETTA_BIN is missing or not executable (was the VM started with --rosetta?)"

  if ! mountpoint -q /proc/sys/fs/binfmt_misc; then
    modprobe binfmt_misc || true
    mkdir -p /proc/sys/fs/binfmt_misc
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc || true
  fi
  mountpoint -q /proc/sys/fs/binfmt_misc ||
    fail "binfmt_misc is not mounted at /proc/sys/fs/binfmt_misc"

  if [ -e /proc/sys/fs/binfmt_misc/rosetta ]; then
    update-binfmts --uninstall rosetta || true
  fi
  update-binfmts --install rosetta "$ROSETTA_BIN" \
    --magic '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00' \
    --mask '\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff' \
    --credentials yes --preserve yes --fix-binary yes

  cat /proc/sys/fs/binfmt_misc/rosetta
  grep -qx 'enabled' /proc/sys/fs/binfmt_misc/rosetta ||
    fail "the binfmt_misc rosetta entry is not enabled"
  ROSETTA_FLAGS=$(awk '/^flags:/ { print $2 }' /proc/sys/fs/binfmt_misc/rosetta)
  log "rosetta binfmt flags: $ROSETTA_FLAGS"
}

load_image() {
  local start_ns
  log "stage 3/7: podman load the amd64 engine image"
  IMAGE_TAR_BYTES=$(stat -c %s "$IMAGE_TAR")
  log "image tar: $IMAGE_TAR ($IMAGE_TAR_BYTES bytes)"
  start_ns=$(now_ns)
  time podman load -i "$IMAGE_TAR"
  LOAD_SECONDS=$(seconds_between "$start_ns" "$(now_ns)")
  log "podman load took ${LOAD_SECONDS}s"
  podman images
  podman image inspect "$ENGINE_IMAGE" --format '{{.Architecture}} {{.Os}} {{.Id}} {{.Size}}'
}

smoke_amd64() {
  log "stage 4/7: smoke-test Rosetta inside podman (uname -m, DNS)"
  local arch rc
  # --network host mirrors the build command and avoids podman's default
  # bridge: netavark is installed, but the trixie package does not pull the
  # `nft` binary, so default-network setup dies with
  #   netavark: nftables error: unable to execute nft: No such file ...
  # Host networking needs no netavark/nft at all (P1-e6b uses --network host).
  set +e
  arch=$(podman run --rm --network host --platform linux/amd64 "$ENGINE_IMAGE" uname -m)
  rc=$?
  set -e
  log "container uname -m: '$arch' (rc=$rc)"
  [ "$rc" -eq 0 ] || fail "podman smoke run failed with rc=$rc"
  [ "$arch" = "x86_64" ] || fail "expected x86_64 from the translated container, got '$arch'"
  if ! podman run --rm --network host --platform linux/amd64 "$ENGINE_IMAGE" bash -c \
    'cat /etc/debian_version; cat /etc/resolv.conf; getent hosts deb.debian.org | head -n 2'; then
    fail "podman smoke DNS check failed (mmdebstrap would not reach the Debian mirror)"
  fi
}

run_engine() {
  local start_ns
  log "stage 5/7: run engine/runtime/container-entry.sh against the x86_64 plan"
  df -h /
  start_ns=$(now_ns)
  set +e
  time podman run \
    --name "$ENGINE_CTR" \
    --privileged \
    --network host \
    --platform linux/amd64 \
    -v /work:/work:ro \
    -v /export:/export \
    "$ENGINE_IMAGE" \
    bash /work/engine/runtime/container-entry.sh \
    --plan "$PLAN" --out /out --export "$EXPORT_DIR" --mode execute
  BUILD_RC=$?
  set -e
  RUN_SECONDS=$(seconds_between "$start_ns" "$(now_ns)")
  log "podman run took ${RUN_SECONDS}s, rc=$BUILD_RC"
}

collect_container_evidence() {
  log "stage 6/7: copy build.log / podman logs and measure storage"
  # container-entry.sh intentionally does not export build.log (the desktop
  # streams build output itself); keep it as spike evidence before removing the
  # container.  Failures are non-fatal: the job log still has the full output.
  podman cp "$ENGINE_CTR:/out/build.log" "$EXPORT_DIR/build.log" 2>/dev/null ||
    log "no container /out/build.log to copy"
  podman logs "$ENGINE_CTR" >"$EXPORT_DIR/podman-container.log" 2>&1 ||
    log "podman logs failed"
  podman inspect "$ENGINE_CTR" >"$EXPORT_DIR/podman-inspect.json" 2>&1 ||
    log "podman inspect failed"
  podman system df >"$EXPORT_DIR/podman-system-df.txt" 2>&1 || true
  STORAGE_DU=$(du -sh /var/lib/containers/storage 2>/dev/null | awk '{ print $1 }')
  log "containers storage: ${STORAGE_DU:-unknown}"
}

validate_artifact() {
  log "stage 7/7: validate exported artifacts"
  local artifact="$EXPORT_DIR/artifact.json"
  [ -s "$artifact" ] || fail "artifact.json was not exported to $EXPORT_DIR"
  [ -s "$EXPORT_DIR/disk.qcow2" ] || fail "disk.qcow2 was not exported to $EXPORT_DIR"
  [ -s "$EXPORT_DIR/disk.img" ] || fail "disk.img was not exported to $EXPORT_DIR"

  set +e
  ARTIFACT_ARCH=$(jq -r '.arch' "$artifact")
  ARTIFACT_BOOT_MODE=$(jq -r '.boot.mode' "$artifact")
  ARTIFACT_PKG_COUNT=$(jq -r '.packages | length' "$artifact")
  QC_SHA_ARTIFACT=$(jq -r '.images[] | select(.path == "disk.qcow2") | .sha256' "$artifact")
  RAW_SHA_ARTIFACT=$(jq -r '.images[] | select(.path == "disk.img") | .sha256' "$artifact")
  set -e

  log "artifact arch=$ARTIFACT_ARCH boot.mode=$ARTIFACT_BOOT_MODE packages=$ARTIFACT_PKG_COUNT"
  [ "$ARTIFACT_ARCH" = "x86_64" ] || fail "artifact arch is '$ARTIFACT_ARCH', expected x86_64"
  [ -n "$QC_SHA_ARTIFACT" ] || fail "artifact.json has no disk.qcow2 sha256"

  log "recomputing disk.qcow2 sha256 over virtiofs (may take a while)"
  set +e
  QC_SHA_ACTUAL=$(sha256sum "$EXPORT_DIR/disk.qcow2" | awk '{ print $1 }')
  set -e
  log "qcow2 sha256 artifact=$QC_SHA_ARTIFACT"
  log "qcow2 sha256 actual  =$QC_SHA_ACTUAL"
  [ "$QC_SHA_ACTUAL" = "$QC_SHA_ARTIFACT" ] || fail "disk.qcow2 sha256 does not match artifact.json"
  ls -lh "$EXPORT_DIR/artifact.json" "$EXPORT_DIR/disk.img" \
    "$EXPORT_DIR/disk.qcow2" "$EXPORT_DIR/build.log" 2>&1 || true
}

cleanup() {
  log "cleanup: remove the build container and check for leftovers"
  podman rm -f "$ENGINE_CTR" >/dev/null 2>&1 || true
  podman ps -a
  df -h /
  GUEST_USED_AFTER_KB=$(df_used_kb)
  GUEST_AVAIL_AFTER_KB=$(df_avail_kb)
  pgrep -af 'podman|conmon|crun' || true
}

main() {
  [ "$(id -u)" -eq 0 ] || fail "this script must run as root in the guest"
  require_file "$IMAGE_TAR"
  require_file "$PLAN"

  log "host: $(uname -a)"
  log "image tar: $(stat -c %s "$IMAGE_TAR") bytes, plan: $PLAN"
  df -h / "$EXPORT_DIR"
  GUEST_USED_BEFORE_KB=$(df_used_kb)
  GUEST_AVAIL_BEFORE_KB=$(df_avail_kb)
  start_monitor

  install_podman
  mount_rosetta
  df -h /
  load_image
  smoke_amd64
  df -h /
  run_engine
  collect_container_evidence

  if [ "$BUILD_RC" -ne 0 ]; then
    log "podman run failed with rc=$BUILD_RC"
    stop_monitor
    diagnostics
    write_summary "fail"
    exit "$BUILD_RC"
  fi

  validate_artifact
  cleanup
  stop_monitor

  GUEST_USED_AFTER_KB=$(df_used_kb)
  GUEST_AVAIL_AFTER_KB=$(df_avail_kb)
  write_summary "pass"
  log "summary: $SUMMARY"
  cat "$SUMMARY"
  log "pass"
  printf 'E6B: pass\n'
}

main "$@"
