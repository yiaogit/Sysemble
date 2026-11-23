#!/usr/bin/env bash
# Sysemble boot-check tests (P0-b kernel mode + P0-c UEFI mode).
#
# Exercises tools/boot-check.sh without QEMU:
#   - offline assertion mode (--log-from) on canned good/bad/empty logs
#   - kernel mode: 3 assertions, -kernel/-initrd argv (P0-b regression)
#   - UEFI mode: 5 assertions, OVMF pflash argv, VARS copy/cleanup, exit 3
#   - artifact validation and usage errors
#   - QEMU availability, fake-QEMU success, fake-QEMU timeout
#
# Every test builds a self-contained artifact fixture in a temp directory.
# Nothing outside the temp directory is written. The suite exits non-zero if
# any test fails.
#
# Requires bash 3.2+ (macOS /bin/bash). Do not use bash 4 features.

set -u

case "$0" in
  */*) TEST_DIR=${0%/*} ;;
  *) TEST_DIR=. ;;
esac
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd -P)
BOOT_CHECK="$REPO_ROOT/tools/boot-check.sh"

if [ -n "${BASH:-}" ] && [ -x "${BASH:-}" ]; then
  BASH_BIN=$BASH
else
  BASH_BIN=/bin/bash
fi

TMP_ROOT=""
CASE_DIR=""
OUT_FILE=""
ERR_FILE=""
RC=0
CASE_NUM=0
PASS_COUNT=0
FAIL_COUNT=0
CASE_NAME=""
CASE_OK=1
JSON_TOOL=""

cleanup() {
  if [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ]; then
    case "$TMP_ROOT" in
      */sysemble-boot-test.*)
        rm -rf "$TMP_ROOT" 2>/dev/null || true
        ;;
    esac
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail_fatal() {
  printf 'boot-check-test: FATAL: %s\n' "$*" >&2
  exit 1
}

if [ ! -f "$BOOT_CHECK" ]; then
  fail_fatal "missing $BOOT_CHECK"
fi

if ! TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sysemble-boot-test.XXXXXX" 2>/dev/null); then
  fail_fatal "cannot create a temporary directory"
fi

if command -v jq >/dev/null 2>&1; then
  JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1; then
  JSON_TOOL=python3
else
  fail_fatal "tests need jq or python3 to inspect evidence JSON"
fi

# ---------------------------------------------------------------------------
# Small test harness
# ---------------------------------------------------------------------------

begin_case() {
  CASE_NUM=$((CASE_NUM + 1))
  CASE_NAME=$1
  CASE_OK=1
  CASE_DIR="$TMP_ROOT/case-$CASE_NUM"
  OUT_FILE="$CASE_DIR/stdout"
  ERR_FILE="$CASE_DIR/stderr"
  mkdir -p "$CASE_DIR"
  printf '\n[%d] %s\n' "$CASE_NUM" "$CASE_NAME"
}

end_case() {
  if [ "$CASE_OK" -eq 1 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS  %s\n' "$CASE_NAME"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf 'FAIL  %s\n' "$CASE_NAME"
  fi
}

check_eq() {
  local label=$1
  local expected=$2
  local actual=$3

  if [ "$expected" = "$actual" ]; then
    printf '  ok    %s == %s\n' "$label" "$expected"
  else
    printf '  FAIL  %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual"
    CASE_OK=0
  fi
}

check_contains() {
  local label=$1
  local needle=$2
  local haystack=$3

  case "$haystack" in
    *"$needle"*)
      printf '  ok    %s contains [%s]\n' "$label" "$needle"
      ;;
    *)
      printf '  FAIL  %s: [%s] not found in:\n%s\n' "$label" "$needle" "$haystack"
      CASE_OK=0
      ;;
  esac
}

check_empty() {
  local label=$1
  local actual=$2

  if [ -z "$actual" ]; then
    printf '  ok    %s is empty\n' "$label"
  else
    printf '  FAIL  %s: expected empty, got [%s]\n' "$label" "$actual"
    CASE_OK=0
  fi
}

check_file() {
  local label=$1
  local path=$2

  if [ -f "$path" ]; then
    printf '  ok    %s exists: %s\n' "$label" "$path"
  else
    printf '  FAIL  %s: missing file %s\n' "$label" "$path"
    CASE_OK=0
  fi
}

check_no_file() {
  local label=$1
  local path=$2

  if [ ! -e "$path" ]; then
    printf '  ok    %s does not exist: %s\n' "$label" "$path"
  else
    printf '  FAIL  %s: unexpected file %s\n' "$label" "$path"
    CASE_OK=0
  fi
}

check_ge() {
  local label=$1
  local minimum=$2
  local actual=$3

  if [ "$actual" -ge "$minimum" ] 2>/dev/null; then
    printf '  ok    %s (%s) >= %s\n' "$label" "$actual" "$minimum"
  else
    printf '  FAIL  %s: expected >= %s, got [%s]\n' "$label" "$minimum" "$actual"
    CASE_OK=0
  fi
}

check_le() {
  local label=$1
  local maximum=$2
  local actual=$3

  if [ "$actual" -le "$maximum" ] 2>/dev/null; then
    printf '  ok    %s (%s) <= %s\n' "$label" "$actual" "$maximum"
  else
    printf '  FAIL  %s: expected <= %s, got [%s]\n' "$label" "$maximum" "$actual"
    CASE_OK=0
  fi
}

invoke_boot_check() {
  RC=0
  "$@" >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

make_fixture() {
  local dir=$1

  mkdir -p "$dir/rootfs/boot"
  : >"$dir/rootfs/boot/vmlinuz-6.12.0-amd64"
  : >"$dir/rootfs/boot/initrd.img-6.12.0-amd64"
  : >"$dir/disk.img"
  : >"$dir/disk.qcow2"

  cat >"$dir/artifact.json" <<'EOF'
{
  "apiVersion": "sysemble/artifact/v1",
  "createdAt": "2026-11-23T12:00:00Z",
  "spec": "minimal-debian",
  "base": {"kind": "debian", "release": "trixie", "pin": "2026-11-01"},
  "arch": "x86_64",
  "packages": ["linux-image-amd64"],
  "rootfs": {"path": "rootfs", "size_mb": 1},
  "images": [
    {"path": "disk.img", "format": "raw", "size_mb": 1, "sha256": "00"},
    {"path": "disk.qcow2", "format": "qcow2", "size_mb": 1, "sha256": "00"}
  ],
  "boot": {
    "kernel": "rootfs/boot/vmlinuz-6.12.0-amd64",
    "initrd": "rootfs/boot/initrd.img-6.12.0-amd64",
    "cmdline": "console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target"
  },
  "builder": {"name": "build.sh", "version": "0.1.0"}
}
EOF
}

write_good_log() {
  cat >"$1" <<'EOF'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Detected virtualization qemu.
[    1.234567] systemd[1]: Reached target Local File Systems.
[    2.345678] Debian GNU/Linux 13 sysemble ttyS0
sysemble login:
EOF
}

write_bad_log() {
  cat >"$1" <<'EOF'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Detected virtualization qemu.
[    1.234567] systemd[1]: Reached target Local File Systems.
EOF
}

write_fake_qemu_good() {
  cat >"$1" <<'EOF'
#!/bin/sh
# Fake qemu: emit a healthy serial log, then exit like a powered-off VM.
cat <<'LOG'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Detected virtualization qemu.
[    1.234567] systemd[1]: Reached target Local File Systems.
[    2.345678] Debian GNU/Linux 13 sysemble ttyS0
sysemble login:
LOG
exit 0
EOF
  chmod +x "$1"
}

write_fake_qemu_hang() {
  cat >"$1" <<'EOF'
#!/bin/sh
# Fake qemu: prove the kernel started, then hang until the boot-check watchdog
# kills this process group.
echo '[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)'
exec sleep 10
EOF
  chmod +x "$1"
}

# UEFI artifact fixture: GPT disk with an ESP, GRUB metadata, and the boot.mode
# contract from docs/plan/P0-c-workplan.md section 4.
make_uefi_fixture() {
  local dir=$1

  make_fixture "$dir"
  mkdir -p "$dir/fw"
  printf 'OVMF-CODE-FIXTURE\n' >"$dir/fw/OVMF_CODE_4M.fd"
  printf 'OVMF-VARS-FIXTURE\n' >"$dir/fw/OVMF_VARS_4M.fd"

  cat >"$dir/artifact.json" <<'EOF'
{
  "apiVersion": "sysemble/artifact/v1",
  "createdAt": "2026-11-23T12:00:00Z",
  "spec": "minimal-debian",
  "base": {"kind": "debian", "release": "trixie", "pin": "2026-11-01"},
  "arch": "x86_64",
  "packages": ["linux-image-amd64", "grub-efi-amd64-bin"],
  "rootfs": {"path": "rootfs", "size_mb": 1},
  "images": [
    {"path": "disk.img", "format": "raw", "size_mb": 1, "sha256": "00"},
    {"path": "disk.qcow2", "format": "qcow2", "size_mb": 1, "sha256": "00"}
  ],
  "boot": {
    "mode": "uefi",
    "disk": "disk.img",
    "kernel": "rootfs/boot/vmlinuz-6.12.0-amd64",
    "initrd": "rootfs/boot/initrd.img-6.12.0-amd64",
    "cmdline": "root=/dev/vda2 rw console=ttyS0 rootfstype=ext4 systemd.unit=multi-user.target",
    "grub": {"efi": "esp/EFI/BOOT/BOOTX64.EFI", "config": "grub.cfg"}
  },
  "partitions": [
    {"index": 1, "role": "esp", "size_mb": 512, "fs": "vfat32"},
    {"index": 2, "role": "root", "size_mb": 3584, "fs": "ext4"}
  ],
  "builder": {"name": "build.sh", "version": "0.1.0"}
}
EOF
}

write_uefi_good_log() {
  cat >"$1" <<'EOF'
[    0.000000] efi: EFI v2.70 by EDK II
GRUB loading..
Booting `Sysemble'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Detected virtualization qemu.
[    1.234567] systemd[1]: Reached target Local File Systems.
[    2.345678] Debian GNU/Linux 13 sysemble ttyS0
sysemble login:
EOF
}

# Same UEFI boot but nothing identifying a bootloader: firmware passed, GRUB
# never produced output.
write_uefi_no_grub_log() {
  cat >"$1" <<'EOF'
[    0.000000] efi: EFI v2.70 by EDK II
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Detected virtualization qemu.
[    1.234567] systemd[1]: Reached target Local File Systems.
[    2.345678] Debian GNU/Linux 13 sysemble ttyS0
sysemble login:
EOF
}

# Fake UEFI qemu: records argv, copies the writable pflash VARS file aside (so
# the test can prove the VARS template reached QEMU), emits a healthy UEFI log,
# then either exits (like a powered-off VM) or keeps running (to prove the
# early-stop monitor).
write_fake_qemu_uefi() {
  local path=$1
  local mode=${2:-exit}

  cat >"$path" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$@" >"$FAKE_QEMU_ARGS"
for arg in "$@"; do
  case "$arg" in
    if=pflash*readonly=on*) ;;
    if=pflash*file=*)
      cp "${arg##*file=}" "$FAKE_QEMU_VARS_COPY" 2>/dev/null || exit 9
      ;;
  esac
done
cat <<'LOG'
[    0.000000] efi: EFI v2.70 by EDK II
GRUB loading..
Booting `Sysemble'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Detected virtualization qemu.
[    1.234567] systemd[1]: Reached target Local File Systems.
[    2.345678] Debian GNU/Linux 13 sysemble ttyS0
sysemble login:
LOG
SCRIPT
  if [ "$mode" = "hang" ]; then
    # A real booted VM never exits; boot-check must stop it after 5 matches.
    printf 'exec sleep 30\n' >>"$path"
  else
    printf 'exit 0\n' >>"$path"
  fi
  chmod +x "$path"
}

# Print the QEMU argv with the random VARS temp name canonicalized, so the full
# pflash/drive sequence can be compared exactly.
normalize_uefi_args() {
  local args_file=$1
  local line=""
  local output=""

  while IFS= read -r line; do
    case "$line" in
      if=pflash,format=raw,file=*) line="if=pflash,format=raw,file=<VARS>" ;;
    esac
    output="$output$line
"
  done <"$args_file"
  printf '%s' "$output"
}

# Print the writable pflash VARS path recorded in the QEMU argv.
find_uefi_vars_arg() {
  local args_file=$1
  local line=""

  while IFS= read -r line; do
    case "$line" in
      if=pflash,format=raw,file=*)
        printf '%s' "${line#*file=}"
        return 0
        ;;
    esac
  done <"$args_file"
  return 1
}

# JSON-backed artifact variants (used to exercise validation errors without
# duplicating the fixture): set or delete a dotted field.
set_artifact_field() {
  local in=$1
  local out=$2
  local path=$3
  local value=$4

  if [ "$JSON_TOOL" = "jq" ]; then
    jq --arg p "$path" --arg v "$value" \
      'setpath(($p | split(".")); $v)' "$in" >"$out" 2>/dev/null
  else
    python3 - "$in" "$out" "$path" "$value" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
node = data
keys = sys.argv[3].split(".")
for key in keys[:-1]:
    node = node[key]
node[keys[-1]] = sys.argv[4]
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
  fi
}

delete_artifact_field() {
  local in=$1
  local out=$2
  local path=$3

  if [ "$JSON_TOOL" = "jq" ]; then
    jq --arg p "$path" 'delpaths([$p | split(".")])' "$in" >"$out" 2>/dev/null
  else
    python3 - "$in" "$out" "$path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
node = data
keys = sys.argv[3].split(".")
for key in keys[:-1]:
    node = node[key]
del node[keys[-1]]
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
PY
  fi
}

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------

json_valid() {
  local file=$1

  if [ "$JSON_TOOL" = "jq" ]; then
    jq -e . "$file" >/dev/null 2>&1
  else
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" >/dev/null 2>&1
  fi
}

json_query() {
  local file=$1
  local key=$2
  local arg=${3:-}

  if [ "$JSON_TOOL" = "jq" ]; then
    case "$key" in
      result) jq -r '.result' "$file" 2>/dev/null ;;
      apiVersion) jq -r '.apiVersion' "$file" 2>/dev/null ;;
      artifact) jq -r '.artifact' "$file" 2>/dev/null ;;
      qemu) jq -r '.qemu' "$file" 2>/dev/null ;;
      timeout_seconds) jq -r '.timeout_seconds' "$file" 2>/dev/null ;;
      elapsed_seconds) jq -r '.elapsed_seconds' "$file" 2>/dev/null ;;
      log) jq -r '.log' "$file" 2>/dev/null ;;
      log_sha256) jq -r '.log_sha256' "$file" 2>/dev/null ;;
      assertion_count) jq -r '.assertions | length' "$file" 2>/dev/null ;;
      assertion_result)
        jq -r --arg id "$arg" '.assertions[] | select(.id == $id) | .result' "$file" 2>/dev/null
        ;;
      assertion_detail)
        jq -r --arg id "$arg" '.assertions[] | select(.id == $id) | .detail' "$file" 2>/dev/null
        ;;
      *)
        return 1
        ;;
    esac
  else
    python3 - "$file" "$key" "$arg" <<'PY'
import json
import sys


def main(argv):
    with open(argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    key = argv[2]
    arg = argv[3] if len(argv) > 3 else ""
    if key == "result":
        print(data["result"])
    elif key == "apiVersion":
        print(data["apiVersion"])
    elif key == "artifact":
        print(data["artifact"])
    elif key == "qemu":
        print(data["qemu"])
    elif key == "timeout_seconds":
        print(data["timeout_seconds"])
    elif key == "elapsed_seconds":
        print(data["elapsed_seconds"])
    elif key == "log":
        print(data["log"])
    elif key == "log_sha256":
        print(data["log_sha256"])
    elif key == "assertion_count":
        print(len(data["assertions"]))
    elif key == "assertion_result":
        for item in data["assertions"]:
            if item["id"] == arg:
                print(item["result"])
                return 0
        return 2
    elif key == "assertion_detail":
        for item in data["assertions"]:
            if item["id"] == arg:
                print(item["detail"])
                return 0
        return 2
    else:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY
  fi
}

file_sha256() {
  local out=""

  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$1" 2>/dev/null) || return 1
    printf '%s' "${out%% *}"
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 "$1" 2>/dev/null) || return 1
    printf '%s' "${out%% *}"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_good_log_offline() {
  local evidence=""
  local stderr_text=""
  local hash=""

  begin_case "canned good log -> exit 0, three passes"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  write_good_log "$CASE_DIR/good.log"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/good.log" --json

  check_eq "exit code" 0 "$RC"
  check_file "evidence file" "$evidence"
  check_no_file "boot.log absent in offline mode" "$CASE_DIR/boot.log"
  check_eq "stdout is valid JSON" 1 "$(json_valid "$OUT_FILE" && echo 1 || echo 0)"
  check_eq "evidence API version" "sysemble/boot-evidence/v1" "$(json_query "$evidence" apiVersion)"
  check_eq "result" "pass" "$(json_query "$evidence" result)"
  check_eq "assertion count" 3 "$(json_query "$evidence" assertion_count)"
  check_eq "boot.kernel" "pass" "$(json_query "$evidence" assertion_result boot.kernel)"
  check_eq "boot.systemd" "pass" "$(json_query "$evidence" assertion_result boot.systemd)"
  check_eq "boot.login" "pass" "$(json_query "$evidence" assertion_result boot.login)"
  check_eq "evidence log" "$CASE_DIR/good.log" "$(json_query "$evidence" log)"
  hash=$(json_query "$evidence" log_sha256)
  check_eq "sha256 length" 64 "${#hash}"
  check_eq "log sha256 matches file" "$(file_sha256 "$CASE_DIR/good.log")" "$hash"
  stderr_text=$(cat "$ERR_FILE")
  check_contains "human summary on stderr" "result: pass" "$stderr_text"
  end_case
}

test_bad_log_offline() {
  local evidence=""

  begin_case "canned bad log (no login) -> exit 1, login fail, valid evidence"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  write_bad_log "$CASE_DIR/bad.log"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/bad.log" --json

  check_eq "exit code" 1 "$RC"
  check_file "evidence file" "$evidence"
  check_eq "stdout is valid JSON" 1 "$(json_valid "$OUT_FILE" && echo 1 || echo 0)"
  check_eq "result" "fail" "$(json_query "$evidence" result)"
  check_eq "boot.kernel" "pass" "$(json_query "$evidence" assertion_result boot.kernel)"
  check_eq "boot.systemd" "pass" "$(json_query "$evidence" assertion_result boot.systemd)"
  check_eq "boot.login" "fail" "$(json_query "$evidence" assertion_result boot.login)"
  check_contains "login detail" "no \`login:\`" "$(json_query "$evidence" assertion_detail boot.login)"
  end_case
}

test_missing_log_from() {
  begin_case "--log-from missing file -> exit 2"
  make_fixture "$CASE_DIR"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/does-not-exist.log" --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic" "log-from file not found" "$(cat "$ERR_FILE")"
  check_no_file "no evidence on I/O error" "$CASE_DIR/boot-evidence.json"
  end_case
}

test_missing_artifact_argument() {
  begin_case "--artifact missing -> exit 2, usage"
  make_fixture "$CASE_DIR"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic" "--artifact is required" "$(cat "$ERR_FILE")"
  check_contains "usage shown" "Usage:" "$(cat "$ERR_FILE")"
  end_case
}

test_qemu_unavailable() {
  begin_case "PATH cleared + --qemu /nonexistent -> exit 3"
  make_fixture "$CASE_DIR"

  RC=0
  PATH=/nonexistent "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --qemu /nonexistent --json >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?

  check_eq "exit code" 3 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic" "QEMU binary is not executable" "$(cat "$ERR_FILE")"
  check_no_file "no boot.log" "$CASE_DIR/boot.log"
  check_no_file "no evidence" "$CASE_DIR/boot-evidence.json"
  end_case
}

test_fake_qemu_good() {
  local evidence=""

  begin_case "fake qemu writes good log then exits -> exit 0, boot.log"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  write_fake_qemu_good "$CASE_DIR/fake-qemu"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" --timeout 10 --json

  check_eq "exit code" 0 "$RC"
  check_file "boot.log" "$CASE_DIR/boot.log"
  check_file "evidence file" "$evidence"
  check_eq "stdout is valid JSON" 1 "$(json_valid "$OUT_FILE" && echo 1 || echo 0)"
  check_eq "result" "pass" "$(json_query "$evidence" result)"
  check_eq "assertion count" 3 "$(json_query "$evidence" assertion_count)"
  check_eq "boot.kernel" "pass" "$(json_query "$evidence" assertion_result boot.kernel)"
  check_eq "boot.login" "pass" "$(json_query "$evidence" assertion_result boot.login)"
  check_eq "evidence log" "boot.log" "$(json_query "$evidence" log)"
  check_eq "boot.log sha256 matches evidence" "$(file_sha256 "$CASE_DIR/boot.log")" "$(json_query "$evidence" log_sha256)"
  check_contains "boot.log has kernel line" "Linux version" "$(cat "$CASE_DIR/boot.log")"
  end_case
}

test_qemu_arguments() {
  local evidence=""
  local args_file=""
  local expected=""
  local actual=""
  local real_case_dir=""

  begin_case "QEMU argv maps artifact fields and resolves paths"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  args_file="$CASE_DIR/qemu-args.txt"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)

  cat >"$CASE_DIR/fake-qemu" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$FAKE_QEMU_ARGS"
cat <<'LOG'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Detected virtualization qemu.
[    1.234567] systemd[1]: Reached target Local File Systems.
[    2.345678] Debian GNU/Linux 13 sysemble ttyS0
sysemble login:
LOG
exit 0
EOF
  chmod +x "$CASE_DIR/fake-qemu"

  expected=$(printf '%s\n' \
    '-machine' 'q35' \
    '-m' '1024' \
    '-smp' '2' \
    '-nographic' \
    '-no-reboot' \
    '-kernel' "$real_case_dir/rootfs/boot/vmlinuz-6.12.0-amd64" \
    '-initrd' "$real_case_dir/rootfs/boot/initrd.img-6.12.0-amd64" \
    '-append' 'console=ttyS0 root=/dev/vda rw rootfstype=ext4 systemd.unit=multi-user.target' \
    '-drive' "file=$real_case_dir/disk.img,format=raw,if=virtio")

  RC=0
  FAKE_QEMU_ARGS="$args_file" "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" --timeout 10 --json \
    >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?

  actual=$(cat "$args_file" 2>/dev/null)
  check_eq "exit code" 0 "$RC"
  check_eq "qemu argv" "$expected" "$actual"
  check_eq "result" "pass" "$(json_query "$evidence" result)"
  end_case
}

test_early_stop_after_assertions() {
  local evidence=""
  local duration=0

  begin_case "fake qemu keeps running after good log -> early stop, exit 0"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"

  cat >"$CASE_DIR/fake-qemu" <<'EOF'
#!/bin/sh
cat <<'LOG'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Detected virtualization qemu.
[    1.234567] systemd[1]: Reached target Local File Systems.
[    2.345678] Debian GNU/Linux 13 sysemble ttyS0
sysemble login:
LOG
# A real booted VM never exits. Boot-check must notice all assertions and stop
# this process instead of waiting for the timeout.
exec sleep 30
EOF
  chmod +x "$CASE_DIR/fake-qemu"

  SECONDS=0
  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" --timeout 5 --json
  duration=$SECONDS

  check_eq "exit code" 0 "$RC"
  check_eq "result" "pass" "$(json_query "$evidence" result)"
  check_eq "all assertions" "pass" "$(json_query "$evidence" assertion_result boot.login)"
  check_le "wall clock duration" 4 "$duration"
  end_case
}

test_fake_qemu_timeout() {
  local evidence=""
  local duration=0

  begin_case "fake qemu hangs with --timeout 2 -> exit 4, partial log kept"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  write_fake_qemu_hang "$CASE_DIR/fake-qemu"

  SECONDS=0
  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" --timeout 2 --json
  duration=$SECONDS

  check_eq "exit code" 4 "$RC"
  check_file "boot.log" "$CASE_DIR/boot.log"
  check_file "evidence file" "$evidence"
  check_eq "stdout is valid JSON" 1 "$(json_valid "$OUT_FILE" && echo 1 || echo 0)"
  check_eq "result" "timeout" "$(json_query "$evidence" result)"
  check_eq "timeout_seconds" 2 "$(json_query "$evidence" timeout_seconds)"
  check_ge "elapsed_seconds" 2 "$(json_query "$evidence" elapsed_seconds)"
  check_ge "wall clock duration" 2 "$duration"
  check_ge "partial log preserved" 1 "$(wc -c <"$CASE_DIR/boot.log" | tr -d ' ')"
  check_eq "boot.kernel on partial log" "pass" "$(json_query "$evidence" assertion_result boot.kernel)"
  check_eq "boot.login on partial log" "fail" "$(json_query "$evidence" assertion_result boot.login)"
  check_contains "login detail mentions timeout" "within 2s" "$(json_query "$evidence" assertion_detail boot.login)"
  end_case
}

test_empty_log_offline() {
  local evidence=""

  begin_case "empty log -> assertions fail (exit 1), not error"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  : >"$CASE_DIR/empty.log"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/empty.log" --json

  check_eq "exit code" 1 "$RC"
  check_file "evidence file" "$evidence"
  check_eq "result" "fail" "$(json_query "$evidence" result)"
  check_eq "boot.kernel" "fail" "$(json_query "$evidence" assertion_result boot.kernel)"
  check_eq "boot.systemd" "fail" "$(json_query "$evidence" assertion_result boot.systemd)"
  check_eq "boot.login" "fail" "$(json_query "$evidence" assertion_result boot.login)"
  check_contains "empty detail" "log is empty" "$(json_query "$evidence" assertion_detail boot.kernel)"
  end_case
}

test_offline_ignores_qemu() {
  begin_case "offline mode does not require QEMU"
  make_fixture "$CASE_DIR"
  write_good_log "$CASE_DIR/good.log"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/good.log" \
    --qemu /nonexistent --json

  check_eq "exit code" 0 "$RC"
  check_eq "result" "pass" "$(json_query "$CASE_DIR/boot-evidence.json" result)"
  check_no_file "boot.log absent in offline mode" "$CASE_DIR/boot.log"
  end_case
}

test_missing_raw_image() {
  begin_case "missing raw image -> exit 2"
  make_fixture "$CASE_DIR"
  write_good_log "$CASE_DIR/good.log"
  rm -f "$CASE_DIR/disk.img"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/good.log" --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic" "images[].path (raw)" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$CASE_DIR/boot-evidence.json"
  end_case
}

test_missing_kernel() {
  begin_case "missing boot.kernel target -> exit 2"
  make_fixture "$CASE_DIR"
  write_good_log "$CASE_DIR/good.log"
  rm -f "$CASE_DIR/rootfs/boot/vmlinuz-6.12.0-amd64"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/good.log" --json

  check_eq "exit code" 2 "$RC"
  check_contains "diagnostic" "boot.kernel" "$(cat "$ERR_FILE")"
  end_case
}

test_invalid_json() {
  begin_case "malformed artifact JSON -> exit 2"
  make_fixture "$CASE_DIR"
  printf '{ this is not json\n' >"$CASE_DIR/artifact.json"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/whatever.log" --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic" "not valid JSON" "$(cat "$ERR_FILE")"
  end_case
}

test_unknown_option() {
  begin_case "unknown option -> exit 2"
  make_fixture "$CASE_DIR"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" --frobnicate

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic" "unknown option" "$(cat "$ERR_FILE")"
  end_case
}

test_systemd_reached_target_only() {
  begin_case "systemd assertion accepts 'Reached target' alone"
  make_fixture "$CASE_DIR"
  cat >"$CASE_DIR/reached.log" <<'EOF'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    1.234567] Reached target Local File Systems.
sysemble login:
EOF

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/reached.log" --json

  check_eq "exit code" 0 "$RC"
  check_eq "result" "pass" "$(json_query "$CASE_DIR/boot-evidence.json" result)"
  check_eq "boot.systemd" "pass" "$(json_query "$CASE_DIR/boot-evidence.json" assertion_result boot.systemd)"
  end_case
}

# ---------------------------------------------------------------------------
# UEFI mode (P0-c)
# ---------------------------------------------------------------------------

test_uefi_good_log_offline() {
  local evidence=""
  local stderr_text=""
  local hash=""

  begin_case "UEFI canned good log -> exit 0, five passes"
  make_uefi_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  write_uefi_good_log "$CASE_DIR/good-uefi.log"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/good-uefi.log" --json

  check_eq "exit code" 0 "$RC"
  check_file "evidence file" "$evidence"
  check_no_file "boot.log absent in offline mode" "$CASE_DIR/boot.log"
  check_eq "stdout is valid JSON" 1 "$(json_valid "$OUT_FILE" && echo 1 || echo 0)"
  check_eq "evidence API version" "sysemble/boot-evidence/v1" "$(json_query "$evidence" apiVersion)"
  check_eq "result" "pass" "$(json_query "$evidence" result)"
  check_eq "assertion count" 5 "$(json_query "$evidence" assertion_count)"
  check_eq "boot.firmware" "pass" "$(json_query "$evidence" assertion_result boot.firmware)"
  check_eq "boot.grub" "pass" "$(json_query "$evidence" assertion_result boot.grub)"
  check_eq "boot.kernel" "pass" "$(json_query "$evidence" assertion_result boot.kernel)"
  check_eq "boot.systemd" "pass" "$(json_query "$evidence" assertion_result boot.systemd)"
  check_eq "boot.login" "pass" "$(json_query "$evidence" assertion_result boot.login)"
  check_contains "firmware detail" 'matched `EFI v`' "$(json_query "$evidence" assertion_detail boot.firmware)"
  hash=$(json_query "$evidence" log_sha256)
  check_eq "log sha256 matches file" "$(file_sha256 "$CASE_DIR/good-uefi.log")" "$hash"
  stderr_text=$(cat "$ERR_FILE")
  check_contains "human summary on stderr" "boot.firmware: pass" "$stderr_text"
  check_contains "boot mode summary" "boot mode: uefi" "$stderr_text"
  end_case
}

test_uefi_missing_grub_offline() {
  local evidence=""

  begin_case "UEFI log without GRUB -> boot.grub fail, exit 1"
  make_uefi_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  write_uefi_no_grub_log "$CASE_DIR/no-grub.log"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/no-grub.log" --json

  check_eq "exit code" 1 "$RC"
  check_eq "result" "fail" "$(json_query "$evidence" result)"
  check_eq "assertion count" 5 "$(json_query "$evidence" assertion_count)"
  check_eq "boot.firmware" "pass" "$(json_query "$evidence" assertion_result boot.firmware)"
  check_eq "boot.grub" "fail" "$(json_query "$evidence" assertion_result boot.grub)"
  check_contains "grub detail" 'no `GRUB` or `Booting`' "$(json_query "$evidence" assertion_detail boot.grub)"
  check_eq "boot.kernel still evaluated" "pass" "$(json_query "$evidence" assertion_result boot.kernel)"
  check_eq "boot.login still evaluated" "pass" "$(json_query "$evidence" assertion_result boot.login)"
  end_case
}

test_uefi_firmware_missing() {
  local args_file=""

  begin_case "UEFI --firmware /nonexistent -> exit 3, QEMU never launched"
  make_uefi_fixture "$CASE_DIR"
  args_file="$CASE_DIR/qemu-args.txt"
  write_fake_qemu_uefi "$CASE_DIR/fake-qemu"

  # An explicit --firmware takes precedence over the auto-probe, so this is
  # independent of whether the host has /usr/share/OVMF installed.
  RC=0
  FAKE_QEMU_ARGS="$args_file" FAKE_QEMU_VARS_COPY="$CASE_DIR/vars-copy.bin" \
    "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" --firmware /nonexistent --timeout 10 --json \
    >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?

  check_eq "exit code" 3 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic" "OVMF firmware not found or not readable" "$(cat "$ERR_FILE")"
  check_contains "actionable hint" "pass --firmware" "$(cat "$ERR_FILE")"
  check_no_file "no boot.log" "$CASE_DIR/boot.log"
  check_no_file "no evidence" "$CASE_DIR/boot-evidence.json"
  check_no_file "QEMU was not launched" "$args_file"
  end_case
}

test_uefi_qemu_arguments() {
  local evidence=""
  local args_file=""
  local vars_copy=""
  local expected=""
  local actual=""
  local real_case_dir=""
  local vars_path=""
  local duration=0

  begin_case "UEFI argv: q35 + two pflash drives + virtio disk, early stop"
  make_uefi_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  args_file="$CASE_DIR/qemu-args.txt"
  vars_copy="$CASE_DIR/vars-copy.bin"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  write_fake_qemu_uefi "$CASE_DIR/fake-qemu" hang

  expected=$(printf '%s\n' \
    '-machine' 'q35' \
    '-m' '1024' \
    '-smp' '2' \
    '-nographic' \
    '-no-reboot' \
    '-drive' "if=pflash,format=raw,readonly=on,file=$real_case_dir/fw/OVMF_CODE_4M.fd" \
    '-drive' 'if=pflash,format=raw,file=<VARS>' \
    '-drive' "file=$real_case_dir/disk.img,format=raw,if=virtio")

  SECONDS=0
  RC=0
  FAKE_QEMU_ARGS="$args_file" FAKE_QEMU_VARS_COPY="$vars_copy" \
    "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" --firmware "$real_case_dir/fw/OVMF_CODE_4M.fd" \
    --timeout 10 --json >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
  duration=$SECONDS

  actual=$(normalize_uefi_args "$args_file")
  check_eq "exit code" 0 "$RC"
  check_eq "qemu argv" "$expected" "$actual"
  # Well below the 10s timeout (the fake qemu would sleep 30s): proves the
  # UEFI assertion set triggers the same early-stop monitor as kernel mode.
  check_le "early stop duration" 6 "$duration"
  check_eq "result" "pass" "$(json_query "$evidence" result)"
  check_eq "assertion count" 5 "$(json_query "$evidence" assertion_count)"
  check_eq "boot.firmware" "pass" "$(json_query "$evidence" assertion_result boot.firmware)"
  check_eq "boot.grub" "pass" "$(json_query "$evidence" assertion_result boot.grub)"
  check_eq "evidence log" "boot.log" "$(json_query "$evidence" log)"
  check_eq "no -kernel flag" 0 "$(grep -c '^-kernel$' "$args_file" || true)"
  check_eq "no -initrd flag" 0 "$(grep -c '^-initrd$' "$args_file" || true)"
  check_eq "no -append flag" 0 "$(grep -c '^-append$' "$args_file" || true)"
  check_eq "VARS template copied for QEMU" "OVMF-VARS-FIXTURE" "$(cat "$vars_copy" 2>/dev/null)"
  vars_path=$(find_uefi_vars_arg "$args_file")
  check_contains "VARS copy in boot-check temp dir" "/sysemble-boot." "$vars_path"
  check_contains "VARS copy under TMPDIR" "${TMPDIR:-/tmp}" "$vars_path"
  check_no_file "VARS copy removed on exit" "$vars_path"
  check_eq "no VARS temp in artifact dir" 0 "$(ls -A "$real_case_dir" | grep -c '^\.sysemble-ovmf-vars\.' || true)"
  end_case
}

test_uefi_vars_name_fallback() {
  local args_file=""
  local vars_copy=""
  local vars_path=""
  local real_case_dir=""

  begin_case "UEFI VARS fallback: OVMF_CODE.fd uses OVMF_VARS.fd"
  make_uefi_fixture "$CASE_DIR"
  rm -f "$CASE_DIR/fw/OVMF_CODE_4M.fd" "$CASE_DIR/fw/OVMF_VARS_4M.fd"
  printf 'OVMF-CODE-PLAIN\n' >"$CASE_DIR/fw/OVMF_CODE.fd"
  printf 'OVMF-VARS-PLAIN\n' >"$CASE_DIR/fw/OVMF_VARS.fd"
  args_file="$CASE_DIR/qemu-args.txt"
  vars_copy="$CASE_DIR/vars-copy.bin"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  write_fake_qemu_uefi "$CASE_DIR/fake-qemu"

  RC=0
  FAKE_QEMU_ARGS="$args_file" FAKE_QEMU_VARS_COPY="$vars_copy" \
    "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" --firmware "$real_case_dir/fw/OVMF_CODE.fd" \
    --timeout 10 --json >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?

  check_eq "exit code" 0 "$RC"
  check_contains "plain CODE used" "readonly=on,file=$real_case_dir/fw/OVMF_CODE.fd" "$(cat "$args_file" 2>/dev/null)"
  check_eq "plain VARS copied for QEMU" "OVMF-VARS-PLAIN" "$(cat "$vars_copy" 2>/dev/null)"
  vars_path=$(find_uefi_vars_arg "$args_file")
  check_no_file "VARS copy removed on exit" "$vars_path"
  end_case
}

test_uefi_missing_disk() {
  begin_case "UEFI artifact without boot.disk -> exit 2"
  make_uefi_fixture "$CASE_DIR"
  write_uefi_good_log "$CASE_DIR/good-uefi.log"
  delete_artifact_field "$CASE_DIR/artifact.json" "$CASE_DIR/no-disk.json" "boot.disk"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/no-disk.json" \
    --log-from "$CASE_DIR/good-uefi.log" --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic" "boot.disk is required when boot.mode=uefi" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$CASE_DIR/boot-evidence.json"
  end_case
}

test_unknown_boot_mode() {
  begin_case "unknown boot.mode -> exit 2"
  make_uefi_fixture "$CASE_DIR"
  write_uefi_good_log "$CASE_DIR/good-uefi.log"
  set_artifact_field "$CASE_DIR/artifact.json" "$CASE_DIR/bios.json" "boot.mode" "bios"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/bios.json" \
    --log-from "$CASE_DIR/good-uefi.log" --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic" "must be 'kernel' or 'uefi'" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$CASE_DIR/boot-evidence.json"
  end_case
}

test_kernel_mode_assertions_unchanged() {
  local evidence=""

  begin_case "kernel mode stays at 3 assertions and ignores --firmware"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  write_good_log "$CASE_DIR/good.log"

  invoke_boot_check "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --log-from "$CASE_DIR/good.log" --firmware /nonexistent --json

  check_eq "exit code" 0 "$RC"
  check_eq "result" "pass" "$(json_query "$evidence" result)"
  check_eq "assertion count" 3 "$(json_query "$evidence" assertion_count)"
  check_empty "no boot.firmware assertion" "$(json_query "$evidence" assertion_result boot.firmware)"
  check_empty "no boot.grub assertion" "$(json_query "$evidence" assertion_result boot.grub)"
  check_contains "firmware warning" "ignoring --firmware" "$(cat "$ERR_FILE")"
  end_case
}

test_uefi_timeout() {
  local evidence=""
  local duration=0
  local args_file=""
  local vars_path=""

  begin_case "UEFI fake qemu emits firmware then hangs -> exit 4, partial log"
  make_uefi_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  args_file="$CASE_DIR/qemu-args.txt"

  cat >"$CASE_DIR/fake-qemu" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$FAKE_QEMU_ARGS"
echo '[    0.000000] efi: EFI v2.70 by EDK II'
exec sleep 10
EOF
  chmod +x "$CASE_DIR/fake-qemu"

  SECONDS=0
  RC=0
  FAKE_QEMU_ARGS="$args_file" "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" --timeout 2 --json \
    >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
  duration=$SECONDS

  check_eq "exit code" 4 "$RC"
  check_eq "result" "timeout" "$(json_query "$evidence" result)"
  check_eq "assertion count" 5 "$(json_query "$evidence" assertion_count)"
  check_eq "boot.firmware on partial log" "pass" "$(json_query "$evidence" assertion_result boot.firmware)"
  check_eq "boot.grub on partial log" "fail" "$(json_query "$evidence" assertion_result boot.grub)"
  check_contains "grub detail mentions timeout" "within 2s" "$(json_query "$evidence" assertion_detail boot.grub)"
  check_ge "wall clock duration" 2 "$duration"
  vars_path=$(find_uefi_vars_arg "$args_file")
  check_no_file "VARS copy removed after timeout" "$vars_path"
  end_case
}

test_uefi_failure_cleanup() {
  local evidence=""
  local args_file=""
  local vars_copy=""
  local vars_path=""
  local real_case_dir=""

  begin_case "UEFI assertion failure -> exit 1, VARS temp still cleaned"
  make_uefi_fixture "$CASE_DIR"
  evidence="$CASE_DIR/boot-evidence.json"
  args_file="$CASE_DIR/qemu-args.txt"
  vars_copy="$CASE_DIR/vars-copy.bin"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)

  # Firmware + kernel + systemd, but no GRUB output and no login prompt: the
  # boot is not proven, so boot-check must exit 1 after cleaning up.
  cat >"$CASE_DIR/fake-qemu" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$FAKE_QEMU_ARGS"
for arg in "$@"; do
  case "$arg" in
    if=pflash*readonly=on*) ;;
    if=pflash*file=*)
      cp "${arg##*file=}" "$FAKE_QEMU_VARS_COPY" 2>/dev/null || exit 9
      ;;
  esac
done
echo '[    0.000000] efi: EFI v2.70 by EDK II'
echo '[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)'
echo '[    1.234567] systemd[1]: Reached target Local File Systems.'
exit 0
EOF
  chmod +x "$CASE_DIR/fake-qemu"

  RC=0
  FAKE_QEMU_ARGS="$args_file" FAKE_QEMU_VARS_COPY="$vars_copy" \
    "$BASH_BIN" "$BOOT_CHECK" \
    --artifact "$CASE_DIR/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" --firmware "$real_case_dir/fw/OVMF_CODE_4M.fd" \
    --timeout 10 --json >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?

  check_eq "exit code" 1 "$RC"
  check_eq "result" "fail" "$(json_query "$evidence" result)"
  check_eq "boot.grub" "fail" "$(json_query "$evidence" assertion_result boot.grub)"
  check_eq "boot.login" "fail" "$(json_query "$evidence" assertion_result boot.login)"
  vars_path=$(find_uefi_vars_arg "$args_file")
  check_no_file "VARS copy removed after assertion failure" "$vars_path"
  check_eq "no VARS temp in artifact dir" 0 "$(ls -A "$real_case_dir" | grep -c '^\.sysemble-ovmf-vars\.' || true)"
  end_case
}

# Runs last: every offline/QEMU path above has had a chance to leak. boot-check
# must keep its OVMF VARS copy under $TMPDIR, never in the caller's working
# directory (the repo root when this suite runs from there).
test_repo_root_has_no_leftovers() {
  local leftovers=""

  begin_case "repo root has no .sysemble-* temporary leftovers"
  leftovers=$(ls -A "$REPO_ROOT" 2>/dev/null | grep '^\.sysemble-' || true)
  check_empty "repo root .sysemble-* files" "$leftovers"
  end_case
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

printf 'Sysemble boot-check tests\n'
printf '  repo: %s\n' "$REPO_ROOT"
printf '  bash: %s\n' "$BASH_BIN"
printf '  json: %s\n' "$JSON_TOOL"

test_good_log_offline
test_bad_log_offline
test_missing_log_from
test_missing_artifact_argument
test_qemu_unavailable
test_fake_qemu_good
test_qemu_arguments
test_early_stop_after_assertions
test_fake_qemu_timeout
test_empty_log_offline
test_offline_ignores_qemu
test_missing_raw_image
test_missing_kernel
test_invalid_json
test_unknown_option
test_systemd_reached_target_only

test_uefi_good_log_offline
test_uefi_missing_grub_offline
test_uefi_firmware_missing
test_uefi_qemu_arguments
test_uefi_vars_name_fallback
test_uefi_missing_disk
test_unknown_boot_mode
test_kernel_mode_assertions_unchanged
test_uefi_timeout
test_uefi_failure_cleanup
test_repo_root_has_no_leftovers

printf '\n----------------------------------------------------------------\n'
printf 'Summary: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -ne 0 ] || [ "$PASS_COUNT" -eq 0 ]; then
  exit 1
fi
exit 0
