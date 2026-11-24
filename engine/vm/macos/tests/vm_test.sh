#!/usr/bin/env bash
# Static/local checks for the Sysemble macOS VM helper (P1-e3b).
#
#   bash engine/vm/macos/tests/vm_test.sh [--boot] [--plan <plan.json>]
#
# Default mode NEVER starts a VM: it checks the built+ad-hoc-signed binary,
# probe's JSON contract, CLI exit codes, path validation (with synthetic
# image/repo trees), and the entitlement. This is what CI runs, because
# GitHub's macOS runners cannot nest Virtualization.framework.
#
# --boot is an opt-in end-to-end smoke test for a developer Mac that already
# has engine/vm/image/build (E3a). It is skipped when the image is absent.
set -u
set -o pipefail

DIR=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$DIR/../../.." && pwd)
BIN="$DIR/.build/release/sysemble-vm"

BOOT=0
PLAN_ARG=""
usage() {
  cat <<'EOF'
Usage: bash engine/vm/macos/tests/vm_test.sh [--boot] [--plan <plan.json>]

Default: static checks only (safe on CI runners, never boots a VM).
  --boot         opt-in E2E smoke test; skipped unless engine/vm/image/build
                 contains disk.img/vmlinuz/initrd.img and E3a's guest script.
  --plan FILE    plan.json for --boot (otherwise $SYsEMBLE_VM_PLAN or a plan
                 generated with `cargo run -p sysemble-cli -- plan`).
  --help         show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --boot)
      BOOT=1
      shift
      ;;
    --plan)
      if [ "$#" -lt 2 ]; then
        echo "error: --plan requires a value" >&2
        exit 2
      fi
      PLAN_ARG=$2
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

PASS=0
FAIL=0
SKIP=0

pass() {
  PASS=$((PASS + 1))
  printf 'PASS: %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n' "$1"
}

skip() {
  SKIP=$((SKIP + 1))
  printf 'SKIP: %s\n' "$1"
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/sysemble-vm-test.XXXXXX") || {
  echo "error: cannot create a temporary directory" >&2
  exit 1
}
trap 'rm -rf "$TMP"' EXIT
# Keep probe's throw-away 1 MiB files inside the test's scratch directory.
export TMPDIR="$TMP/tmp"
mkdir -p "$TMPDIR"

if [ ! -x "$BIN" ]; then
  echo "FAIL: helper not built: $BIN" >&2
  echo "      run: bash engine/vm/macos/build.sh" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required to validate probe's JSON contract" >&2
  exit 1
fi

# expect_rc <description> <expected> <command...>
expect_rc() {
  local description=$1 expected=$2
  shift 2
  local actual
  "$@" >"$TMP/stdout" 2>"$TMP/stderr"
  actual=$?
  if [ "$actual" -eq "$expected" ]; then
    pass "$description (exit $actual)"
  else
    fail "$description: expected exit $expected, got $actual; stderr: $(head -n 2 "$TMP/stderr" | tr '\n' ' ')"
  fi
}

# MARK: - Build/signature

if codesign --verify "$BIN" >/dev/null 2>"$TMP/codesign.err"; then
  pass "codesign --verify accepts the ad-hoc signature"
else
  fail "codesign --verify failed: $(cat "$TMP/codesign.err")"
fi

ENTITLEMENTS=$(codesign -d --entitlements - "$BIN" 2>&1 || true)
case "$ENTITLEMENTS" in
  *com.apple.security.virtualization*)
    pass "codesign reports com.apple.security.virtualization"
    ;;
  *)
    fail "signature lacks com.apple.security.virtualization (run engine/vm/macos/build.sh)"
    ;;
esac

# MARK: - probe

if "$BIN" probe --json >"$TMP/probe.json" 2>"$TMP/probe.err"; then
  if jq -e '
      def type_ok:
        type == "object"
        and (.supported | (type == "boolean") or . == "unknown")
        and (.entitled | type == "boolean")
        and (.arch | type == "string" and length > 0)
        and (.macos | type == "string" and test("^[0-9]+\\.[0-9]+"))
        and (.cpus | type == "number" and . >= 1 and . == floor)
        and (.reason | type == "string" and length > 0);
      type_ok
    ' "$TMP/probe.json" >/dev/null 2>&1; then
    pass "probe --json has the documented fields and types"
  else
    fail "probe --json does not match the documented schema: $(cat "$TMP/probe.json")"
  fi

  EXPECTED_ARCH=$(uname -m)
  if jq -e --arg arch "$EXPECTED_ARCH" '.arch == $arch' "$TMP/probe.json" >/dev/null 2>&1; then
    pass "probe reports the host architecture ($EXPECTED_ARCH)"
  else
    fail "probe arch does not match uname -m ($EXPECTED_ARCH)"
  fi

  EXPECTED_MACOS=$(sw_vers -productVersion)
  if jq -e --arg version "$EXPECTED_MACOS" '.macos == $version' "$TMP/probe.json" >/dev/null 2>&1; then
    pass "probe reports the host macOS version ($EXPECTED_MACOS)"
  else
    fail "probe macos does not match sw_vers ($EXPECTED_MACOS)"
  fi

  if jq -e '
      if .supported == true then .entitled == true else true end
    ' "$TMP/probe.json" >/dev/null 2>&1; then
    pass "probe is self-consistent (a supported host accepts the signature)"
  else
    fail "probe says supported=true but entitled=false on a capable host"
  fi

  SUPPORTED=$(jq -r '.supported' "$TMP/probe.json")
  ENTITLED=$(jq -r '.entitled' "$TMP/probe.json")
  if [ "$SUPPORTED" = "true" ]; then
    pass "probe: supported=true entitled=$ENTITLED (host can run a VM)"
  else
    skip "probe: supported=$SUPPORTED (expected on CI/nested-VM runners; VM boot is unavailable)"
  fi
else
  fail "probe --json failed: $(cat "$TMP/probe.err")"
fi

expect_rc "probe exits 0 (a diagnostic, not a gate)" 0 "$BIN" probe
if "$BIN" probe >"$TMP/probe-h.txt" 2>&1; then
  if grep -q '^  supported:' "$TMP/probe-h.txt" &&
      grep -q '^  entitled:' "$TMP/probe-h.txt" &&
      grep -q '^  reason:' "$TMP/probe-h.txt"; then
    pass "probe human output lists supported/entitled/reason"
  else
    fail "probe human output is missing fields"
  fi
else
  fail "probe (human mode) failed"
fi

# MARK: - CLI grammar (exit 2)

if "$BIN" --help >"$TMP/help.txt" 2>&1 && grep -q '^Usage:' "$TMP/help.txt"; then
  pass "--help exits 0 and prints usage"
else
  fail "--help did not exit 0 with usage"
fi

if "$BIN" run --help >"$TMP/run-help.txt" 2>&1 && grep -q '^Usage:' "$TMP/run-help.txt"; then
  pass "run --help exits 0 and prints usage"
else
  fail "run --help did not exit 0 with usage"
fi

expect_rc "unknown command is a usage error" 2 "$BIN" frobnicate
expect_rc "unknown probe option is a usage error" 2 "$BIN" probe --bogus
expect_rc "run without required arguments is a usage error" 2 "$BIN" run
expect_rc "run with a missing option value is a usage error" 2 "$BIN" run --cpus

# MARK: - Synthetic fixtures (never boot a VM)

FAKE="$TMP/fake"
mkdir -p "$FAKE/image" "$FAKE/repo/builders/debian" "$FAKE/repo/engine/vm/guest"
# 1 MiB zero disk: >0 and a multiple of 512.
dd if=/dev/zero of="$FAKE/image/disk.img" bs=1024 count=1024 >/dev/null 2>&1
printf 'kernel' >"$FAKE/image/vmlinuz"
printf 'initrd' >"$FAKE/image/initrd.img"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE/repo/builders/debian/build.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE/repo/engine/vm/guest/minimal-build.sh"
printf '{}\n' >"$FAKE/plan.json"
chmod +x "$FAKE/repo/builders/debian/build.sh" "$FAKE/repo/engine/vm/guest/minimal-build.sh"

# Fixtures without a guest script / plan.
mkdir -p "$FAKE/repo-incomplete/builders/debian"
cp "$FAKE/repo/builders/debian/build.sh" "$FAKE/repo-incomplete/builders/debian/build.sh"

expect_rc "run with a missing --image-dir exits 3" 3 \
  "$BIN" run --image-dir "$FAKE/image-missing" --repo "$FAKE/repo" \
  --out "$FAKE/out" --plan "$FAKE/plan.json"

mkdir -p "$FAKE/image-incomplete"
cp "$FAKE/image/vmlinuz" "$FAKE/image/initrd.img" "$FAKE/image-incomplete/"
expect_rc "run with an incomplete image (no disk.img) exits 3" 3 \
  "$BIN" run --image-dir "$FAKE/image-incomplete" --repo "$FAKE/repo" \
  --out "$FAKE/out" --plan "$FAKE/plan.json"

expect_rc "run without engine/vm/guest/minimal-build.sh exits 3" 3 \
  "$BIN" run --image-dir "$FAKE/image" --repo "$FAKE/repo-incomplete" \
  --out "$FAKE/out" --plan "$FAKE/plan.json"

expect_rc "run with a missing plan exits 3" 3 \
  "$BIN" run --image-dir "$FAKE/image" --repo "$FAKE/repo" \
  --out "$FAKE/out" --plan "$FAKE/plan-missing.json"

# A bad disk size must be rejected before a VM is constructed.
mkdir -p "$FAKE/image-badsize"
cp "$FAKE/image/vmlinuz" "$FAKE/image/initrd.img" "$FAKE/image-badsize/"
dd if=/dev/zero of="$FAKE/image-badsize/disk.img" bs=1000 count=1 >/dev/null 2>&1
expect_rc "run with a disk.img size that is not a multiple of 512 exits 3" 3 \
  "$BIN" run --image-dir "$FAKE/image-badsize" --repo "$FAKE/repo" \
  --out "$FAKE/out" --plan "$FAKE/plan.json"

# --out exists but is a file: fail while preparing output, still no VM.
printf 'not a directory\n' >"$FAKE/out-file"
expect_rc "run with --out pointing at a file exits 3" 3 \
  "$BIN" run --image-dir "$FAKE/image" --repo "$FAKE/repo" \
  --out "$FAKE/out-file" --plan "$FAKE/plan.json"

expect_rc "run --cpus 0 exits 2 before touching paths" 2 \
  "$BIN" run --image-dir "$FAKE/image" --repo "$FAKE/repo" \
  --out "$FAKE/out" --plan "$FAKE/plan.json" --cpus 0

expect_rc "run --out / is refused as a usage error" 2 \
  "$BIN" run --image-dir "$FAKE/image" --repo "$FAKE/repo" \
  --out / --plan "$FAKE/plan.json"

# --json must keep stdout machine-readable even for a path error.
"$BIN" run --json --image-dir "$FAKE/image-missing" --repo "$FAKE/repo" \
  --out "$TMP/json-out" --plan "$FAKE/plan.json" \
  >"$TMP/run-error.json" 2>"$TMP/run-error.err"
RC=$?
if [ "$RC" -eq 3 ] && jq -e '
    .rc == 3
    and .ready == false
    and .done == false
    and (.elapsed_seconds | type == "number")
    and (.log_path | type == "string")
    and (.serial_log | type == "string")
    and (.work_dir | type == "string")
    and (.error | type == "string" and length > 0)
  ' "$TMP/run-error.json" >/dev/null 2>&1; then
  pass "run --json emits the documented error object with rc=3"
else
  fail "run --json error contract mismatch (exit $RC): $(cat "$TMP/run-error.json")"
fi

# MARK: - Shell syntax

for script in "$DIR/build.sh" "$DIR/tests/vm_test.sh"; do
  if bash -n "$script" 2>"$TMP/bash-n.err"; then
    pass "bash -n $(basename "$script")"
  else
    fail "bash -n $(basename "$script"): $(cat "$TMP/bash-n.err")"
  fi
done

# MARK: - Optional E2E (explicit --boot only)

if [ "$BOOT" -eq 1 ]; then
  IMAGE_DIR=${SYsEMBLE_VM_IMAGE_DIR:-"$REPO/engine/vm/image/build"}
  PLAN=$PLAN_ARG
  if [ -z "$PLAN" ] && [ -n "${SYsEMBLE_VM_PLAN:-}" ]; then
    PLAN=$SYsEMBLE_VM_PLAN
  fi

  if [ ! -f "$IMAGE_DIR/disk.img" ] || [ ! -f "$IMAGE_DIR/vmlinuz" ] ||
      [ ! -f "$IMAGE_DIR/initrd.img" ]; then
    skip "boot: no E3a image under $IMAGE_DIR (build it or set SYsEMBLE_VM_IMAGE_DIR)"
  elif [ ! -f "$REPO/engine/vm/guest/minimal-build.sh" ]; then
    skip "boot: E3a guest script engine/vm/guest/minimal-build.sh is not present"
  else
    if [ -z "$PLAN" ] && command -v cargo >/dev/null 2>&1; then
      if (cd "$REPO" && cargo run -q -p sysemble-cli -- plan \
        examples/minimal-debian.yaml) >"$TMP/boot-plan.json" 2>"$TMP/boot-plan.err"; then
        PLAN=$TMP/boot-plan.json
      fi
    fi
    if [ -z "$PLAN" ] || [ ! -f "$PLAN" ]; then
      skip "boot: no plan (pass --plan or set SYsEMBLE_VM_PLAN)"
    else
      mkdir -p "$TMP/boot"
      if "$BIN" run --image-dir "$IMAGE_DIR" --repo "$REPO" --out "$TMP/boot" \
        --plan "$PLAN" --ready-timeout 180 --timeout 600 --json \
        >"$TMP/boot.json" 2>"$TMP/boot.err"; then
        if jq -e '.rc == 0 and .ready == true and .done == true' \
          "$TMP/boot.json" >/dev/null 2>&1; then
          pass "boot: VM reached ready, ran the job, and returned rc=0"
          for artifact in rootfs.tar.gz artifact-vm.json; do
            if [ -s "$TMP/boot/$artifact" ]; then
              pass "boot: exported $artifact"
            else
              fail "boot: missing or empty $TMP/boot/$artifact"
            fi
          done
        else
          fail "boot: JSON protocol result was not successful: $(cat "$TMP/boot.json")"
        fi
      else
        fail "boot: sysemble-vm run failed: $(tail -n 5 "$TMP/boot.err" | tr '\n' ' ')"
      fi
    fi
  fi
fi

# MARK: - Summary

printf '\nVM helper tests: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
exit 0
