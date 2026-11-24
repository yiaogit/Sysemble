#!/usr/bin/env bash
# Build and ad-hoc sign the Sysemble macOS VM helper (P1-e3b).
#
#   bash engine/vm/macos/build.sh [--debug]
#
# The helper needs the com.apple.security.virtualization entitlement even for
# local development. This script signs the SwiftPM product ad-hoc ("-") with
# sysemble-vm.entitlements and verifies the entitlement is present. It does not
# notarize or distribute the binary; that is out of scope for P1-e3.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
CONFIG=release

usage() {
  cat <<'EOF'
Usage: bash engine/vm/macos/build.sh [--debug]

Builds the sysemble-vm SwiftPM executable (release by default), ad-hoc signs
it with sysemble-vm.entitlements, verifies com.apple.security.virtualization,
and prints the binary path.

  --debug   build the debug configuration instead of release
  --help    show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --debug)
      CONFIG=debug
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift not found; install the Xcode Command Line Tools" >&2
  exit 1
fi
if ! command -v codesign >/dev/null 2>&1; then
  echo "error: codesign not found; install the Xcode Command Line Tools" >&2
  exit 1
fi
if [ ! -f "$DIR/sysemble-vm.entitlements" ]; then
  echo "error: missing $DIR/sysemble-vm.entitlements" >&2
  exit 1
fi

# Keep clang's module cache inside .build. Besides being tidy, this lets the
# script run under a restricted host sandbox that cannot write to the default
# ~/Library or /var/folders cache locations.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$DIR/.build/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

echo "swift: $(swift --version 2>/dev/null | head -n 1)"
echo "package: $DIR"
echo "configuration: $CONFIG"

# The package has no dependencies and no build plugins, so SwiftPM's build
# sandbox has nothing to isolate. Disabling it also makes the build work when
# this script is itself run inside another sandbox (CI containers, agent
# sandboxes), where nested sandbox_apply is denied.
swift build -c "$CONFIG" --disable-sandbox --package-path "$DIR"

BIN_DIR=$(swift build -c "$CONFIG" --disable-sandbox --package-path "$DIR" --show-bin-path)
BIN="$BIN_DIR/sysemble-vm"
if [ ! -x "$BIN" ]; then
  echo "error: build succeeded but the executable is missing: $BIN" >&2
  exit 1
fi

codesign --force --sign - --entitlements "$DIR/sysemble-vm.entitlements" "$BIN"
codesign --verify "$BIN"

ENTITLEMENTS=$(codesign -d --entitlements - "$BIN" 2>&1 || true)
case "$ENTITLEMENTS" in
  *com.apple.security.virtualization*)
    ;;
  *)
    echo "error: signature does not contain com.apple.security.virtualization" >&2
    echo "$ENTITLEMENTS" >&2
    exit 1
    ;;
esac

SIZE=$(ls -lh "$BIN" | awk '{print $5}')
echo
echo "entitlements:"
echo "$ENTITLEMENTS"
echo
echo "binary: $BIN ($SIZE)"
