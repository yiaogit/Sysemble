#!/usr/bin/env bash
# Sysemble TUI install-check tests (P0-e1).
#
# Exercises tools/tui-install-check.sh without QEMU, OVMF, or a usable pty:
#   - a fake `expect` (first on PATH) parses the invocation and drives the fake
#     QEMU through the frozen prompt sequence over pipes, writing the TUI log
#   - a fake QEMU prints the five frozen prompts, consumes the five answers,
#     records them, and emits a success/failure marker or hangs for the timeout
#   - a fake boot-check writes boot.log/boot-evidence.json and exits with the
#     requested status
#
# Covered:
#   - success: exit 0, exact QEMU argv, 6 GiB disk, answers and marker in
#     tui-install.log (password redacted), evidence install+boot pass with the
#     merged boot-check assertions and boot.hostname, tui-install-boot.log
#   - install timeout: exit 4, evidence timeout, boot phase omitted
#   - failed marker: exit 1, reason recorded, boot-check not invoked
#   - post-install boot failure: exit 1, phases.boot=fail with assertions
#   - hostname absent from boot.log: boot phase fail even when boot-check passes
#   - artifact validation: missing/wrong boot.install_tui, missing boot.iso
#     field/file, missing --hostname (exit 2)
#   - missing QEMU or expect (exit 3)
#   - --json stdout carries only tui-install-evidence.json
#   - auto workdir cleanup and caller-owned --workdir retention
#   - repository root has no leftovers
#
# The real pty/Tcl interaction is exercised in CI by the tui-install-smoke job.
# Here the generated Tcl is additionally checked for the frozen prompts,
# deadline wiring, and argv-passed hostname, and for Tcl syntactic completeness
# when tclsh is available.
#
# Requires bash 3.2+ (macOS /bin/bash). Do not use bash 4 features.

set -u

case "$0" in
  */*) TEST_DIR=${0%/*} ;;
  *) TEST_DIR=. ;;
esac
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd -P)
TUI_CHECK="$REPO_ROOT/tools/tui-install-check.sh"

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
TCLSH=""

cleanup() {
  if [ -n "${TMP_ROOT:-}" ] && [ -d "$TMP_ROOT" ]; then
    case "$TMP_ROOT" in
      */sysemble-tui-install-test.*)
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
  printf 'tui-install-check-test: FATAL: %s\n' "$*" >&2
  exit 1
}

if [ ! -f "$TUI_CHECK" ]; then
  fail_fatal "missing $TUI_CHECK"
fi

if ! TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/sysemble-tui-install-test.XXXXXX" 2>/dev/null); then
  fail_fatal "cannot create a temporary directory"
fi
# macOS mktemp preserves a trailing slash from TMPDIR and /var is a symlink to
# /private/var; normalize once so fixture paths compare literally.
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

if command -v jq >/dev/null 2>&1; then
  JSON_TOOL=jq
elif command -v python3 >/dev/null 2>&1; then
  JSON_TOOL=python3
else
  fail_fatal "tests need jq or python3 to inspect evidence JSON"
fi

if command -v tclsh8.5 >/dev/null 2>&1; then
  TCLSH=$(command -v tclsh8.5)
elif command -v tclsh >/dev/null 2>&1; then
  TCLSH=$(command -v tclsh)
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

check_not_contains() {
  local label=$1
  local needle=$2
  local haystack=$3

  case "$haystack" in
    *"$needle"*)
      printf '  FAIL  %s: unexpected [%s] in:\n%s\n' "$label" "$needle" "$haystack"
      CASE_OK=0
      ;;
    *)
      printf '  ok    %s does not contain [%s]\n' "$label" "$needle"
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

invoke_tui_check() {
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

# Query a fixed set of keys from tui-install-evidence.json.
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
    "install_tui": true,
    "install_device": "/dev/vda",
    "cmdline": "boot=live live-media-path=/live console=ttyS0 sysemble.install.tui=1",
    "memory_mb": 1024
  },
  "builder": {"name": "build.sh", "version": "0.1.0"}
}
EOF
}

write_fake_qemu() {
  local path=$1

  cat >"$path" <<'SCRIPT'
#!/bin/sh
# Fake QEMU: prints the frozen TUI prompts, consumes one answer per prompt,
# records the answers, and then emits the requested marker (or keeps running).
if [ -n "${FAKE_QEMU_ARGS:-}" ]; then
  printf '%s\n' "$@" >"$FAKE_QEMU_ARGS"
fi

record() {
  if [ -n "${FAKE_TUI_ANSWERS:-}" ]; then
    printf '%s\n' "$1" >>"$FAKE_TUI_ANSWERS"
  fi
}

printf 'SYMBLE-TUI disk [/dev/vda]: '
IFS= read -r answer
record "disk=[$answer]"
printf '\n'

printf 'SYMBLE-TUI hostname [sysemble]: '
IFS= read -r answer
record "hostname=$answer"
printf '\n'

printf 'SYMBLE-TUI user [ops]: '
IFS= read -r answer
record "user=$answer"
printf '\n'

printf 'SYMBLE-TUI password: '
IFS= read -r answer
record "password=$answer"
printf '\n'

printf 'SYMBLE-TUI confirm install to /dev/vda (yes/no): '
IFS= read -r answer
record "confirm=$answer"
printf '\n'

case "${FAKE_TUI_MODE:-success}" in
  success)
    printf 'SYMBLE: install complete\n'
    exec sleep 30
    ;;
  failed)
    printf 'SYMBLE: install failed: grub-install exited 1\n'
    exec sleep 30
    ;;
  timeout)
    printf 'installing, no completion marker yet\n'
    exec sleep 30
    ;;
  early-exit)
    printf 'QEMU failed before the installer produced a marker\n'
    exit 7
    ;;
  *)
    printf 'fake-qemu: unknown mode %s\n' "${FAKE_TUI_MODE:-}" >&2
    exit 1
    ;;
esac
SCRIPT
  chmod +x "$path"
}

# A fake expect that parses the real invocation
#   expect -f <tcl> -- <qemu> <log> <pidfile> <timeout> <hostname> <qemu args...>
# and drives the fake QEMU over pipes. It cannot allocate a pty in every test
# sandbox, so the pty dance itself is left to CI; this exercises the wrapper
# contract (argv, log, deadline, exit-code mapping) deterministically.
write_fake_expect() {
  local path=$1

  cat >"$path" <<'SCRIPT'
#!/bin/sh
if [ -n "${FAKE_EXPECT_ARGS:-}" ]; then
  printf '%s\n' "$@" >"$FAKE_EXPECT_ARGS"
fi

script=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f) script=$2; shift 2 ;;
    --) shift; break ;;
    *) shift ;;
  esac
done
if [ ! -f "$script" ]; then
  printf 'fake-expect: missing generated script: %s\n' "$script" >&2
  exit 3
fi
qemu=$1
log=$2
pidfile=$3
timeout=$4
hostname=$5
shift 5

if [ "${FAKE_EXPECT_MODE:-}" = "hang" ]; then
  printf '[fake-expect] wedged; ignoring the expect timeout\n' >>"$log"
  exec sleep 30
fi

# Answers, in the frozen prompt order. An empty first line is the default disk.
answers="$pidfile.answers"
{
  printf '\n'
  printf '%s\n' "$hostname"
  printf 'ops\n'
  printf 's3cret\n'
  printf 'yes\n'
} >"$answers"

"$qemu" "$@" <"$answers" >>"$log" 2>&1 &
qpid=$!
printf '%s\n' "$qpid" >"$pidfile"

i=0
outcome=timeout
while :; do
  if grep -Fq 'SYMBLE: install complete' "$log" 2>/dev/null; then
    outcome=complete
    break
  fi
  if grep -Fq 'SYMBLE: install failed' "$log" 2>/dev/null; then
    outcome=failed
    break
  fi
  if ! kill -0 "$qpid" 2>/dev/null; then
    outcome=exited
    break
  fi
  if [ "$i" -ge "$timeout" ]; then
    outcome=timeout
    break
  fi
  sleep 1
  i=$((i + 1))
done

if kill -0 "$qpid" 2>/dev/null; then
  kill -TERM "$qpid" 2>/dev/null || true
  wait "$qpid" 2>/dev/null || true
fi

# Stand-in for expect's send_log: the password is never logged.
{
  printf '[expect] answer disk: <default>\n'
  printf '[expect] answer hostname: %s\n' "$hostname"
  printf '[expect] answer user: ops\n'
  printf '[expect] answer password: <redacted>\n'
  printf '[expect] answer confirm: yes\n'
} >>"$log"

case "$outcome" in
  complete) exit 0 ;;
  failed) exit 10 ;;
  timeout) exit 4 ;;
  exited) exit 5 ;;
  *) exit 1 ;;
esac
SCRIPT
  chmod +x "$path"
}

write_fake_boot_check() {
  local path=$1

  cat >"$path" <<'SCRIPT'
#!/bin/sh
# Fake boot-check: writes boot.log/boot-evidence.json next to the temporary uefi
# artifact and returns the mode selected by FAKE_BOOT_MODE.
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
if [ -z "$artifact" ]; then
  printf 'fake-boot-check: no --artifact\n' >&2
  exit 2
fi
dir=${artifact%/*}
mode=${FAKE_BOOT_MODE:-pass}

case "$mode" in
  pass | fail)
    cat >"$dir/boot.log" <<'LOG'
[    0.000000] efi: EFI v2.70 by EDK II
GRUB loading..
Booting `Sysemble'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Reached target Local File Systems.
sysemble-tui login:
LOG
    ;;
  hostname-mismatch)
    cat >"$dir/boot.log" <<'LOG'
[    0.000000] efi: EFI v2.70 by EDK II
GRUB loading..
Booting `Sysemble'
[    0.000000] Linux version 6.12.0-amd64 (debian-kernel@lists.debian.org)
[    0.123456] systemd[1]: Reached target Local File Systems.
sysemble login:
LOG
    ;;
  timeout)
    cat >"$dir/boot.log" <<'LOG'
[    0.000000] efi: EFI v2.70 by EDK II
GRUB loading..
Booting `Sysemble'
LOG
    ;;
  *)
    printf 'fake-boot-check: unknown mode %s\n' "$mode" >&2
    exit 2
    ;;
esac

case "$mode" in
  pass | hostname-mismatch)
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
    ;;
  fail)
    cat >"$dir/boot-evidence.json" <<'JSON'
{
  "apiVersion": "sysemble/boot-evidence/v1",
  "result": "fail",
  "assertions": [
    {"id": "boot.firmware", "result": "pass", "detail": "matched `EFI v`"},
    {"id": "boot.grub", "result": "pass", "detail": "matched `GRUB`"},
    {"id": "boot.kernel", "result": "pass", "detail": "matched `Linux version`"},
    {"id": "boot.systemd", "result": "fail", "detail": "no `systemd[1]` in log"},
    {"id": "boot.login", "result": "pass", "detail": "matched `login:`"}
  ]
}
JSON
    cat "$dir/boot-evidence.json"
    echo 'fake-boot-check: boot.systemd failed' >&2
    exit 1
    ;;
  timeout)
    cat >"$dir/boot-evidence.json" <<'JSON'
{
  "apiVersion": "sysemble/boot-evidence/v1",
  "result": "timeout",
  "assertions": []
}
JSON
    echo 'fake-boot-check: boot timed out' >&2
    exit 4
    ;;
esac
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

check_tcl_syntax() {
  local script=$1
  local helper="$CASE_DIR/check-tcl.tcl"

  if [ -z "$TCLSH" ]; then
    printf '  skip  no tclsh; generated Tcl syntax not checked\n'
    return 0
  fi
  cat >"$helper" <<'TCL'
set f [open [lindex $argv 0] r]
set source [read $f]
close $f
if {![info complete $source]} {
    puts stderr "incomplete Tcl"
    exit 1
}
exit 0
TCL
  if "$TCLSH" "$helper" "$script" >/dev/null 2>&1; then
    printf '  ok    generated expect script is complete Tcl\n'
  else
    printf '  FAIL  generated expect script is not complete Tcl\n'
    CASE_OK=0
  fi
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_success_two_phases() {
  local real_case_dir=""
  local work=""
  local args_file=""
  local expect_args_file=""
  local answers_file=""
  local boot_args_file=""
  local expected=""
  local actual=""
  local duration=0
  local evidence=""
  local log_file=""
  local boot_log=""
  local script_file=""

  begin_case "success: expect answers -> install marker -> boot-check -> hostname pass"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  work="$real_case_dir/work"
  args_file="$CASE_DIR/qemu-args.txt"
  expect_args_file="$CASE_DIR/expect-args.txt"
  answers_file="$CASE_DIR/answers.txt"
  boot_args_file="$CASE_DIR/boot-args.txt"
  evidence="$real_case_dir/out/tui-install-evidence.json"
  log_file="$real_case_dir/out/tui-install.log"
  boot_log="$real_case_dir/out/tui-install-boot.log"
  script_file="$real_case_dir/work/tui-install.expect"
  mkdir -p "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  write_fake_boot_check "$CASE_DIR/fake-boot-check"

  expected=$(printf '%s\n' \
    '-machine' 'q35' \
    '-m' '1024' \
    '-smp' '2' \
    '-nographic' \
    '-no-reboot' \
    '-drive' "if=pflash,format=raw,readonly=on,file=$real_case_dir/fw/OVMF_CODE_4M.fd" \
    '-drive' 'if=pflash,format=raw,file=<VARS>' \
    '-cdrom' "$real_case_dir/out/live.iso" \
    '-drive' "file=$real_case_dir/work/disk.img,format=raw,if=virtio")

  SECONDS=0
  PATH="$CASE_DIR/bin:$PATH" \
    FAKE_EXPECT_ARGS="$expect_args_file" \
    FAKE_QEMU_ARGS="$args_file" \
    FAKE_TUI_ANSWERS="$answers_file" \
    FAKE_TUI_MODE=success \
    FAKE_BOOT_ARGS="$boot_args_file" \
    FAKE_BOOT_MODE=pass \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$work" \
    --timeout 10 --json
  duration=$SECONDS

  check_eq "exit code" 0 "$RC"
  check_le "install phase stopped QEMU early" 20 "$duration"

  actual=$(normalize_install_args "$args_file")
  check_eq "QEMU argv" "$expected" "$actual"
  check_eq "default memory arg" "1024" "$(arg_after "$args_file" -m)"
  check_eq "cdrom arg" "$real_case_dir/out/live.iso" \
    "$(arg_after "$args_file" -cdrom)"
  check_contains "virtio disk drive" \
    "file=$real_case_dir/work/disk.img,format=raw,if=virtio" "$(cat "$args_file")"
  check_eq "no -kernel flag" 0 "$(grep -c '^-kernel$' "$args_file" || true)"
  check_eq "no -initrd flag" 0 "$(grep -c '^-initrd$' "$args_file" || true)"
  check_eq "no -append flag" 0 "$(grep -c '^-append$' "$args_file" || true)"

  check_eq "disk is exactly 6 GiB" 6442450944 "$(file_size "$work/disk.img")"

  check_file "generated expect script" "$script_file"
  check_eq "expect got the generated script" "$script_file" \
    "$(arg_after "$expect_args_file" -f)"
  check_eq "expect got the QEMU binary" "$CASE_DIR/fake-qemu" \
    "$(sed -n '4p' "$expect_args_file")"
  check_eq "expect got timeout 10" "10" "$(sed -n '7p' "$expect_args_file")"
  check_eq "expect got hostname" "sysemble-tui" "$(sed -n '8p' "$expect_args_file")"

  check_file "TUI install log" "$log_file"
  check_contains "install marker in tui-install.log" 'SYMBLE: install complete' \
    "$(cat "$log_file" 2>/dev/null)"
  check_contains "disk prompt in log" 'SYMBLE-TUI disk [' \
    "$(cat "$log_file" 2>/dev/null)"
  check_contains "hostname prompt in log" 'SYMBLE-TUI hostname [' \
    "$(cat "$log_file" 2>/dev/null)"
  check_contains "user prompt in log" 'SYMBLE-TUI user [' \
    "$(cat "$log_file" 2>/dev/null)"
  check_contains "password prompt in log" 'SYMBLE-TUI password:' \
    "$(cat "$log_file" 2>/dev/null)"
  check_contains "confirm prompt in log" 'SYMBLE-TUI confirm install to ' \
    "$(cat "$log_file" 2>/dev/null)"
  check_contains "hostname answer in log" 'answer hostname: sysemble-tui' \
    "$(cat "$log_file" 2>/dev/null)"
  check_contains "user answer in log" 'answer user: ops' \
    "$(cat "$log_file" 2>/dev/null)"
  check_contains "confirm answer in log" 'answer confirm: yes' \
    "$(cat "$log_file" 2>/dev/null)"
  check_contains "password redacted in log" 'answer password: <redacted>' \
    "$(cat "$log_file" 2>/dev/null)"
  check_not_contains "password absent from log" 's3cret' \
    "$(cat "$log_file" 2>/dev/null)"

  check_file "fake QEMU answers" "$answers_file"
  check_eq "disk answer was the default" 'disk=[]' "$(sed -n '1p' "$answers_file")"
  check_eq "hostname answer" 'hostname=sysemble-tui' "$(sed -n '2p' "$answers_file")"
  check_eq "user answer" 'user=ops' "$(sed -n '3p' "$answers_file")"
  check_eq "password answer" 'password=s3cret' "$(sed -n '4p' "$answers_file")"
  check_eq "confirm answer" 'confirm=yes' "$(sed -n '5p' "$answers_file")"

  # The generated Tcl must be driven by argv, contain the frozen prompts, and
  # enforce the overall deadline.
  check_contains "Tcl disk prompt" 'SYMBLE-TUI disk [' "$(cat "$script_file")"
  check_contains "Tcl hostname prompt" 'SYMBLE-TUI hostname [' "$(cat "$script_file")"
  check_contains "Tcl user prompt" 'SYMBLE-TUI user [' "$(cat "$script_file")"
  check_contains "Tcl password prompt" 'SYMBLE-TUI password:' "$(cat "$script_file")"
  check_contains "Tcl confirm prompt" 'SYMBLE-TUI confirm install to ' "$(cat "$script_file")"
  check_contains "Tcl initial timeout" 'set timeout $timeout_seconds' "$(cat "$script_file")"
  check_contains "Tcl remaining timeout" 'set timeout $left' "$(cat "$script_file")"
  check_contains "Tcl absolute watchdog" 'after [expr {$timeout_seconds * 1000}]' \
    "$(cat "$script_file")"
  check_contains "Tcl hostname from argv" '$hostname_value' "$(cat "$script_file")"
  check_contains "Tcl user answer" 'set user_value "ops"' "$(cat "$script_file")"
  check_contains "Tcl password answer" 'set password_value "s3cret"' "$(cat "$script_file")"
  check_contains "Tcl confirm answer" 'set confirm_value "yes"' "$(cat "$script_file")"
  check_contains "Tcl completion marker" \
    'set complete_marker "SYMBLE: install complete"' "$(cat "$script_file")"
  check_contains "Tcl failure marker" \
    'set failed_marker "SYMBLE: install failed"' "$(cat "$script_file")"
  check_contains "Tcl logs to argv log path" 'log_file -a $log_path' "$(cat "$script_file")"
  check_contains "Tcl spawns argv QEMU" \
    'spawn -noecho $qemu_bin {*}$qemu_args' "$(cat "$script_file")"
  check_not_contains "hostname not interpolated into Tcl" 'sysemble-tui' \
    "$(cat "$script_file")"
  check_tcl_syntax "$script_file"

  check_file "post-install serial log" "$boot_log"
  check_contains "hostname login in post-install log" 'sysemble-tui login:' \
    "$(cat "$boot_log" 2>/dev/null)"

  check_eq "temporary artifact boot.mode" "uefi" \
    "$(json_field "$work/boot-artifact.json" "boot.mode")"
  check_eq "temporary artifact boot.disk" "disk.img" \
    "$(json_field "$work/boot-artifact.json" "boot.disk")"
  check_eq "temporary artifact boot.memory_mb" "1024" \
    "$(json_field "$work/boot-artifact.json" "boot.memory_mb")"
  check_eq "temporary artifact raw image format" "raw" \
    "$(json_field "$work/boot-artifact.json" "images.0.format")"

  check_eq "boot-check artifact arg" "$work/boot-artifact.json" \
    "$(arg_after "$boot_args_file" --artifact)"
  check_eq "boot-check qemu arg" "$CASE_DIR/fake-qemu" \
    "$(arg_after "$boot_args_file" --qemu)"
  check_eq "boot-check firmware arg" "$real_case_dir/fw/OVMF_CODE_4M.fd" \
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
  check_eq "boot-check assertions merged plus hostname" 6 \
    "$(json_query "$evidence" boot_assertion_count)"
  check_eq "boot.firmware assertion" "pass" \
    "$(json_query "$evidence" boot_assertion_result boot.firmware)"
  check_eq "boot.login assertion" "pass" \
    "$(json_query "$evidence" boot_assertion_result boot.login)"
  check_eq "boot.hostname assertion" "pass" \
    "$(json_query "$evidence" boot_assertion_result boot.hostname)"
  check_contains "boot.hostname detail" "sysemble-tui login:" \
    "$(json_query "$evidence" boot_assertion_detail boot.hostname)"
  check_contains "human summary on stderr" "result: pass" "$(cat "$ERR_FILE")"

  if json_valid "$OUT_FILE"; then
    printf '  ok    stdout is valid JSON\n'
  else
    printf '  FAIL  stdout is not valid JSON:\n%s\n' "$(cat "$OUT_FILE")"
    CASE_OK=0
  fi
  check_eq "stdout equals evidence file" "$(cat "$evidence")" "$(cat "$OUT_FILE")"

  check_no_file "no disk image beside artifact" "$real_case_dir/out/disk.img"
  end_case
}

test_install_timeout() {
  local real_case_dir=""
  local work=""
  local evidence=""
  local duration=0

  begin_case "timeout: marker absent -> exit 4, boot phase omitted"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  work="$real_case_dir/work"
  evidence="$real_case_dir/out/tui-install-evidence.json"
  mkdir -p "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  write_fake_boot_check "$CASE_DIR/fake-boot-check"

  SECONDS=0
  PATH="$CASE_DIR/bin:$PATH" \
    FAKE_EXPECT_ARGS="$CASE_DIR/expect-args.txt" \
    FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    FAKE_TUI_ANSWERS="$CASE_DIR/answers.txt" \
    FAKE_TUI_MODE=timeout \
    FAKE_BOOT_INVOKED="$CASE_DIR/boot-invoked" \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$work" \
    --timeout 2 --json
  duration=$SECONDS

  check_eq "exit code" 4 "$RC"
  check_eq "timeout stdout is evidence" "timeout" "$(json_query "$OUT_FILE" result)"
  check_le "timeout respected" 15 "$duration"
  check_file "TUI log kept on timeout" "$real_case_dir/out/tui-install.log"
  check_contains "TUI log keeps the prompts" "SYMBLE-TUI password:" \
    "$(cat "$real_case_dir/out/tui-install.log" 2>/dev/null)"
  check_contains "all answers logged before timeout" "answer confirm: yes" \
    "$(cat "$real_case_dir/out/tui-install.log" 2>/dev/null)"
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

test_wedged_expect_hard_timeout() {
  local real_case_dir=""
  local work=""
  local evidence=""
  local duration=0

  begin_case "wedged expect: harness hard deadline still exits 4"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  work="$real_case_dir/work"
  evidence="$real_case_dir/out/tui-install-evidence.json"
  mkdir -p "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  write_fake_boot_check "$CASE_DIR/fake-boot-check"

  SECONDS=0
  PATH="$CASE_DIR/bin:$PATH" \
    FAKE_EXPECT_ARGS="$CASE_DIR/expect-args.txt" \
    FAKE_TUI_MODE=success \
    FAKE_EXPECT_MODE=hang \
    FAKE_BOOT_INVOKED="$CASE_DIR/boot-invoked" \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$work" \
    --timeout 1 --json
  duration=$SECONDS

  check_eq "exit code" 4 "$RC"
  check_le "hard deadline bounded" 20 "$duration"
  check_contains "wedged expect logged" "wedged" \
    "$(cat "$real_case_dir/out/tui-install.log" 2>/dev/null)"
  check_eq "overall result" "timeout" "$(json_query "$evidence" result)"
  check_contains "timeout error records deadline" "within 1s" \
    "$(json_query "$evidence" install_error)"
  check_no_file "boot-check not invoked" "$CASE_DIR/boot-invoked"
  end_case
}

test_install_failed_marker() {  local real_case_dir=""
  local evidence=""

  begin_case "failed marker: exit 1, reason recorded, boot-check not invoked"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/tui-install-evidence.json"
  mkdir -p "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  write_fake_boot_check "$CASE_DIR/fake-boot-check"

  PATH="$CASE_DIR/bin:$PATH" \
    FAKE_EXPECT_ARGS="$CASE_DIR/expect-args.txt" \
    FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    FAKE_TUI_ANSWERS="$CASE_DIR/answers.txt" \
    FAKE_TUI_MODE=failed \
    FAKE_BOOT_INVOKED="$CASE_DIR/boot-invoked" \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$real_case_dir/work" \
    --timeout 10 --json

  check_eq "exit code" 1 "$RC"
  check_eq "failure stdout is evidence" "fail" "$(json_query "$OUT_FILE" result)"
  check_file "TUI log kept" "$real_case_dir/out/tui-install.log"
  check_contains "failed line in log" 'SYMBLE: install failed: grub-install exited 1' \
    "$(cat "$real_case_dir/out/tui-install.log" 2>/dev/null)"
  check_eq "overall result" "fail" "$(json_query "$evidence" result)"
  check_eq "install result" "fail" "$(json_query "$evidence" install_result)"
  check_contains "install reason recorded" "grub-install exited 1" \
    "$(json_query "$evidence" install_error)"
  case "$(json_query "$evidence" install_error)" in
    'SYMBLE: install failed: '*)
      printf '  ok    install error starts at the failed marker\n'
      ;;
    *)
      printf '  FAIL  install error does not start at the failed marker: [%s]\n' \
        "$(json_query "$evidence" install_error)"
      CASE_OK=0
      ;;
  esac
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
  evidence="$real_case_dir/out/tui-install-evidence.json"
  mkdir -p "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  write_fake_boot_check "$CASE_DIR/fake-boot-check"

  PATH="$CASE_DIR/bin:$PATH" \
    FAKE_EXPECT_ARGS="$CASE_DIR/expect-args.txt" \
    FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    FAKE_TUI_ANSWERS="$CASE_DIR/answers.txt" \
    FAKE_TUI_MODE=success \
    FAKE_BOOT_ARGS="$CASE_DIR/boot-args.txt" \
    FAKE_BOOT_MODE=fail \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$real_case_dir/work" \
    --timeout 10 --json

  check_eq "exit code" 1 "$RC"
  check_eq "overall result" "fail" "$(json_query "$evidence" result)"
  check_eq "install result" "pass" "$(json_query "$evidence" install_result)"
  check_eq "boot result" "fail" "$(json_query "$evidence" boot_result)"
  check_eq "boot assertions merged plus hostname" 6 \
    "$(json_query "$evidence" boot_assertion_count)"
  check_eq "boot.systemd failed" "fail" \
    "$(json_query "$evidence" boot_assertion_result boot.systemd)"
  check_eq "boot.hostname passed" "pass" \
    "$(json_query "$evidence" boot_assertion_result boot.hostname)"
  check_contains "boot failure reason recorded" "status 1" \
    "$(json_query "$evidence" boot_error)"
  check_file "post-install serial log preserved" \
    "$real_case_dir/out/tui-install-boot.log"
  end_case
}

test_hostname_not_in_boot_log() {
  local real_case_dir=""
  local evidence=""

  begin_case "hostname missing from boot.log: boot phase fails despite boot-check 0"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/tui-install-evidence.json"
  mkdir -p "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  write_fake_boot_check "$CASE_DIR/fake-boot-check"

  PATH="$CASE_DIR/bin:$PATH" \
    FAKE_EXPECT_ARGS="$CASE_DIR/expect-args.txt" \
    FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    FAKE_TUI_ANSWERS="$CASE_DIR/answers.txt" \
    FAKE_TUI_MODE=success \
    FAKE_BOOT_MODE=hostname-mismatch \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$real_case_dir/work" \
    --timeout 10 --json

  check_eq "exit code" 1 "$RC"
  check_eq "overall result" "fail" "$(json_query "$evidence" result)"
  check_eq "install result" "pass" "$(json_query "$evidence" install_result)"
  check_eq "boot result" "fail" "$(json_query "$evidence" boot_result)"
  check_contains "boot error names expected login prompt" "sysemble-tui login:" \
    "$(json_query "$evidence" boot_error)"
  check_eq "boot.hostname failed" "fail" \
    "$(json_query "$evidence" boot_assertion_result boot.hostname)"
  check_contains "boot.hostname detail names hostname" "sysemble-tui login:" \
    "$(json_query "$evidence" boot_assertion_detail boot.hostname)"
  check_file "post-install log copied for diagnosis" \
    "$real_case_dir/out/tui-install-boot.log"
  end_case
}

test_boot_phase_timeout() {
  local real_case_dir=""
  local evidence=""

  begin_case "post-install boot timeout: exit 1, phases.boot=timeout"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/tui-install-evidence.json"
  mkdir -p "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  write_fake_boot_check "$CASE_DIR/fake-boot-check"

  PATH="$CASE_DIR/bin:$PATH" \
    FAKE_EXPECT_ARGS="$CASE_DIR/expect-args.txt" \
    FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    FAKE_TUI_ANSWERS="$CASE_DIR/answers.txt" \
    FAKE_TUI_MODE=success \
    FAKE_BOOT_MODE=timeout \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$real_case_dir/work" \
    --timeout 10 --json

  check_eq "exit code" 1 "$RC"
  check_eq "overall result" "fail" "$(json_query "$evidence" result)"
  check_eq "boot result" "timeout" "$(json_query "$evidence" boot_result)"
  check_contains "boot timeout reason" "timed out" \
    "$(json_query "$evidence" boot_error)"
  end_case
}

test_early_qemu_exit() {
  local real_case_dir=""
  local evidence=""

  begin_case "QEMU exits before marker: exit 1 with early-exit evidence"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/tui-install-evidence.json"
  mkdir -p "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  write_fake_boot_check "$CASE_DIR/fake-boot-check"

  PATH="$CASE_DIR/bin:$PATH" \
    FAKE_EXPECT_ARGS="$CASE_DIR/expect-args.txt" \
    FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    FAKE_TUI_ANSWERS="$CASE_DIR/answers.txt" \
    FAKE_TUI_MODE=early-exit \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --workdir "$real_case_dir/work" \
    --timeout 10 --json

  check_eq "exit code" 1 "$RC"
  check_eq "overall result" "fail" "$(json_query "$evidence" result)"
  check_eq "install result" "fail" "$(json_query "$evidence" install_result)"
  check_contains "early exit recorded" "QEMU exited before" \
    "$(json_query "$evidence" install_error)"
  check_eq "boot phase omitted" "false" "$(json_query "$evidence" boot_has)"
  end_case
}

test_missing_install_tui() {
  begin_case "artifact without boot.install_tui: exit 2"
  make_fixture "$CASE_DIR"
  delete_artifact_field "$CASE_DIR/out/artifact.json" \
    "$CASE_DIR/out/no-tui.json" "boot.install_tui"

  invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/no-tui.json" \
    --hostname sysemble-tui --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic names install_tui" "boot.install_tui" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$CASE_DIR/out/tui-install-evidence.json"
  check_no_file "no TUI log" "$CASE_DIR/out/tui-install.log"
  end_case
}

test_install_tui_false() {
  begin_case "artifact boot.install_tui=false: exit 2"
  make_fixture "$CASE_DIR"
  set_artifact_json "$CASE_DIR/out/artifact.json" \
    "$CASE_DIR/out/no-tui.json" "boot.install_tui" "false"

  invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/no-tui.json" \
    --hostname sysemble-tui --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic says must be true" "must be true" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$CASE_DIR/out/tui-install-evidence.json"
  end_case
}

test_missing_boot_iso_field() {
  begin_case "artifact without boot.iso: exit 2"
  make_fixture "$CASE_DIR"
  delete_artifact_field "$CASE_DIR/out/artifact.json" \
    "$CASE_DIR/out/no-iso.json" "boot.iso"

  invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/no-iso.json" \
    --hostname sysemble-tui --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic names boot.iso" "boot.iso" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$CASE_DIR/out/tui-install-evidence.json"
  end_case
}

test_missing_boot_iso_file() {
  begin_case "artifact boot.iso points to a missing file: exit 2"
  make_fixture "$CASE_DIR"
  set_artifact_string "$CASE_DIR/out/artifact.json" \
    "$CASE_DIR/out/missing-iso.json" "boot.iso" "does-not-exist.iso"

  invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/missing-iso.json" \
    --hostname sysemble-tui --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic names boot.iso" "boot.iso" "$(cat "$ERR_FILE")"
  check_contains "diagnostic says missing" "does not exist" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$CASE_DIR/out/tui-install-evidence.json"
  end_case
}

test_missing_hostname() {
  begin_case "missing --hostname: exit 2"
  make_fixture "$CASE_DIR"

  invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic names --hostname" "--hostname" "$(cat "$ERR_FILE")"
  end_case
}

test_missing_qemu() {
  begin_case "explicit missing QEMU: exit 3"
  make_fixture "$CASE_DIR"

  invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu /nonexistent/sysemble-qemu --json

  check_eq "exit code" 3 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic names QEMU" "QEMU" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$CASE_DIR/out/tui-install-evidence.json"
  end_case
}

test_missing_expect() {
  local sandbox=""

  begin_case "expect missing from PATH: exit 3"
  make_fixture "$CASE_DIR"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  sandbox="$CASE_DIR/sandbox-bin"
  mkdir -p "$sandbox"
  # Only the JSON parser is needed before resolve_expect fails; omitting expect
  # from PATH is exactly the condition under test.
  if command -v jq >/dev/null 2>&1; then
    ln -s "$(command -v jq)" "$sandbox/jq"
  elif command -v python3 >/dev/null 2>&1; then
    ln -s "$(command -v python3)" "$sandbox/python3"
  else
    fail_fatal "tests need jq or python3"
  fi

  PATH="$sandbox" \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --json

  check_eq "exit code" 3 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic names expect" "expect" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$CASE_DIR/out/tui-install-evidence.json"
  end_case
}

test_missing_boot_check() {
  begin_case "explicit missing boot-check: exit 2 before install"
  make_fixture "$CASE_DIR"
  mkdir -p "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"

  PATH="$CASE_DIR/bin:$PATH" \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu "$CASE_DIR/fake-qemu" \
    --boot-check /nonexistent/sysemble-boot-check --json

  check_eq "exit code" 2 "$RC"
  check_empty "stdout" "$(cat "$OUT_FILE")"
  check_contains "diagnostic names boot-check" "boot-check" "$(cat "$ERR_FILE")"
  check_no_file "no evidence" "$CASE_DIR/out/tui-install-evidence.json"
  end_case
}

test_json_stdout_only() {
  local real_case_dir=""
  local evidence=""

  begin_case "--json: stdout is tui-install-evidence.json and nothing else"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/tui-install-evidence.json"
  mkdir -p "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  write_fake_boot_check "$CASE_DIR/fake-boot-check"

  PATH="$CASE_DIR/bin:$PATH" \
    FAKE_EXPECT_ARGS="$CASE_DIR/expect-args.txt" \
    FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    FAKE_TUI_ANSWERS="$CASE_DIR/answers.txt" \
    FAKE_TUI_MODE=success \
    FAKE_BOOT_MODE=pass \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
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
    "$(grep -c '^tui-install-check:' "$OUT_FILE" || true)"
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
  evidence="$real_case_dir/out/tui-install-evidence.json"
  set_artifact_json "$CASE_DIR/out/artifact.json" \
    "$CASE_DIR/out/big-memory.json" "boot.memory_mb" "2048"
  mkdir -p "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  write_fake_boot_check "$CASE_DIR/fake-boot-check"

  PATH="$CASE_DIR/bin:$PATH" \
    FAKE_EXPECT_ARGS="$CASE_DIR/expect-args.txt" \
    FAKE_QEMU_ARGS="$args_file" \
    FAKE_TUI_ANSWERS="$CASE_DIR/answers.txt" \
    FAKE_TUI_MODE=success \
    FAKE_BOOT_MODE=pass \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/big-memory.json" \
    --hostname sysemble-tui \
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

test_auto_workdir_cleanup() {
  local real_case_dir=""
  local evidence=""

  begin_case "default workdir is removed on exit; logs stay beside artifact"
  make_fixture "$CASE_DIR"
  real_case_dir=$(cd "$CASE_DIR" && pwd -P)
  evidence="$real_case_dir/out/tui-install-evidence.json"
  mkdir -p "$CASE_DIR/tmp" "$CASE_DIR/bin"
  write_fake_expect "$CASE_DIR/bin/expect"
  write_fake_qemu "$CASE_DIR/fake-qemu"
  write_fake_boot_check "$CASE_DIR/fake-boot-check"

  TMPDIR="$CASE_DIR/tmp" \
    PATH="$CASE_DIR/bin:$PATH" \
    FAKE_EXPECT_ARGS="$CASE_DIR/expect-args.txt" \
    FAKE_QEMU_ARGS="$CASE_DIR/qemu-args.txt" \
    FAKE_TUI_ANSWERS="$CASE_DIR/answers.txt" \
    FAKE_TUI_MODE=success \
    FAKE_BOOT_MODE=pass \
    invoke_tui_check "$BASH_BIN" "$TUI_CHECK" \
    --artifact "$CASE_DIR/out/artifact.json" \
    --hostname sysemble-tui \
    --qemu "$CASE_DIR/fake-qemu" \
    --firmware "$CASE_DIR/fw/OVMF_CODE_4M.fd" \
    --boot-check "$CASE_DIR/fake-boot-check" \
    --timeout 10 --json

  check_eq "exit code" 0 "$RC"
  check_eq "overall result" "pass" "$(json_query "$evidence" result)"
  check_empty "temporary workdir removed" "$(ls -A "$CASE_DIR/tmp" 2>/dev/null)"
  check_file "TUI log beside artifact" "$real_case_dir/out/tui-install.log"
  check_file "evidence beside artifact" "$evidence"
  check_file "post-install log preserved" "$real_case_dir/out/tui-install-boot.log"
  check_no_file "no disk beside artifact" "$real_case_dir/out/disk.img"
  end_case
}

# Runs last: every test above has had a chance to leak into the repository.
test_repo_root_has_no_leftovers() {
  local leftovers=""

  begin_case "repo root has no tui-install-check leftovers"
  leftovers=$(ls -A "$REPO_ROOT" 2>/dev/null | \
    grep -E '^(\.tui-install|tui-install|\.sysemble-tui|disk\.img$|boot-artifact\.json$)' || true)
  check_empty "repo root leftovers" "$leftovers"
  end_case
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

printf 'Sysemble tui-install-check tests\n'
printf '  repo: %s\n' "$REPO_ROOT"
printf '  bash: %s\n' "$BASH_BIN"
printf '  json: %s\n' "$JSON_TOOL"
if [ -n "$TCLSH" ]; then
  printf '  tcl:  %s\n' "$TCLSH"
else
  printf '  tcl:  unavailable (syntax check skipped)\n'
fi

test_success_two_phases
test_install_timeout
test_wedged_expect_hard_timeout
test_install_failed_marker
test_boot_phase_failure
test_hostname_not_in_boot_log
test_boot_phase_timeout
test_early_qemu_exit
test_missing_install_tui
test_install_tui_false
test_missing_boot_iso_field
test_missing_boot_iso_file
test_missing_hostname
test_missing_qemu
test_missing_expect
test_missing_boot_check
test_json_stdout_only
test_explicit_memory
test_auto_workdir_cleanup
test_repo_root_has_no_leftovers

printf '\n----------------------------------------------------------------\n'
printf 'Summary: %d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -ne 0 ] || [ "$PASS_COUNT" -eq 0 ]; then
  exit 1
fi
exit 0
