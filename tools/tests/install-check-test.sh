#!/usr/bin/env bash
# Sysemble install-check tests (P0-d3).
#
# Exercises tools/install-check.sh without QEMU or OVMF:
#   - success: fake QEMU prints the install marker, the installed disk is 6 GiB,
#     the exact QEMU argv is checked, boot-check is invoked with a generated
#     mode=uefi artifact, and both evidence phases pass
#   - install timeout (exit 4, install.log kept)
#   - install failed marker (exit 1, reason recorded, boot-check not invoked)
#   - post-install boot failure (exit 1, phases.boot=fail, assertions merged)
#   - post-install boot timeout (exit 1, phases.boot.result=timeout)
#   - early QEMU exit before the marker (exit 1)
#   - artifact validation: missing boot.iso field/file, non-install mode,
#     invalid memory_mb (exit 2)
#   - missing QEMU (exit 3)
#   - work-directory contract: auto mktemp dir removed, --workdir retained
#   - --json stdout carries only install-evidence.json
#
# Every test builds a self-contained fixture under a temp directory. Nothing
# outside the temp directory is written and the repo root is checked for
# leftovers at the end.
#
# Requires bash 3.2+ (macOS /bin/bash). Do not use bash 4 features.

set -u

case "$0" in
  */*) TEST_DIR=${0%/*} ;;
  *) TEST_DIR=. ;;
esac
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd -P)
INSTALL_CHECK="$REPO_ROOT/tools/install-check.sh"

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
      */sysemble-install-test.*)
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
  printf 'install-check-test: FATAL: %s\n' "$*" >&2
  exit 1
}

if [ ! -f "$INSTALL_CHECK" ]; then
  fail_fatal "missing $INSTALL_CHECK"
fi

if ! TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sysemble-install-test.XXXXXX" 2>/dev/null); then
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

invoke_install_check() {
  RC=0
  "$@" >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
}

# ---------------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------------

json_valid() {
  local file=$1

  if [ "$JSON_TOOL" = "jq" ]; then
    jq -e . "$file" >/dev/null 2>&1
  else
    python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$file" >/dev/null 2>&1
  fi
}

# Query a fixed set of keys from install-evidence.json.
json_query() {
  local file=$1
  local key=$2
  local arg=${3:-}

  if [ "$JSON_TOOL" = "jq" ]; then
    case "$key" in
      apiVersion) jq -r '.apiVersion // ""' "$file" 2>/dev/null ;;
      result) jq -r '.result // ""' "$file" 2>/dev/null ;;
      install_result) jq -r '.phases.install.result // ""' "$file" 2>/dev/null ;;
      install_marker) jq -r '.phases.install.marker // ""' "$file" 2>/dev/null ;;
      install_error) jq -r '.phases.install.error // ""' "$file" 2>/dev/null ;;
      boot_has) jq -r '.phases | has("boot")' "$file" 2>/dev/null ;;
      boot_result) jq -r '.phases.boot.result // ""' "$file" 2>/dev/null ;;
      boot_error) jq -r '.phases.boot.error // ""' "$file" 2>/dev/null ;;
      boot_assertion_count)
        jq -r '(.phases.boot.assertions // []) | length' "$file" 2>/dev/null
        ;;
      boot_assertion_ids)
        jq -r '(.phases.boot.assertions // []) | map(.id) | join(",")' "$file" 2>/dev/null
        ;;
      boot_assertion_result)
        jq -r --arg id "$arg" \
          '(.phases.boot.assertions // [])[] | select(.id == $id) | .result' \
          "$file" 2>/dev/null
        ;;
      boot_assertion_detail)
        jq -r --arg id "$arg" \
          '(.phases.boot.assertions // [])[] | select(.id == $id) | .detail' \
          "$file" 2>/dev/null
        ;;
      *) return 1 ;;
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
    phases = data.get("phases", {})
    install = phases.get("install", {})
    boot = phases.get("boot", {})
    assertions = boot.get("assertions", []) if isinstance(boot, dict) else []
    if key == "apiVersion":
        print(data.get("apiVersion", ""))
    elif key == "result":
        print(data.get("result", ""))
    elif key == "install_result":
        print(install.get("result", ""))
    elif key == "install_marker":
        print(install.get("marker", ""))
    elif key == "install_error":
        print(install.get("error", ""))
    elif key == "boot_has":
        print("true" if "boot" in phases else "false")
    elif key == "boot_result":
        print(boot.get("result", "") if isinstance(boot, dict) else "")
    elif key == "boot_error":
        print(boot.get("error", "") if isinstance(boot, dict) else "")
    elif key == "boot_assertion_count":
        print(len(assertions))
    elif key == "boot_assertion_ids":
        print(",".join(item.get("id", "") for item in assertions))
    elif key == "boot_assertion_result":
        for item in assertions:
            if item.get("id") == arg:
                print(item.get("result", ""))
                return 0
        return 2
    elif key == "boot_assertion_detail":
        for item in assertions:
            if item.get("id") == arg:
                print(item.get("detail", ""))
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

# Read one dotted field from any JSON file (numeric segments index arrays).
json_field() {
  local file=$1
  local path=$2

  if [ "$JSON_TOOL" = "jq" ]; then
    jq -r --arg p "$path" \
      'getpath($p | split(".") | map(if test("^[0-9]+$") then tonumber else . end))' \
      "$file" 2>/dev/null
  else
    python3 - "$file" "$path" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    value = json.load(fh)
for key in sys.argv[2].split("."):
    if isinstance(value, list):
        value = value[int(key)]
    else:
        value = value[key]
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("null")
else:
    print(value)
PY
  fi
}

file_size() {
  local file=$1

  if stat -c %s "$file" >/dev/null 2>&1; then
    stat -c %s "$file"
  else
    stat -f %z "$file"
  fi
}

arg_after() {
  local file=$1
  local flag=$2

  awk -v want="$flag" '$0 == want { getline; print; exit }' "$file"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

make_fixture() {
  local dir=$1

  mkdir -p "$dir/out" "$dir/fw"
  : >"$dir/out/live.iso"
  printf 'OVMF-CODE-FIXTURE\n' >"$dir/fw/OVMF_CODE_4M.fd"
  printf 'OVMF-VARS-FIXTURE\n' >"$dir/fw/OVMF_VARS_4M.fd"

  cat >"$dir/out/artifact.json" <<'EOF'
{
  "apiVersion": "sysemble/artifact/v1",
  "createdAt": "2026-11-23T12:00:00Z",
  "spec": "minimal-debian-live",
  "base": {"kind": "debian", "release": "trixie", "pin": "2026-11-01"},
  "arch": "x86_64",
  "packages": ["linux-image-amd64", "live-boot", "rsync", "grub-efi-amd64"],
  "images": [
    {"path": "live.iso", "format": "iso", "size_mb": 780, "sha256": "00"}
  ],
  "boot": {
    "mode": "install",
    "iso": "live.iso",
    "install_device": "/dev/vda",
    "cmdline": "boot=live live-media-path=/live console=ttyS0 sysemble.install=/dev/vda",
    "memory_mb": 1024
  },
  "builder": {"name": "build.sh", "version": "0.1.0"}
}
EOF
}

write_fake_qemu() {
  local path=$1
  local mode=$2

  cat >"$path" <<'SCRIPT'
#!/bin/sh
if [ -n "${FAKE_QEMU_ARGS:-}" ]; then
  printf '%s\n' "$@" >"$FAKE_QEMU_ARGS"
fi
SCRIPT

  case "$mode" in
    success)
      cat >>"$path" <<'SCRIPT'
cat <<'LOG'
[    0.000000] efi: EFI v2.70 by EDK II
GRUB loading..
Booting `Sysemble Installer'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Reached target Multi-User System.
SYMBLE: install complete
LOG
# A real installer powers off, but a booted VM may linger; install-check must
# stop this process as soon as the marker is seen.
exec sleep 30
SCRIPT
      ;;
    timeout)
      cat >>"$path" <<'SCRIPT'
echo '[    0.000000] efi: EFI v2.70 by EDK II'
echo 'installer booting, no completion marker yet'
exec sleep 30
SCRIPT
      ;;
    failed)
      cat >>"$path" <<'SCRIPT'
echo '[    0.000000] efi: EFI v2.70 by EDK II'
echo 'grub-install: error: cannot find EFI directory.'
echo 'SYMBLE: install failed: grub-install exited 1'
exec sleep 30
SCRIPT
      ;;
    early-exit)
      cat >>"$path" <<'SCRIPT'
echo '[    0.000000] efi: EFI v2.70 by EDK II'
echo 'QEMU failed before the installer produced a marker'
exit 7
SCRIPT
      ;;
    *)
      printf 'write_fake_qemu: unknown mode %s\n' "$mode" >&2
      exit 1
      ;;
  esac
  chmod +x "$path"
}

write_fake_boot_check_pass() {
  local path=$1

  cat >"$path" <<'SCRIPT'
#!/bin/sh
if [ -n "${FAKE_BOOT_ARGS:-}" ]; then
  printf '%s\n' "$@" >"$FAKE_BOOT_ARGS"
fi
if [ -n "${FAKE_BOOT_INVOKED:-}" ]; then
  : >"$FAKE_BOOT_INVOKED"
fi
artifact=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifact) artifact=$2; shift 2 ;;
    --artifact=*) artifact=${1#--artifact=}; shift ;;
    *) shift ;;
  esac
done
dir=${artifact%/*}
cat >"$dir/boot.log" <<'LOG'
[    0.000000] efi: EFI v2.70 by EDK II
GRUB loading..
Booting `Sysemble'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Reached target Local File Systems.
sysemble login:
LOG
cat >"$dir/boot-evidence.json" <<'JSON'
{
  "apiVersion": "sysemble/boot-evidence/v1",
  "result": "pass",
  "assertions": [
    {"id": "boot.firmware", "result": "pass", "detail": "matched `EFI v`"},
    {"id": "boot.grub", "result": "pass", "detail": "matched `GRUB`"},
    {"id": "boot.kernel", "result": "pass", "detail": "matched `Linux version`"},
    {"id": "boot.systemd", "result": "pass", "detail": "matched `systemd[1]`"},
    {"id": "boot.login", "result": "pass", "detail": "matched `login:`"}
  ]
}
JSON
cat "$dir/boot-evidence.json"
exit 0
SCRIPT
  chmod +x "$path"
}

write_fake_boot_check_fail() {
  local path=$1

  cat >"$path" <<'SCRIPT'
#!/bin/sh
if [ -n "${FAKE_BOOT_ARGS:-}" ]; then
  printf '%s\n' "$@" >"$FAKE_BOOT_ARGS"
fi
artifact=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifact) artifact=$2; shift 2 ;;
    --artifact=*) artifact=${1#--artifact=}; shift ;;
    *) shift ;;
  esac
done
dir=${artifact%/*}
cat >"$dir/boot.log" <<'LOG'
[    0.000000] efi: EFI v2.70 by EDK II
GRUB loading..
Booting `Sysemble'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Reached target Local File Systems.
LOG
cat >"$dir/boot-evidence.json" <<'JSON'
{
  "apiVersion": "sysemble/boot-evidence/v1",
  "result": "fail",
  "assertions": [
    {"id": "boot.firmware", "result": "pass", "detail": "matched `EFI v`"},
    {"id": "boot.grub", "result": "pass", "detail": "matched `GRUB`"},
    {"id": "boot.kernel", "result": "pass", "detail": "matched `Linux version`"},
    {"id": "boot.systemd", "result": "pass", "detail": "matched `systemd[1]`"},
    {"id": "boot.login", "result": "fail", "detail": "no `login:` in log"}
  ]
}
JSON
echo 'boot-check: boot.login: fail - no `login:` in log' >&2
exit 1
SCRIPT
  chmod +x "$path"
}

write_fake_boot_check_timeout() {
  local path=$1

  cat >"$path" <<'SCRIPT'
#!/bin/sh
if [ -n "${FAKE_BOOT_ARGS:-}" ]; then
  printf '%s\n' "$@" >"$FAKE_BOOT_ARGS"
fi
artifact=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifact) artifact=$2; shift 2 ;;
    --artifact=*) artifact=${1#--artifact=}; shift ;;
    *) shift ;;
  esac
done
dir=${artifact%/*}
echo '{"apiVersion":"sysemble/boot-evidence/v1","result":"timeout","assertions":[]}' \
  >"$dir/boot-evidence.json"
echo 'boot-check: boot did not complete within the timeout' >&2
exit 4
SCRIPT
  chmod +x "$path"
}

normalize_install_args() {
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

# JSON-backed artifact variants, used to exercise validation errors without
# duplicating the fixture.
set_artifact_string() {
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

set_artifact_json() {
  local in=$1
  local out=$2
  local path=$3
  local value=$4

  if [ "$JSON_TOOL" = "jq" ]; then
    jq --arg p "$path" --argjson v "$value" \
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
node[keys[-1]] = json.loads(sys.argv[4])
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
# Tests
# ---------------------------------------------------------------------------

test_success_two_phases() {
  local real_case_dir=""
  local work=""
  local args_file=""
  local boot_args_file=""
  local expected=""
  local actual=""
  local duration=0
  local evidence=""
  local qemu_args=""

  begin_case "success: install marker -> boot-check -> both phases pass"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  work="$real_case_dir/work"
  args_file="$CASE_DIR/qemu-args.txt"
  boot_args_file="$CASE_DIR/boot-args.txt"
  evidence="$real_case_dir/out/install-evidence.json"
  write_fake_qemu "$CASE_DIR/fake-qemu" success
  write_fake_boot_check_pass "$CASE_DIR/fake-boot-check"

  expected=$(printf '%s\n' \
    '-machine' 'q35' \
    '-m' '1024' \
    '-smp' '2' \
    '-nographic' \
    '-no-reboot' \
    '-drive' "if=pflash,format=raw,readonly=on,file=$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    '-drive' 'if=pflash,format=raw,file=<VARS>' \
    '-cdrom' "$real_case_dir/out/live.iso" \
    '-drive' "file=$real_case_dir/work/disk.img,format=raw,if=virtio")

  SECONDS=0
  FAKE_QEMU_ARGS="$args_file" FAKE_BOOT_ARGS="$boot_args_file" \
    invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$work" \
    --timeout 10 --json
  duration=$SECONDS

  actual=$(normalize_install_args "$args_file")
  check_eq "exit code" 0 "$RC"
  check_eq "qemu argv" "$expected" "$actual"
  check_eq "default memory arg" "1024" "$(arg_after "$args_file" -m)"
  check_eq "cdrom arg" "$real_case_dir/out/live.iso" \
    "$(arg_after "$args_file" -cdrom)"
  check_contains "virtio disk drive" \
    "file=$real_case_dir/work/disk.img,format=raw,if=virtio" "$(cat "$args_file")"
  check_eq "no -kernel flag" 0 "$(grep -c '^-kernel$' "$args_file" || true)"
  check_eq "no -initrd flag" 0 "$(grep -c '^-initrd$' "$args_file" || true)"
  check_eq "no -append flag" 0 "$(grep -c '^-append$' "$args_file" || true)"
  check_le "install phase stopped QEMU early" 10 "$duration"

  check_eq "disk is exactly 6 GiB" 6442450944 "$(file_size "$work/disk.img")"
  check_file "installer serial log" "$real_case_dir/out/install.log"
  check_contains "install marker in install.log" 'SYMBLE: install complete' \
    "$(cat "$real_case_dir/out/install.log" 2>/dev/null)"
  check_file "post-install serial log preserved" "$real_case_dir/out/install-boot.log"

  check_eq "temporary artifact boot.mode" "uefi" \
    "$(json_field "$work/boot-artifact.json" "boot.mode")"
  check_eq "temporary artifact boot.disk" "disk.img" \
    "$(json_field "$work/boot-artifact.json" "boot.disk")"
  check_eq "temporary artifact boot.memory_mb" "1024" \
    "$(json_field "$work/boot-artifact.json" "boot.memory_mb")"
  check_eq "temporary artifact raw image format" "raw" \
    "$(json_field "$work/boot-artifact.json" "images.0.format")"

  check_eq "boot-check artifact arg" "$real_case_dir/work/boot-artifact.json" \
    "$(arg_after "$boot_args_file" --artifact)"
  check_eq "boot-check qemu arg" "$CASE_DIR/fake-qemu" \
    "$(arg_after "$boot_args_file" --qemu)"
  check_eq "boot-check firmware arg" "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    "$(arg_after "$boot_args_file" --firmware)"
  check_eq "boot-check timeout arg" "10" \
    "$(arg_after "$boot_args_file" --timeout)"
  check_contains "boot-check --json" "--json" "$(cat "$boot_args_file")"

  check_file "evidence" "$evidence"
  check_eq "evidence apiVersion" "sysemble/install-evidence/v1" \
    "$(json_query "$evidence" apiVersion)"
  check_eq "overall result" "pass" "$(json_query "$evidence" result)"
  check_eq "install result" "pass" "$(json_query "$evidence" install_result)"
  check_eq "install marker" "SYMBLE: install complete" \
    "$(json_query "$evidence" install_marker)"
  check_eq "boot result" "pass" "$(json_query "$evidence" boot_result)"
  check_eq "boot phase present" "true" "$(json_query "$evidence" boot_has)"
  check_eq "boot assertions merged" 5 "$(json_query "$evidence" boot_assertion_count)"
  check_eq "boot.firmware assertion" "pass" \
    "$(json_query "$evidence" boot_assertion_result boot.firmware)"
  check_eq "boot.login assertion" "pass" \
    "$(json_query "$evidence" boot_assertion_result boot.login)"
  check_contains "human summary on stderr" "result: pass" "$(cat "$ERR_FILE")"

  # No stale disk is left in the artifact directory.
  check_no_file "no disk image beside artifact" "$real_case_dir/out/disk.img"
  end_case
}

test_install_timeout() {
  local real_case_dir=""
  local work=""
  local evidence=""
  local duration=0

  begin_case "timeout: marker absent -> exit 4, install.log kept"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  work="$real_case_dir/work"
  evidence="$real_case_dir/out/install-evidence.json"
  write_fake_qemu "$CASE_DIR/fake-qemu" timeout
  write_fake_boot_check_pass "$CASE_DIR/fake-boot-check"

  SECONDS=0
  FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    FAKE_BOOT_INVOKED="$CASE_DIR/boot-invoked" \
    invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$work" \
    --timeout 2 --json
  duration=$SECONDS

  check_eq "exit code" 4 "$RC"
  check_eq "timeout stdout is evidence" "timeout" "$(json_query "$OUT_FILE" result)"
  check_le "timeout respected" 15 "$duration"
  check_file "install.log kept on timeout" "$real_case_dir/out/install.log"
  check_contains "install.log content kept" "installer booting" \
    "$(cat "$real_case_dir/out/install.log" 2>/dev/null)"
  check_file "evidence" "$evidence"
  check_eq "overall result" "timeout" "$(json_query "$evidence" result)"
  check_eq "install result" "timeout" "$(json_query "$evidence" install_result)"
  check_contains "timeout error records deadline" "within 2s" \
    "$(json_query "$evidence" install_error)"
  check_eq "boot phase omitted" "false" "$(json_query "$evidence" boot_has)"
  check_no_file "boot-check not invoked" "$CASE_DIR/boot-invoked"
  check_no_file "no boot evidence" "$work/boot-evidence.json"
  # --workdir is caller-owned, so the sparse disk remains for diagnosis.
  check_file "caller-owned disk retained" "$work/disk.img"
  end_case
}

test_install_failed_marker() {
  local real_case_dir=""
  local evidence=""

  begin_case "failed marker: exit 1, reason recorded, boot-check not invoked"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/install-evidence.json"
  write_fake_qemu "$CASE_DIR/fake-qemu" failed
  write_fake_boot_check_pass "$CASE_DIR/fake-boot-check"

  FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    FAKE_BOOT_INVOKED="$CASE_DIR/boot-invoked" \
    invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$real_case_dir/work" \
    --timeout 10 --json

  check_eq "exit code" 1 "$RC"
  check_eq "failure stdout is evidence" "fail" "$(json_query "$OUT_FILE" result)"
  check_file "install.log kept" "$real_case_dir/out/install.log"
  check_contains "failed line in install.log" 'SYMBLE: install failed' \
    "$(cat "$real_case_dir/out/install.log" 2>/dev/null)"
  check_eq "overall result" "fail" "$(json_query "$evidence" result)"
  check_eq "install result" "fail" "$(json_query "$evidence" install_result)"
  check_contains "install reason recorded" "grub-install exited 1" \
    "$(json_query "$evidence" install_error)"
  check_eq "boot phase omitted" "false" "$(json_query "$evidence" boot_has)"
  check_no_file "boot-check not invoked" "$CASE_DIR/boot-invoked"
  end_case
}

test_boot_phase_failure() {
  local real_case_dir=""
  local evidence=""

  begin_case "post-install boot failure: exit 1, boot phase fail with assertions"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/install-evidence.json"
  write_fake_qemu "$CASE_DIR/fake-qemu" success
  write_fake_boot_check_fail "$CASE_DIR/fake-boot-check"

  FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    FAKE_BOOT_ARGS="$CASE_DIR/boot-args.txt" \
    invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$real_case_dir/work" \
    --timeout 10 --json

  check_eq "exit code" 1 "$RC"
  check_eq "overall result" "fail" "$(json_query "$evidence" result)"
  check_eq "install result" "pass" "$(json_query "$evidence" install_result)"
  check_eq "boot result" "fail" "$(json_query "$evidence" boot_result)"
  check_eq "boot assertions merged" 5 "$(json_query "$evidence" boot_assertion_count)"
  check_eq "boot.login failed" "fail" \
    "$(json_query "$evidence" boot_assertion_result boot.login)"
  check_contains "boot failure reason recorded" "status 1" \
    "$(json_query "$evidence" boot_error)"
  check_file "post-install serial log preserved" "$real_case_dir/out/install-boot.log"
  end_case
}

test_boot_phase_timeout() {
  local real_case_dir=""
  local evidence=""

  begin_case "post-install boot timeout: exit 1, boot result timeout"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/install-evidence.json"
  write_fake_qemu "$CASE_DIR/fake-qemu" success
  write_fake_boot_check_timeout "$CASE_DIR/fake-boot-check"

  FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$real_case_dir/work" \
    --timeout 10 --json

  check_eq "exit code" 1 "$RC"
  check_eq "overall result" "fail" "$(json_query "$evidence" result)"
  check_eq "install result" "pass" "$(json_query "$evidence" install_result)"
  check_eq "boot result" "timeout" "$(json_query "$evidence" boot_result)"
  check_contains "boot timeout reason" "timed out" \
    "$(json_query "$evidence" boot_error)"
  end_case
}

test_early_qemu_exit() {
  local real_case_dir=""
  local evidence=""

  begin_case "QEMU exits before marker: exit 1 with status in evidence"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/install-evidence.json"
  write_fake_qemu "$CASE_DIR/fake-qemu" early-exit
  write_fake_boot_check_pass "$CASE_DIR/fake-boot-check"

  FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$real_case_dir/work" \
    --timeout 10 --json

  check_eq "exit code" 1 "$RC"
  check_eq "overall result" "fail" "$(json_query "$evidence" result)"
  check_eq "install result" "fail" "$(json_query "$evidence" install_result)"
  check_contains "QEMU status recorded" "status 7" \
    "$(json_query "$evidence" install_error)"
  check_eq "boot phase omitted" "false" "$(json_query "$evidence" boot_has)"
  end_case
}

test_missing_boot_iso_field() {
  local evidence=""

  begin_case "artifact without boot.iso: exit 2"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/out/install-evidence.json"
  delete_artifact_field "$CASE_DIR/out/artifact.json" \
    "$CASE_DIR/out/no-iso.json" "boot.iso"

  invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/no-iso.json" --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic names boot.iso" "boot.iso" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$evidence"
  end_case
}

test_missing_boot_iso_file() {
  local evidence=""

  begin_case "artifact boot.iso points to a missing file: exit 2"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/out/install-evidence.json"
  set_artifact_string "$CASE_DIR/out/artifact.json" \
    "$CASE_DIR/out/missing-iso.json" "boot.iso" "does-not-exist.iso"

  invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/missing-iso.json" --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic names boot.iso" "boot.iso" "$(cat "$ERR_FILE")"
  check_contains "diagnostic says missing" "does not exist" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$evidence"
  end_case
}

test_invalid_boot_mode() {
  local evidence=""

  begin_case "artifact boot.mode=iso instead of install: exit 2"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/out/install-evidence.json"
  set_artifact_string "$CASE_DIR/out/artifact.json" \
    "$CASE_DIR/out/wrong-mode.json" "boot.mode" "iso"

  invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/wrong-mode.json" --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic demands install" "must be 'install'" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$evidence"
  end_case
}

test_invalid_memory() {
  local evidence=""

  begin_case "artifact boot.memory_mb=0: exit 2"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/out/install-evidence.json"
  set_artifact_json "$CASE_DIR/out/artifact.json" \
    "$CASE_DIR/out/bad-memory.json" "boot.memory_mb" "0"

  invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/bad-memory.json" --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic names memory_mb" "memory_mb" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$evidence"
  end_case
}

test_missing_qemu() {
  local evidence=""

  begin_case "explicit missing QEMU: exit 3"
  make_fixture "$CASE_DIR"
  evidence="$CASE_DIR/out/install-evidence.json"

  invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --qemu /nonexistent/sysemble-qemu --json

  check_eq "exit code" 3 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic names QEMU" "QEMU" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$evidence"
  end_case
}

test_auto_workdir_cleanup() {
  local real_case_dir=""
  local evidence=""

  begin_case "default workdir is removed on exit; logs stay beside artifact"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/install-evidence.json"
  mkdir -p "$CASE_DIR/tmp"
  write_fake_qemu "$CASE_DIR/fake-qemu" success
  write_fake_boot_check_pass "$CASE_DIR/fake-boot-check"

  TMPDIR="$CASE_DIR/tmp" \
    FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --timeout 10 --json

  check_eq "exit code" 0 "$RC"
  check_eq "overall result" "pass" "$(json_query "$evidence" result)"
  check_empty "temporary workdir removed" "$(ls -A "$CASE_DIR/tmp" 2>/dev/null)"
  check_file "install.log beside artifact" "$real_case_dir/out/install.log"
  check_file "evidence beside artifact" "$evidence"
  check_file "post-install log preserved" "$real_case_dir/out/install-boot.log"
  check_no_file "no disk beside artifact" "$real_case_dir/out/disk.img"
  end_case
}

test_json_stdout_only() {
  local real_case_dir=""
  local evidence=""

  begin_case "--json: stdout is install-evidence.json and nothing else"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/install-evidence.json"
  write_fake_qemu "$CASE_DIR/fake-qemu" success
  write_fake_boot_check_pass "$CASE_DIR/fake-boot-check"

  FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$real_case_dir/work" \
    --timeout 10 --json

  check_eq "exit code" 0 "$RC"
  if json_valid "$OUT_FILE"; then
    printf '  ok    stdout is valid JSON\n'
  else
    printf '  FAIL  stdout is not valid JSON:\n%s\n' "$(cat "$OUT_FILE")"
    CASE_OK=0
  fi
  check_eq "stdout starts with JSON object" "{" "$(head -c 1 "$OUT_FILE")"
  check_eq "stdout equals evidence file" "$(cat "$evidence")" "$(cat "$OUT_FILE")"
  check_eq "no human lines on stdout" 0 \
    "$(grep -c '^install-check:' "$OUT_FILE" || true)"
  check_contains "human summary moved to stderr" "result: pass" "$(cat "$ERR_FILE")"
  end_case
}

test_explicit_memory() {
  local real_case_dir=""
  local args_file=""
  local evidence=""

  begin_case "boot.memory_mb=2048 sizes install QEMU; boot artifact stays 1024"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  args_file="$CASE_DIR/qemu-args.txt"
  evidence="$real_case_dir/out/install-evidence.json"
  set_artifact_json "$CASE_DIR/out/artifact.json" \
    "$CASE_DIR/out/big-memory.json" "boot.memory_mb" "2048"
  write_fake_qemu "$CASE_DIR/fake-qemu" success
  write_fake_boot_check_pass "$CASE_DIR/fake-boot-check"

  FAKE_QEMU_ARGS="$args_file" \
    invoke_install_check "$BASH_BIN" "$INSTALL_CHECK" \
    --artifact "$CASE_DIR/out/big-memory.json" \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$real_case_dir/work" \
    --timeout 10 --json

  check_eq "exit code" 0 "$RC"
  check_eq "install QEMU memory" "2048" "$(arg_after "$args_file" -m)"
  check_eq "boot artifact memory frozen at 1024" "1024" \
    "$(json_field "$real_case_dir/work/boot-artifact.json" "boot.memory_mb")"
  check_eq "overall result" "pass" "$(json_query "$evidence" result)"
  end_case
}

# Runs last: every test above has had a chance to leak into the repository.
test_repo_root_has_no_leftovers() {
  local leftovers=""

  begin_case "repo root has no install-check leftovers"
  leftovers=$(ls -A "$REPO_ROOT" 2>/dev/null | \
    grep -E '^(\.sysemble-|install\.log$|install-boot\.log$|install-evidence\.json$|boot-artifact\.json$|disk\.img$)' || true)
  check_empty "repo root leftovers" "$leftovers"
  end_case
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

printf 'Sysemble install-check tests\n'
printf '  repo: %s\n' "$REPO_ROOT"
printf '  bash: %s\n' "$BASH_BIN"
printf '  json: %s\n' "$JSON_TOOL"

test_success_two_phases
test_install_timeout
test_install_failed_marker
test_boot_phase_failure
test_boot_phase_timeout
test_early_qemu_exit
test_missing_boot_iso_field
test_missing_boot_iso_file
test_invalid_boot_mode
test_invalid_memory
test_missing_qemu
test_auto_workdir_cleanup
test_json_stdout_only
test_explicit_memory
test_repo_root_has_no_leftovers

printf '\n----------------------------------------------------------------\n'
printf 'Summary: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -ne 0 ] || [ "$PASS_COUNT" -eq 0 ]; then
  exit 1
fi
exit 0
