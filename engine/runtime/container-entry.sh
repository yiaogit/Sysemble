#!/usr/bin/env bash
# Sysemble engine container entry point (P1-e2b).
#
# Runs *inside* the engine image: executes the frozen Debian builder against a
# container-local output directory, then exports the top-level result files to
# the bind-mounted export directory.
#
# Why the indirection (added in P1-e2b after local evidence):
#   macOS APFS is case-insensitive by default. Debian packages contain paths
#   that differ only by case (e.g. /usr/share/man/man7/PAM.7.gz -> pam.7.gz).
#   When the builder writes the rootfs directly into a bind-mounted host
#   directory, dpkg creates that symlink and then resolves it to itself
#   ("Too many levels of symbolic links" / ELOOP), so mmdebstrap fails.
#   Building into the container's own (case-sensitive) filesystem and exporting
#   only the final top-level files keeps macOS usable. The exported files are
#   single artifacts (artifact.json, disk.img, disk.qcow2, *.iso, ...), so the
#   case-insensitive host filesystem cannot collide them.
#
# Contract (frozen, docs/plan/P1-e2-workplan.md section 2.3):
#   container-entry.sh --plan <plan> --out <dir> --export <dir> [--mode execute]
#     --plan    plan.json produced by `sysemble plan`; readable in the container
#     --out     container-local build output directory (case-sensitive)
#     --export  bind-mounted host directory receiving the final files
#     --mode    only `execute` is accepted; dry-run stays on the host
#
# Exit status: the builder's status (0 only when artifact.json was produced and
# exported). Usage errors exit 2.
#
# The script is executed by the engine image (`bash engine/runtime/...`), so it
# must stay bash 3.2-compatible: no mapfile, no associative arrays, no ${x,,}.

set -euo pipefail

PLAN=""
OUT=""
EXPORT=""
MODE="execute"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)

usage() {
  cat <<'EOF'
Usage: container-entry.sh --plan <plan.json> --out <dir> --export <dir> [--mode execute]

Runs builders/debian/build.sh inside the engine container and copies the
top-level output files (artifact.json, disk.img, disk.qcow2, *.iso, ...) to the
bind-mounted export directory. build.log is not exported: the runtime streams
the build output to the desktop's log file.
EOF
}

usage_error() {
  printf 'container-entry: error: %s\n' "$*" >&2
  usage >&2
  exit 2
}

die() {
  printf 'container-entry: error: %s\n' "$*" >&2
  exit 1
}

note() {
  printf 'container-entry: %s\n' "$*"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --plan)
        [ "$#" -ge 2 ] || usage_error "--plan requires a value"
        PLAN=$2
        shift 2
        ;;
      --out)
        [ "$#" -ge 2 ] || usage_error "--out requires a directory"
        OUT=$2
        shift 2
        ;;
      --export)
        [ "$#" -ge 2 ] || usage_error "--export requires a directory"
        EXPORT=$2
        shift 2
        ;;
      --mode)
        [ "$#" -ge 2 ] || usage_error "--mode requires a value"
        MODE=$2
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage_error "unknown argument: $1"
        ;;
    esac
  done

  [ -n "$PLAN" ] || usage_error "--plan is required"
  [ -n "$OUT" ] || usage_error "--out is required"
  [ -n "$EXPORT" ] || usage_error "--export is required"
  [ "$MODE" = "execute" ] ||
    usage_error "unsupported --mode '$MODE': only 'execute' runs in the engine container (dry-run stays on the host)"
}

validate() {
  [ -f "$PLAN" ] || die "plan not found: $PLAN (the desktop writes it before launching the engine)"
  [ -d "$EXPORT" ] || die "export directory not found: $EXPORT (bind-mount the host output directory)"
  [ -x "$REPO_ROOT/builders/debian/build.sh" ] ||
    die "builder not found or not executable: $REPO_ROOT/builders/debian/build.sh (is the repository mounted at /work?)"

  # The output directory must live inside the container: a bind-mounted out
  # directory on a case-insensitive host filesystem breaks Debian packages.
  case "$OUT" in
    /work | /work/*)
      die "refusing --out '$OUT': the output directory must be container-local (for example /out), not inside the read-only repository mount"
      ;;
    /export | /export/*)
      die "refusing --out '$OUT': the export directory only receives final files; build under /out"
      ;;
  esac
}

export_outputs() {
  mkdir -p "$EXPORT"
  local file=""
  local name=""
  local exported=0
  for file in "$OUT"/*; do
    [ -f "$file" ] || continue
    name=${file##*/}
    # The desktop already streams the builder log to <out>/build.log; copying
    # it back would truncate a file the host process still holds open.
    [ "$name" = "build.log" ] && continue
    if ! cp -f "$file" "$EXPORT/$name"; then
      die "cannot export $name to $EXPORT"
    fi
    exported=$((exported + 1))
    note "exported $name"
  done

  [ "$exported" -gt 0 ] || die "the builder produced no top-level files in $OUT"
  [ -s "$EXPORT/artifact.json" ] || die "artifact.json was not produced; the build reported success but is incomplete"
}

main() {
  parse_args "$@"
  validate

  note "build: $REPO_ROOT/builders/debian/build.sh --plan $PLAN --out $OUT --execute"
  bash "$REPO_ROOT/builders/debian/build.sh" --plan "$PLAN" --out "$OUT" --execute
  export_outputs
  note "build and export complete"
}

main "$@"
