#!/usr/bin/env bash
# =============================================================================
# Sysemble P0-a acceptance runner (SA-verify)
# =============================================================================
#
# Black-box acceptance for the frozen P0-a slice:
#   validate + plan + builders/debian dry-run.
#
# Covers A1-A10 (docs/plan/P0-workplan.md, as restated by the SA-verify task)
# and the adversarial checks B1-B7.
#
# Properties:
#   - Does not modify the repository. Every scratch file lives under a fresh
#     mktemp directory and is removed on exit.
#   - Does not need the network: Cargo runs with CARGO_NET_OFFLINE=true.
#   - Does not need a Docker daemon and never starts a container. The builder
#     docker path is deliberately not exercised.
#   - Prints PASS/FAIL per check; BLOCKED is used only where the exercise
#     itself says to record an environment gap (A7 without jsonschema/pyyaml).
#
# Exit status:
#   0  no FAIL (BLOCKED/risk items may be present)
#   1  at least one FAIL
#   2  missing prerequisite (cargo/jq/python3/git)
#
# Usage:
#   bash tests/acceptance/run.sh
#
# Optional environment:
#   CARGO_HOME / RUSTUP_HOME  toolchain location (default: <repo>/../.tools)
#   CARGO                     cargo executable
#   CARGO_NET_OFFLINE         defaults to true
# =============================================================================

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)

# ---------------------------------------------------------------------------
# Toolchain and prerequisites
# ---------------------------------------------------------------------------

PROJECT_TOOLS=$(cd "$ROOT/.." && pwd -P)/.tools
if [ -x "$PROJECT_TOOLS/cargo/bin/cargo" ]; then
  : "${CARGO_HOME:=$PROJECT_TOOLS/cargo}"
  : "${RUSTUP_HOME:=$PROJECT_TOOLS/rustup}"
  CARGO=${CARGO:-$CARGO_HOME/bin/cargo}
else
  CARGO=${CARGO:-cargo}
fi
export CARGO_HOME RUSTUP_HOME
: "${CARGO_NET_OFFLINE:=true}"
export CARGO_NET_OFFLINE

MISSING=""
for tool in jq python3 git; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if ! command -v "$CARGO" >/dev/null 2>&1; then
  MISSING="$MISSING cargo($CARGO)"
fi
if [ -n "$MISSING" ]; then
  printf 'ERROR: missing prerequisite(s):%s\n' "$MISSING" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Scratch space, counters, output helpers
# ---------------------------------------------------------------------------

TMP_BASE=${TMPDIR:-/tmp}
TMP_BASE=${TMP_BASE%/}
TMP=$(mktemp -d "$TMP_BASE/sysemble-accept.XXXXXX") || {
  printf 'ERROR: cannot create a temporary directory\n' >&2
  exit 2
}
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

PASSES=0
FAILS=0
BLOCKED=0
FAILED_IDS=""

note() {
  printf '         %s\n' "$*"
}

pass() {
  PASSES=$((PASSES + 1))
  printf 'PASS     %-3s %s\n' "$1" "$2"
}

fail() {
  FAILS=$((FAILS + 1))
  FAILED_IDS="${FAILED_IDS}${FAILED_IDS:+ }$1"
  printf 'FAIL     %-3s %s\n' "$1" "$2"
}

blocked() {
  BLOCKED=$((BLOCKED + 1))
  printf 'BLOCKED  %-3s %s\n' "$1" "$2"
}

show_tail() {
  tail -n "$2" "$1" 2>/dev/null | sed 's/^/         | /'
}

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    cksum "$1" 2>/dev/null | awk '{print $1 "-" $2}'
  fi
}

# Run the real CLI through `cargo run`, from the repository root. This matches
# the documented acceptance commands and guarantees the tested binary is built
# from the current sources.
cli() {
  ( cd "$ROOT" && "$CARGO" run --quiet -p sysemble-cli -- "$@" )
}

# Snapshot the work tree before any check runs: A10 compares this with the
# state after every other check.
if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'ERROR: %s is not a git work tree (A10 needs git status)\n' "$ROOT" >&2
  exit 2
fi
GIT_HEAD=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
GIT_START="$TMP/git-start.txt"
GIT_DIFF_START="$TMP/git-diff-start.txt"
git -C "$ROOT" status --porcelain -uall >"$GIT_START" 2>/dev/null || true
git -C "$ROOT" diff --no-ext-diff >"$GIT_DIFF_START" 2>/dev/null || true
LOCK_START=$(hash_file "$ROOT/Cargo.lock")

printf 'Sysemble P0-a acceptance (SA-verify)\n'
printf '  repo:  %s\n' "$ROOT"
printf '  head:  %s\n' "$GIT_HEAD"
printf '  tmp:   %s\n' "$TMP"
printf '  cargo: %s\n' "$("$CARGO" --version 2>/dev/null || echo unknown)"
printf '  host:  %s\n' "$(uname -srm)"
printf '  date:  %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '\n'

# ---------------------------------------------------------------------------
# A1 - cargo test --workspace
# ---------------------------------------------------------------------------

A1_LOG="$TMP/a1.log"
( cd "$ROOT" && "$CARGO" test --workspace ) >"$A1_LOG" 2>&1
A1_RC=$?
if [ "$A1_RC" -eq 0 ] && ! grep -q 'test result: FAILED' "$A1_LOG"; then
  A1_TARGETS=$(grep -c '^test result: ok' "$A1_LOG" || true)
  A1_TESTS=$(awk '/^test result: ok\./ {
    for (i = 1; i <= NF; i++) if ($i == "passed;") print $(i - 1)
  }' "$A1_LOG" | awk '{ sum += $1 } END { print sum + 0 }')
  pass A1 "cargo test --workspace: exit 0, $A1_TESTS tests passed in $A1_TARGETS targets"
  note "CARGO_NET_OFFLINE=$CARGO_NET_OFFLINE"
  grep '^test result:' "$A1_LOG" | sed 's/^/         | /'
else
  fail A1 "cargo test --workspace failed (exit $A1_RC)"
  show_tail "$A1_LOG" 25
fi

# ---------------------------------------------------------------------------
# A2 / A3 - examples validate cleanly
# ---------------------------------------------------------------------------

check_validate() {
  id=$1
  file=$2
  log=$3
  cli validate "$file" >"$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && ! grep -q 'error\[' "$log"; then
    pass "$id" "validate $file: exit 0"
    if [ -s "$log" ]; then
      note "output: $(tr '\n' ' ' <"$log")"
    else
      note "no diagnostics"
    fi
  else
    fail "$id" "validate $file: exit $rc"
    show_tail "$log" 15
  fi
}

check_validate A2 examples/debian-kde-dev.yaml "$TMP/a2.log"
check_validate A3 examples/minimal-alpine.yaml "$TMP/a3.log"

# ---------------------------------------------------------------------------
# A4 - unknown field is rejected
# ---------------------------------------------------------------------------

A4_SPEC="$TMP/a4-bogus.yaml"
A4_LOG="$TMP/a4.log"
if cp "$ROOT/examples/debian-kde-dev.yaml" "$A4_SPEC" &&
  printf '\nbogus: 1\n' >>"$A4_SPEC"; then
  cli validate "$A4_SPEC" >"$A4_LOG" 2>&1
  A4_RC=$?
  if [ "$A4_RC" -eq 1 ] && grep -q 'bogus' "$A4_LOG"; then
    pass A4 "example + 'bogus: 1': exit 1, diagnostic names bogus"
    grep -m1 'bogus' "$A4_LOG" | sed 's/^/         | /'
  else
    fail A4 "unknown field: exit $A4_RC (want 1) or stderr does not name bogus"
    show_tail "$A4_LOG" 15
  fi
else
  fail A4 "could not build the temporary bogus spec"
fi

# ---------------------------------------------------------------------------
# A5 / A6 - plan JSON shape and content
# ---------------------------------------------------------------------------

REAL_PLAN="$TMP/plan.json"
A5_LOG="$TMP/a5.log"
cli plan examples/debian-kde-dev.yaml >"$REAL_PLAN" 2>"$A5_LOG"
A5_RC=$?
if [ "$A5_RC" -eq 0 ] &&
  jq -e '(.apiVersion == "sysemble/plan/v1")
         and ((.packages | type) == "array") and ((.packages | length) > 0)
         and ((.estimates | type) == "object")' "$REAL_PLAN" >/dev/null 2>&1; then
  pass A5 "plan: exit 0, valid JSON with apiVersion/packages/estimates"
  note "jq parse OK: $(jq -c '{apiVersion, packages: (.packages | length), estimates}' "$REAL_PLAN")"
  [ -s "$A5_LOG" ] && note "stderr: $(tr '\n' ' ' <"$A5_LOG")"
else
  fail A5 "plan: exit $A5_RC or missing apiVersion/packages/estimates"
  show_tail "$A5_LOG" 15
fi

A6_MISSING=""
for pkg in plasma-desktop sddm firefox-esr; do
  if ! jq -e --arg p "$pkg" '(.packages | index($p)) != null' "$REAL_PLAN" >/dev/null 2>&1; then
    A6_MISSING="$A6_MISSING $pkg"
  fi
done
if [ -z "$A6_MISSING" ]; then
  pass A6 "plan packages contain plasma-desktop, sddm, firefox-esr"
  note "found: $(jq -c '[.packages[] | select(. == "plasma-desktop" or . == "sddm" or . == "firefox-esr")]' "$REAL_PLAN")"
  note "workplan A6 says 'firefox'; Debian maps that to firefox-esr (task A6 expects firefox-esr)"
else
  fail A6 "plan is missing package(s):$A6_MISSING"
fi

# ---------------------------------------------------------------------------
# A7 - python schema validator (BLOCKED when deps are absent)
# ---------------------------------------------------------------------------

A7_LOG="$TMP/a7.log"
( cd "$ROOT" && python3 tools/validate.py ) >"$A7_LOG" 2>&1
A7_RC=$?
if grep -q 'missing dependencies' "$A7_LOG"; then
  A7_DEPS=$(python3 -c 'import jsonschema, yaml' 2>&1 | tail -n 1)
  blocked A7 "python3 tools/validate.py: exit $A7_RC, dependencies missing; not installing"
  note "error: $(grep -m1 'missing dependencies' "$A7_LOG")"
  note "$A7_DEPS"
elif [ "$A7_RC" -eq 0 ] && grep -q 'all specs valid' "$A7_LOG" && ! grep -q '^FAIL' "$A7_LOG"; then
  pass A7 "python3 tools/validate.py: exit 0, all specs ok"
  grep -E '^(ok|FAIL)' "$A7_LOG" | sed 's/^/         | /'
else
  fail A7 "python3 tools/validate.py: exit $A7_RC"
  show_tail "$A7_LOG" 20
fi

# ---------------------------------------------------------------------------
# A8 - builder dry-run against the contract fixture
# ---------------------------------------------------------------------------

FIXTURE_PLAN="$ROOT/builders/debian/testdata/plan.example.json"
A8_OUT="$TMP/a8-out"
A8_LOG="$TMP/a8.log"
( cd "$ROOT" && bash builders/debian/build.sh \
  --plan "$FIXTURE_PLAN" --out "$A8_OUT" --dry-run ) >"$A8_LOG" 2>&1
A8_RC=$?
A8_STAGES=$(grep -c '^  \[[1-6]/6\]' "$A8_LOG" || true)
A8_MISSING_STAGES=""
for n in 1 2 3 4 5 6; do
  grep -q "^  \[$n/6\]" "$A8_LOG" || A8_MISSING_STAGES="$A8_MISSING_STAGES $n"
done
if [ "$A8_RC" -eq 0 ] && [ "$A8_STAGES" -eq 6 ] && [ -z "$A8_MISSING_STAGES" ] &&
  grep -q 'Dry run complete: no image was built' "$A8_LOG"; then
  pass A8 "dry-run (fixture): exit 0, printed all 6 stages"
  grep '^  \[[1-6]/6\]' "$A8_LOG" | sed 's/^/         | /'
  note "fixture packages: $(sed -n 's/^Packages (\([0-9][0-9]*\)):$/\1/p' "$A8_LOG")"
else
  fail A8 "dry-run (fixture): exit $A8_RC, stages $A8_STAGES/6, missing:$A8_MISSING_STAGES"
  show_tail "$A8_LOG" 25
fi

# ---------------------------------------------------------------------------
# A9 - native engine is refused on macOS and creates no output directory
# ---------------------------------------------------------------------------

A9_OUT="$TMP/a9-out"
A9_LOG="$TMP/a9.log"
rm -rf "$A9_OUT"
( cd "$ROOT" && bash builders/debian/build.sh \
  --plan "$FIXTURE_PLAN" --out "$A9_OUT" ) >"$A9_LOG" 2>&1
A9_RC=$?
if [ "$A9_RC" -eq 3 ] && [ ! -e "$A9_OUT" ] &&
  grep -q 'native engine requires Linux' "$A9_LOG"; then
  pass A9 "native build without --dry-run: exit 3, no out directory created"
  grep -E 'native engine requires|error:' "$A9_LOG" | sed 's/^/         | /'
  note "out directory exists after run: no ($A9_OUT)"
else
  fail A9 "native refusal: exit $A9_RC (want 3), out exists=$([ -e "$A9_OUT" ] && echo yes || echo no)"
  show_tail "$A9_LOG" 20
fi

# ---------------------------------------------------------------------------
# B1 - real plan -> builder dry-run (not the fixture)
# ---------------------------------------------------------------------------

B1_PLAN="$TMP/b1-plan.json"
B1_OUT="$TMP/b1-out"
B1_LOG="$TMP/b1.log"
cli plan examples/debian-kde-dev.yaml >"$B1_PLAN" 2>"$TMP/b1-plan.err"
B1_RC=$?
if [ "$B1_RC" -eq 0 ] && jq -e '(.packages | type) == "array"' "$B1_PLAN" >/dev/null 2>&1; then
  B1_PLAN_N=$(jq '.packages | length' "$B1_PLAN")
  ( cd "$ROOT" && bash builders/debian/build.sh \
    --plan "$B1_PLAN" --out "$B1_OUT" --dry-run ) >"$B1_LOG" 2>&1
  B1_BUILD_RC=$?
  B1_BUILDER_N=$(sed -n 's/^Packages (\([0-9][0-9]*\)):$/\1/p' "$B1_LOG")
  awk '/^Packages \([0-9]+\):$/ { in_packages = 1; next }
       in_packages && /^  - / { print substr($0, 5); next }
       in_packages && /^$/ { exit }' "$B1_LOG" >"$TMP/b1-builder-packages.txt"
  jq -r '.packages[]' "$B1_PLAN" >"$TMP/b1-plan-packages.txt"
  B1_LIST_DIFF=$(diff -u "$TMP/b1-plan-packages.txt" "$TMP/b1-builder-packages.txt" 2>&1 || true)
  B1_OK=0
  if [ "$B1_BUILD_RC" -eq 0 ] && [ -n "$B1_BUILDER_N" ] &&
    [ "$B1_PLAN_N" -eq "$B1_BUILDER_N" ] &&
    [ -z "$B1_LIST_DIFF" ] &&
    grep -q "install packages  $B1_PLAN_N packages via --include" "$B1_LOG"; then
    B1_OK=1
  fi
  if [ "$B1_OK" -eq 1 ]; then
    pass B1 "real plan -> builder: exit 0, $B1_BUILDER_N packages == plan $B1_PLAN_N (fixture regenerated from the same plan)"
    note "plan stderr: $(tr '\n' ' ' <"$TMP/b1-plan.err")"
    grep -E 'install packages|^Packages \(' "$B1_LOG" | sed 's/^/         | /'
    note "builder package list is byte-identical to plan.packages"
  else
    fail B1 "real plan -> builder: builder exit $B1_BUILD_RC, plan=$B1_PLAN_N builder=${B1_BUILDER_N:-?}"
    printf '%s\n' "$B1_LIST_DIFF" | sed -n '1,20p' | sed 's/^/         | /'
    show_tail "$B1_LOG" 20
  fi
else
  fail B1 "could not obtain a real plan from the CLI (exit $B1_RC)"
  show_tail "$TMP/b1-plan.err" 10
  B1_PLAN_N=0
fi

# ---------------------------------------------------------------------------
# B2 - plan output is deterministic (byte-identical stdout)
# ---------------------------------------------------------------------------

cli plan examples/debian-kde-dev.yaml >"$TMP/b2-1.json" 2>"$TMP/b2-1.err"
B2_RC1=$?
cli plan examples/debian-kde-dev.yaml >"$TMP/b2-2.json" 2>"$TMP/b2-2.err"
B2_RC2=$?
if [ "$B2_RC1" -eq 0 ] && [ "$B2_RC2" -eq 0 ] &&
  cmp -s "$TMP/b2-1.json" "$TMP/b2-2.json"; then
  B2_HASH=$(hash_file "$TMP/b2-1.json")
  pass B2 "two consecutive plans: stdout byte-identical"
  note "sha256: $B2_HASH"
  note "bytes: $(wc -c <"$TMP/b2-1.json" | tr -d ' ')"
else
  fail B2 "plan determinism: exits $B2_RC1/$B2_RC2, cmp=$(cmp -s "$TMP/b2-1.json" "$TMP/b2-2.json" && echo same || echo differ)"
fi

# ---------------------------------------------------------------------------
# B3 - wrong apiVersion is rejected with a readable diagnostic
# ---------------------------------------------------------------------------

B3_SPEC="$TMP/b3-v2.yaml"
B3_LOG="$TMP/b3.log"
sed 's|^apiVersion: sysemble/v1$|apiVersion: sysemble/v2|' \
  "$ROOT/examples/debian-kde-dev.yaml" >"$B3_SPEC"
if grep -q '^apiVersion: sysemble/v2$' "$B3_SPEC"; then
  cli validate "$B3_SPEC" >"$B3_LOG" 2>&1
  B3_RC=$?
  if [ "$B3_RC" -eq 1 ] && grep -q 'unsupported apiVersion' "$B3_LOG" &&
    grep -q 'sysemble/v2' "$B3_LOG" && grep -q 'error\[' "$B3_LOG"; then
    pass B3 "apiVersion sysemble/v2: exit 1, readable diagnostic"
    grep -m1 'unsupported apiVersion' "$B3_LOG" | sed 's/^/         | /'
  else
    fail B3 "apiVersion sysemble/v2: exit $B3_RC or unreadable diagnostic"
    show_tail "$B3_LOG" 10
  fi
else
  fail B3 "could not rewrite apiVersion in the temporary spec"
fi

# ---------------------------------------------------------------------------
# B4 - dangerous --out is refused before any write
# ---------------------------------------------------------------------------

B4_LOG="$TMP/b4.log"
if [ -e /plan.copy.json ]; then
  fail B4 "/plan.copy.json existed before the test; cannot prove no-write"
else
  ( cd "$ROOT" && bash builders/debian/build.sh \
    --plan "$FIXTURE_PLAN" --out / --dry-run ) >"$B4_LOG" 2>&1
  B4_RC=$?
  if [ "$B4_RC" -eq 2 ] && grep -q "refusing --out '/'" "$B4_LOG" &&
    [ ! -e /plan.copy.json ]; then
    pass B4 "--out /: exit 2, refused, no write"
    grep 'refusing --out' "$B4_LOG" | sed 's/^/         | /'
    note "/plan.copy.json exists after run: no"
  else
    fail B4 "--out /: exit $B4_RC (want 2) or /plan.copy.json was created"
    show_tail "$B4_LOG" 10
  fi
fi

# ---------------------------------------------------------------------------
# B5 - validate --json on a warning-only spec: valid JSON array, exit 0
# ---------------------------------------------------------------------------

B5_SPEC="$TMP/b5-warning.yaml"
B5_JSON="$TMP/b5.json"
B5_LOG="$TMP/b5.log"
cat >"$B5_SPEC" <<'YAML'
apiVersion: sysemble/v1
meta:
  name: warning-spec
target:
  base:
    kind: debian
  arch: x86_64
  output: [qcow2]
system:
  hostname: warning-spec
YAML
cli validate "$B5_SPEC" --json >"$B5_JSON" 2>"$B5_LOG"
B5_RC=$?
B5_JSON_RC=1
python3 -m json.tool <"$B5_JSON" >/dev/null 2>&1 && B5_JSON_RC=0
if [ "$B5_RC" -eq 0 ] && [ "$B5_JSON_RC" -eq 0 ] &&
  jq -e '((type) == "array") and ((length) > 0)
         and (.[0].severity == "warning")' "$B5_JSON" >/dev/null 2>&1; then
  pass B5 "validate --json (warning spec): exit 0, valid JSON array"
  note "python3 -m json.tool: OK"
  note "payload: $(jq -c . "$B5_JSON")"
else
  fail B5 "validate --json: exit $B5_RC, json.tool=$B5_JSON_RC, or wrong shape"
  show_tail "$B5_LOG" 10
fi

# ---------------------------------------------------------------------------
# B6 - dry-run leaves only plan.copy.json (no rootfs, no images)
# ---------------------------------------------------------------------------

B6_ERR=""
check_dry_run_out() {
  label=$1
  dir=$2
  src=$3

  if [ ! -d "$dir" ]; then
    B6_ERR="$B6_ERR $label:missing-out"
    return
  fi
  extras=$(find "$dir" -mindepth 1 -maxdepth 1 ! -name plan.copy.json -print 2>/dev/null)
  [ -z "$extras" ] || B6_ERR="$B6_ERR $label:extra($(printf '%s' "$extras" | tr '\n' ' '))"
  [ -f "$dir/plan.copy.json" ] || B6_ERR="$B6_ERR $label:no-plan-copy"
  cmp -s "$dir/plan.copy.json" "$src" || B6_ERR="$B6_ERR $label:plan-copy-differs"
  [ ! -e "$dir/rootfs" ] || B6_ERR="$B6_ERR $label:rootfs-present"
  images=$(find "$dir" -type f \( -name '*.qcow2' -o -name '*.iso' -o -name '*.img' -o -name '*.raw' \) -print 2>/dev/null)
  [ -z "$images" ] || B6_ERR="$B6_ERR $label:image($(printf '%s' "$images" | tr '\n' ' '))"
}

check_dry_run_out A8 "$A8_OUT" "$FIXTURE_PLAN"
check_dry_run_out B1 "$B1_OUT" "$B1_PLAN"
if [ -z "$B6_ERR" ]; then
  pass B6 "dry-run outputs: only plan.copy.json (byte-identical), no rootfs/images"
  note "A8: $(find "$A8_OUT" -mindepth 1 -maxdepth 1 -print | sed "s|$A8_OUT/||")"
  note "B1: $(find "$B1_OUT" -mindepth 1 -maxdepth 1 -print | sed "s|$B1_OUT/||")"
else
  fail B6 "dry-run output contents:$B6_ERR"
fi

# ---------------------------------------------------------------------------
# B7 - fixture vs real plan divergence is recorded as a risk
# ---------------------------------------------------------------------------

if [ -s "$B1_PLAN" ] && [ -s "$FIXTURE_PLAN" ]; then
  B7_FIX_N=$(jq '.packages | length' "$FIXTURE_PLAN" 2>/dev/null)
  B7_FIX_MB=$(jq '.estimates.image_mb' "$FIXTURE_PLAN" 2>/dev/null)
  B7_REAL_N=$(jq '.packages | length' "$B1_PLAN" 2>/dev/null)
  B7_REAL_MB=$(jq '.estimates.image_mb' "$B1_PLAN" 2>/dev/null)
  jq -r '.packages[]' "$FIXTURE_PLAN" 2>/dev/null | LC_ALL=C sort >"$TMP/b7-fixture-pkgs.txt"
  jq -r '.packages[]' "$B1_PLAN" 2>/dev/null | LC_ALL=C sort >"$TMP/b7-real-pkgs.txt"
  B7_FIX_ONLY=$(LC_ALL=C comm -23 "$TMP/b7-fixture-pkgs.txt" "$TMP/b7-real-pkgs.txt" | wc -l | tr -d ' ')
  B7_REAL_ONLY=$(LC_ALL=C comm -13 "$TMP/b7-fixture-pkgs.txt" "$TMP/b7-real-pkgs.txt" | wc -l | tr -d ' ')
  B7_FIX_MODS=$(jq '.modules | length' "$FIXTURE_PLAN" 2>/dev/null)
  B7_REAL_MODS=$(jq '.modules | length' "$B1_PLAN" 2>/dev/null)
  B7_FIX_WARNS=$(jq '.warnings | length' "$FIXTURE_PLAN" 2>/dev/null)
  B7_REAL_WARNS=$(jq '.warnings | length' "$B1_PLAN" 2>/dev/null)
  if [ -n "$B7_FIX_N" ] && [ -n "$B7_REAL_N" ]; then
    pass B7 "fixture/real divergence measured; recorded as a risk (not a failure)"
    note "fixture: ${B7_FIX_N} packages / ${B7_FIX_MB} MB / ${B7_FIX_MODS} modules / ${B7_FIX_WARNS} warnings"
    note "real:    ${B7_REAL_N} packages / ${B7_REAL_MB} MB / ${B7_REAL_MODS} modules / ${B7_REAL_WARNS} warnings"
    note "package-set delta: fixture-only=${B7_FIX_ONLY}, real-only=${B7_REAL_ONLY}"
    if [ "$B7_FIX_ONLY" -eq 0 ] && [ "$B7_REAL_ONLY" -eq 0 ]; then
      note "fixture was regenerated from the real plan; no divergence"
    else
      note "RISK: fixture diverges from the real plan:"
      note "      fixture-only packages: $(LC_ALL=C comm -23 "$TMP/b7-fixture-pkgs.txt" "$TMP/b7-real-pkgs.txt" | tr '\n' ' ')"
      note "      real-only packages:    $(LC_ALL=C comm -13 "$TMP/b7-fixture-pkgs.txt" "$TMP/b7-real-pkgs.txt" | tr '\n' ' ')"
    fi
  else
    fail B7 "could not read package/estimate counts for the comparison"
  fi
else
  fail B7 "B7 needs both the fixture and a real plan; one is missing"
fi

# ---------------------------------------------------------------------------
# A10 - work tree unchanged by the run; deliveries only in expected directories
# ---------------------------------------------------------------------------

A10_STATUS_END="$TMP/git-end.txt"
A10_DIFF_END="$TMP/git-diff-end.txt"
git -C "$ROOT" status --porcelain -uall >"$A10_STATUS_END" 2>/dev/null || true
git -C "$ROOT" diff --no-ext-diff >"$A10_DIFF_END" 2>/dev/null || true
LOCK_END=$(hash_file "$ROOT/Cargo.lock")

A10_ERR=""
cmp -s "$GIT_START" "$A10_STATUS_END" || A10_ERR="$A10_ERR git-status-changed"
cmp -s "$GIT_DIFF_START" "$A10_DIFF_END" || A10_ERR="$A10_ERR tracked-diff-changed"
[ "$LOCK_START" = "$LOCK_END" ] || A10_ERR="$A10_ERR Cargo.lock-changed"
# P0-b: the one reviewed example addition is allowed; spec/ and other examples stay frozen.
grep -E '^.. (spec|examples)/' "$A10_STATUS_END" | grep -vE '^.. examples/(minimal-debian|debian-xfce|minimal-debian-live)\.yaml$' | grep -q . && A10_ERR="$A10_ERR frozen-dir-touched"

A10_OUTSIDE=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  path=$(printf '%s\n' "$line" | cut -c4-)
  case "$path" in
    Cargo.lock | README.md | .gitignore | \
      crates/sysemble-core/* | crates/sysemble-cli/* | \
      builders/* | docs/plan/* | \
      tools/* | .github/workflows/* | examples/minimal-debian.yaml | examples/debian-xfce.yaml | examples/minimal-debian-live.yaml | \
      apps/desktop/* | engine/* | docs/roadmap.md | docs/design/* | \
      tests/acceptance/* | docs/acceptance/*)
      ;;
    *)
      A10_OUTSIDE="$A10_OUTSIDE $path"
      ;;
  esac
done <"$A10_STATUS_END"

if [ -z "$A10_ERR" ] && [ -z "$A10_OUTSIDE" ]; then
  pass A10 "work tree stable; all changes confined to expected directories"
  note "git status entries: $(wc -l <"$A10_STATUS_END" | tr -d ' ') (unchanged before/after the run)"
  note "Cargo.lock sha256 unchanged: $LOCK_END"
  note "frozen spec/ and examples/ untouched"
  note "allowed dirs: crates/sysemble-{core,cli}/, builders/, docs/plan/, docs/design/, tests/acceptance/, docs/acceptance/, apps/desktop/, engine/, Cargo.lock"
else
  fail A10 "work-tree check:$A10_ERR outside:$A10_OUTSIDE"
  diff -u "$GIT_START" "$A10_STATUS_END" 2>/dev/null | sed -n '1,30p' | sed 's/^/         | /'
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\nSUMMARY: %d passed, %d failed, %d blocked\n' "$PASSES" "$FAILS" "$BLOCKED"
if [ -n "$FAILED_IDS" ]; then
  printf 'FAILED:%s\n' "$FAILED_IDS"
fi
if [ "$FAILS" -ne 0 ]; then
  printf 'RESULT: FAIL\n'
  exit 1
fi
if [ "$BLOCKED" -ne 0 ]; then
  printf 'RESULT: PASS (with %d blocked check(s) - see above)\n' "$BLOCKED"
else
  printf 'RESULT: PASS\n'
fi
exit 0
