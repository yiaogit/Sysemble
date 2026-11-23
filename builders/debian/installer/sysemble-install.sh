#!/bin/sh
# Sysemble installer: unattended backend (P0-d3) + serial TUI wizard (P0-e1).
#
# Contract (frozen by docs/plan/P0-d3-workplan.md and
# docs/plan/P0-e1-workplan.md):
#
#   sysemble-install [--disk DEV] [--hostname NAME] [--user NAME]
#                    [--password-file FILE] [--yes] [--tui] [--dry-run] [--auto]
#
#   - no --tui: unattended. Missing values fall back to sysemble.install= on
#     /proc/cmdline, then /dev/vda, hostname "sysemble", user "ops", and an
#     empty password (the account is locked with passwd -l).
#   - --tui: interactive wizard. When /dev/ttyS0 exists and is a tty the
#     prompts are read from/written to it directly (serial getty is stopped
#     first); otherwise stdin/stdout are used, which keeps local pipe tests
#     possible.
#   - --dry-run: log the command sequence, the answers, and the files that
#     would be written, but execute nothing destructive.
#   - exit codes: 0 success; 1 install failure; 2 usage/parameter/cancel;
#     3 non-root or non-Linux (checked only for a real install, so --dry-run
#     works on a developer laptop).
#
# The installer runs as a oneshot systemd unit on the live ISO:
#   - validates the target disk (refuses the live medium and mounted disks)
#   - creates GPT: p1 ESP (512 MiB, ef00), p2 root (rest, 8300)
#   - formats the ESP (vfat32/ESP) and root (ext4/SYMBLE)
#   - copies the live system with rsync, writes /etc/fstab, /etc/hostname,
#     /etc/hosts, creates the user and sets/locks the password, and installs
#     GRUB to the ESP with --removable
#   - on success prints "SYMBLE: install complete" and powers off; on failure
#     prints "SYMBLE: install failed: <reason>" and exits 1 WITHOUT powering
#     off so the live journal/console can be inspected.
#
# A TUI ISO boots with sysemble.install.tui=1 instead of sysemble.install=;
# the script auto-enables --tui for that cmdline marker (the systemd unit is
# the shared P0-d3 unit). --auto overrides the marker and stays unattended.
#
# Testability (all optional, production defaults):
#   SYMBLE_CMDLINE_FILE  kernel cmdline source      (default /proc/cmdline)
#   SYMBLE_ROOT          live root to copy           (default /)
#   SYMBLE_MNT           install target mountpoint   (default /mnt)
#   SYMBLE_CONSOLE       marker output                (default /dev/ttyS0)
#   SYMBLE_LIVE_MEDIA    live medium device override
#   SYMBLE_TUI_DEVICE    wizard device                (default /dev/ttyS0)
#   SYMBLE_BLOCK_DEVICES comma-separated fake block devices for dry-run tests;
#                        when set, the TUI accepts exactly these disks.
#
# The script never writes a config to this live system except /mnt; the
# installed disk is the only persistent output.

set -eu

CMDLINE_FILE=${SYMBLE_CMDLINE_FILE:-/proc/cmdline}
ROOT_SRC=${SYMBLE_ROOT:-/}
MNT=${SYMBLE_MNT:-/mnt}
CONSOLE=${SYMBLE_CONSOLE:-/dev/ttyS0}
TUI_DEVICE=${SYMBLE_TUI_DEVICE:-/dev/ttyS0}

DRY_RUN=0
TUI=0
TUI_REQUESTED=0
AUTO_REQUESTED=0
ASSUME_YES=0

CLI_DISK=""
CMDLINE_DEVICE=""
CMDLINE_TUI=0
CLI_HOSTNAME=""
CLI_USER=""
PASSWORD_FILE=""
PASSWORD=""
PASSWORD_STATE="empty"
INSTALL_DEVICE=""
HOSTNAME=""
USER_NAME=""

TUI_FD=0
TUI_INPUT_IS_TTY=0
TUI_USING_SERIAL=0
TUI_READ_EOF=0
TUI_ANSWER=""
TUI_ECHO_OFF=0
TUI_STTY_SAVED=""
TUI_CR=$(printf '\r')

ROOT_MOUNTED=0
ESP_MOUNTED=0
BINDS_MOUNTED=0
FAILED=0

usage() {
  cat <<'USAGE'
Usage: sysemble-install [--disk DEV] [--hostname NAME] [--user NAME]
                        [--password-file FILE] [--yes] [--tui] [--dry-run]
                        [--auto]

Install the live Sysemble system to a disk.

Without --tui the installer is unattended: missing values fall back to
sysemble.install=<device> on the kernel cmdline (/dev/vda by default),
hostname "sysemble", user "ops", and an empty (locked) password.

Options:
  --disk DEV             target whole-disk device (e.g. /dev/vda)
  --hostname NAME        installed hostname (default sysemble)
  --user NAME            user to create (default ops)
  --password-file FILE   read the user's password from the first line of FILE;
                         an empty password leaves the account locked
  --yes                  skip the TUI confirmation prompt
  --tui                  run the serial/stdio install wizard
  --auto                 force unattended mode (also for a sysemble.install.tui=1
                         cmdline); mutually exclusive with --tui
  --dry-run              print the command sequence and answers; do not
                         partition, format, mount, write, or power off
  -h, --help             show this help and exit 0

TUI prompts (frozen, used by expect in CI):
  SYMBLE-TUI disk [/dev/vda]:
  SYMBLE-TUI hostname [sysemble]:
  SYMBLE-TUI user [ops]:
  SYMBLE-TUI password:
  SYMBLE-TUI confirm install to <disk> (yes/no):

Exit codes:
  0 success
  1 install failure
  2 usage/parameter error, or the TUI confirmation was not given
  3 not root or not Linux (real install only)

Environment overrides (diagnostics/tests only):
  SYMBLE_CMDLINE_FILE, SYMBLE_ROOT, SYMBLE_MNT, SYMBLE_CONSOLE,
  SYMBLE_LIVE_MEDIA, SYMBLE_TUI_DEVICE, SYMBLE_BLOCK_DEVICES
USAGE
}

log() {
  printf 'sysemble-install: %s\n' "$*"
}

fail() {
  FAILED=1
  printf 'SYMBLE: install failed: %s\n' "$*" | tee "$CONSOLE" >&2 || true
  exit 1
}

# Usage/parameter errors and a refused TUI confirmation exit 2. They are not
# install failures, so no "SYMBLE: install failed" marker is printed and the
# EXIT trap must preserve the status instead of normalizing it to 1.
usage_fail() {
  printf 'sysemble-install: %s\n' "$*" >&2
  exit 2
}

# Environment/precondition errors (non-root, non-Linux) exit 3.
env_fail() {
  printf 'sysemble-install: %s\n' "$*" >&2
  exit 3
}

# Run a state-changing command, logging its argv first. In --dry-run the
# command is only printed. A failing command reports a specific reason.
run() {
  reason=$1
  shift
  printf '+ %s\n' "$*"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  "$@" || fail "$reason"
}

# Best-effort command (getty stop, udevadm settle, cleanup umounts): log it,
# execute only outside --dry-run, and ignore failures.
run_soft() {
  printf '+ %s\n' "$*"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  "$@" >/dev/null 2>&1 || true
}

# Run a command with one line on stdin (chpasswd). The line is never logged,
# because it contains the password.
run_feed() {
  reason=$1
  input=$2
  shift 2
  printf '+ %s\n' "$*"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  printf '%s\n' "$input" | "$@" || fail "$reason"
}

# Read-only probe (used to skip useradd when the account exists). In dry-run
# it reports "not present" so the plan still shows the useradd command.
probe() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return 1
  fi
  "$@" >/dev/null 2>&1
}

# Resolve a partition (or whole disk) to its parent disk name, e.g.
# /dev/vda2 -> /dev/vda, /dev/nvme0n1p1 -> /dev/nvme0n1. Used only to refuse
# the live medium; it is best-effort and never touches the device.
base_disk() {
  disk=$1
  if [ -e "$disk" ]; then
    resolved=$(readlink -f "$disk" 2>/dev/null || true)
    if [ -n "$resolved" ]; then
      disk=$resolved
    fi
  fi
  name=${disk##*/}
  case "$name" in
    nvme* | mmcblk*)
      case "$name" in
        *p[0-9]*) name=${name%p*} ;;
        *) : ;;
      esac
      ;;
    *[0-9])
      name=${name%%[0-9]*}
      ;;
  esac
  printf '/dev/%s\n' "$name"
}

# Mounts owned by this run, torn down on both success and error. The order is
# reverse of the mount order so a nested bind mount is released before its
# parent filesystem.
cleanup_mounts() {
  if [ "$BINDS_MOUNTED" -eq 1 ]; then
    for suffix in run dev sys proc; do
      run_soft umount "$MNT/$suffix"
    done
    BINDS_MOUNTED=0
  fi
  if [ "$ESP_MOUNTED" -eq 1 ]; then
    run_soft umount "$MNT/boot/efi"
    ESP_MOUNTED=0
  fi
  if [ "$ROOT_MOUNTED" -eq 1 ]; then
    run_soft umount "$MNT"
    ROOT_MOUNTED=0
  fi
}

on_exit() {
  status=$?
  # Argument/environment errors can exit before the TUI helpers are defined.
  if command -v tui_echo_restore >/dev/null 2>&1; then
    tui_echo_restore
  fi
  if [ "$TUI_FD" -eq 3 ]; then
    exec 3>&- 2>/dev/null || true
  fi
  if [ "$status" -ne 0 ]; then
    cleanup_mounts
    case "$status" in
      2 | 3)
        # Usage/cancel (2) and environment (3) errors already explained
        # themselves; keep the frozen exit code and print no install marker.
        trap - EXIT
        exit "$status"
        ;;
    esac
    if [ "$FAILED" -eq 0 ]; then
      FAILED=1
      printf 'SYMBLE: install failed: installer exited with status %s\n' "$status" |
        tee "$CONSOLE" >&2 || true
    fi
    # The frozen contract says a failed install exits 1 (never poweroff), so
    # normalize every unwrapped command/signal failure to that status.
    trap - EXIT
    exit 1
  fi
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

need_value() {
  option=$1
  count=$2
  if [ "$count" -lt 2 ]; then
    printf 'sysemble-install: %s requires a value\n' "$option" >&2
    usage >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --disk)
      need_value --disk "$#"
      CLI_DISK=$2
      shift 2
      ;;
    --disk=*)
      CLI_DISK=${1#--disk=}
      shift
      ;;
    --hostname)
      need_value --hostname "$#"
      CLI_HOSTNAME=$2
      shift 2
      ;;
    --hostname=*)
      CLI_HOSTNAME=${1#--hostname=}
      shift
      ;;
    --user)
      need_value --user "$#"
      CLI_USER=$2
      shift 2
      ;;
    --user=*)
      CLI_USER=${1#--user=}
      shift
      ;;
    --password-file)
      need_value --password-file "$#"
      PASSWORD_FILE=$2
      shift 2
      ;;
    --password-file=*)
      PASSWORD_FILE=${1#--password-file=}
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    --tui)
      TUI_REQUESTED=1
      shift
      ;;
    --auto)
      AUTO_REQUESTED=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'sysemble-install: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$TUI_REQUESTED" -eq 1 ] && [ "$AUTO_REQUESTED" -eq 1 ]; then
  printf 'sysemble-install: --tui and --auto are mutually exclusive\n' >&2
  usage >&2
  exit 2
fi
if [ "$TUI_REQUESTED" -eq 1 ]; then
  TUI=1
fi

# ---------------------------------------------------------------------------
# Resolve defaults: explicit CLI > kernel cmdline > frozen defaults
# ---------------------------------------------------------------------------

if [ -r "$CMDLINE_FILE" ]; then
  CMDLINE=$(cat "$CMDLINE_FILE" 2>/dev/null || true)
  # Disable pathname expansion while splitting the cmdline on whitespace.
  set -f
  for word in $CMDLINE; do
    case "$word" in
      sysemble.install=*)
        CMDLINE_DEVICE=${word#sysemble.install=}
        ;;
      sysemble.install.tui=*)
        case "${word#sysemble.install.tui=}" in
          1 | yes | true | on) CMDLINE_TUI=1 ;;
        esac
        ;;
    esac
  done
  set +f
fi

# A TUI ISO boots with sysemble.install.tui=1 and uses the shared P0-d3 unit;
# the script switches to the wizard itself. An explicit --auto wins.
if [ "$CMDLINE_TUI" -eq 1 ] && [ "$AUTO_REQUESTED" -eq 0 ]; then
  TUI=1
fi

INSTALL_DEVICE=$CMDLINE_DEVICE
if [ -n "$CLI_DISK" ]; then
  INSTALL_DEVICE=$CLI_DISK
fi
if [ -z "$INSTALL_DEVICE" ]; then
  INSTALL_DEVICE=/dev/vda
fi

HOSTNAME=${CLI_HOSTNAME:-sysemble}
USER_NAME=${CLI_USER:-ops}

if [ -n "$PASSWORD_FILE" ]; then
  if [ ! -f "$PASSWORD_FILE" ] || [ ! -r "$PASSWORD_FILE" ]; then
    usage_fail "cannot read password file: $PASSWORD_FILE"
  fi
  PASSWORD=""
  IFS= read -r PASSWORD <"$PASSWORD_FILE" || true
  PASSWORD=${PASSWORD%"$TUI_CR"}
  if [ -n "$PASSWORD" ]; then
    PASSWORD_STATE=set
  else
    PASSWORD_STATE=empty
  fi
fi

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

valid_hostname() {
  value=$1
  if [ -z "$value" ] || [ "${#value}" -gt 63 ]; then
    return 1
  fi
  case "$value" in
    *[!A-Za-z0-9.-]*) return 1 ;;
  esac
  case "$value" in
    [A-Za-z0-9]*) : ;;
    *) return 1 ;;
  esac
  case "$value" in
    *[A-Za-z0-9]) : ;;
    *) return 1 ;;
  esac
  return 0
}

valid_user_name() {
  value=$1
  if [ -z "$value" ] || [ "${#value}" -gt 32 ]; then
    return 1
  fi
  case "$value" in
    [a-z_]*) : ;;
    *) return 1 ;;
  esac
  case "$value" in
    *[!a-z0-9_-]*) return 1 ;;
  esac
  return 0
}

# A whole-disk name that is plausible for the dry-run TUI, used only where a
# block device cannot exist (macOS dev host / pipe tests). Real installs
# never take this path: they require [ -b "$INSTALL_DEVICE" ] below.
is_plausible_dry_run_disk() {
  case "$1" in
    /dev/vd[a-z] | /dev/sd[a-z] | /dev/hd[a-z] | /dev/xvd[a-z] | /dev/nvme[0-9]n[0-9] | /dev/mmcblk[0-9])
      return 0
      ;;
  esac
  return 1
}

valid_tui_disk() {
  case "$1" in
    /dev/*) : ;;
    *) return 1 ;;
  esac
  case "$1" in
    /dev/sr* | /dev/loop* | /dev/fd* | /dev/dm-* | /dev/ram*)
      return 1
      ;;
  esac
  if [ -b "$1" ]; then
    return 0
  fi
  if [ -n "${SYMBLE_BLOCK_DEVICES:-}" ]; then
    case ",$SYMBLE_BLOCK_DEVICES," in
      *",$1,"*) return 0 ;;
    esac
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    is_plausible_dry_run_disk "$1"
    return $?
  fi
  return 1
}

if [ -n "$CLI_HOSTNAME" ] && ! valid_hostname "$CLI_HOSTNAME"; then
  usage_fail "invalid hostname: '$CLI_HOSTNAME'"
fi
if [ -n "$CLI_USER" ] && ! valid_user_name "$CLI_USER"; then
  usage_fail "invalid user name: '$CLI_USER'"
fi

# ---------------------------------------------------------------------------
# Environment preflight (real installs only; --dry-run must work anywhere)
# ---------------------------------------------------------------------------

if [ "$DRY_RUN" -eq 0 ]; then
  host_os=$(uname -s 2>/dev/null || true)
  if [ "$host_os" != "Linux" ]; then
    env_fail "sysemble-install requires Linux (host reports '${host_os:-unknown}')"
  fi
  euid=$(id -u 2>/dev/null || true)
  if [ "$euid" != "0" ]; then
    env_fail "sysemble-install requires root (euid is '${euid:-unknown}')"
  fi
fi

# ---------------------------------------------------------------------------
# TUI wizard
# ---------------------------------------------------------------------------

# True when <device> can be opened and is a terminal. tty(1) is the primary
# probe; stty -g is the fallback for a live image without coreutils' tty.
is_tty_device() {
  if command -v tty >/dev/null 2>&1; then
    if tty <"$1" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  if stty -g <"$1" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

tui_puts() {
  if [ "$TUI_FD" -eq 3 ]; then
    printf '%s' "$1" >&3
  else
    printf '%s' "$1"
  fi
}

tui_newline() {
  if [ "$TUI_FD" -eq 3 ]; then
    printf '\n' >&3
  else
    printf '\n'
  fi
}

# Read one line from the TUI device (fd 3) or stdin. A piped stdin has no
# terminal echo, so emit the newline the terminal would otherwise provide.
tui_read() {
  TUI_ANSWER=""
  TUI_READ_EOF=0
  if [ "$TUI_FD" -eq 3 ]; then
    if IFS= read -r TUI_ANSWER <&3; then :; else TUI_READ_EOF=1; fi
  else
    if IFS= read -r TUI_ANSWER; then :; else TUI_READ_EOF=1; fi
    if [ "$TUI_INPUT_IS_TTY" -eq 0 ]; then
      printf '\n'
    fi
  fi
  TUI_ANSWER=${TUI_ANSWER%"$TUI_CR"}
}

tui_echo_off() {
  if [ "$TUI_FD" -eq 3 ]; then
    TUI_STTY_SAVED=$(stty -g <&3 2>/dev/null || true)
    if [ -n "$TUI_STTY_SAVED" ] && stty -echo <&3 2>/dev/null; then
      TUI_ECHO_OFF=1
    fi
  elif [ "$TUI_INPUT_IS_TTY" -eq 1 ]; then
    TUI_STTY_SAVED=$(stty -g 2>/dev/null || true)
    if [ -n "$TUI_STTY_SAVED" ] && stty -echo 2>/dev/null; then
      TUI_ECHO_OFF=1
    fi
  fi
}

tui_echo_restore() {
  if [ "$TUI_ECHO_OFF" -ne 1 ]; then
    return 0
  fi
  if [ "$TUI_FD" -eq 3 ]; then
    if [ -n "$TUI_STTY_SAVED" ]; then
      stty "$TUI_STTY_SAVED" <&3 2>/dev/null || stty echo <&3 2>/dev/null || true
    else
      stty echo <&3 2>/dev/null || true
    fi
  else
    if [ -n "$TUI_STTY_SAVED" ]; then
      stty "$TUI_STTY_SAVED" 2>/dev/null || stty echo 2>/dev/null || true
    else
      stty echo 2>/dev/null || true
    fi
  fi
  TUI_ECHO_OFF=0
}

prepare_tui_device() {
  if [ -c "$TUI_DEVICE" ] && is_tty_device "$TUI_DEVICE"; then
    case "$TUI_DEVICE" in
      /dev/ttyS0)
        TUI_USING_SERIAL=1
        # The serial getty also owns ttyS0. Failures are explicitly ignored:
        # the wizard can still use the device if no getty is running.
        run_soft systemctl stop serial-getty@ttyS0.service
        ;;
    esac
    if exec 3<>"$TUI_DEVICE" 2>/dev/null; then
      if [ -t 3 ]; then
        TUI_FD=3
        TUI_INPUT_IS_TTY=1
      else
        exec 3>&- 2>/dev/null || true
      fi
    fi
  fi
  if [ "$TUI_FD" -eq 0 ] && [ -t 0 ]; then
    TUI_INPUT_IS_TTY=1
  fi
  if [ "$TUI_USING_SERIAL" -eq 1 ] && [ "$DRY_RUN" -eq 1 ]; then
    log "tui: using serial console $TUI_DEVICE (getty stop was only logged)"
  fi
}

tui_prompt() {
  label=$1
  default=$2
  if [ -n "$default" ]; then
    tui_puts "SYMBLE-TUI $label [$default]: "
  else
    tui_puts "SYMBLE-TUI $label: "
  fi
  tui_read
  if [ -z "$TUI_ANSWER" ]; then
    TUI_ANSWER=$default
  fi
}

tui_prompt_password() {
  default=$1
  tui_puts "SYMBLE-TUI password: "
  tui_echo_off
  tui_read
  tui_echo_restore
  # With echo off the terminal did not echo Return; piped stdin already got a
  # newline from tui_read.
  if [ "$TUI_INPUT_IS_TTY" -eq 1 ]; then
    tui_newline
  fi
  if [ -z "$TUI_ANSWER" ]; then
    TUI_ANSWER=$default
  fi
}

tui_cancel() {
  tui_puts "SYMBLE-TUI installation cancelled"
  tui_newline
  log "$*"
  exit 2
}

run_tui() {
  prepare_tui_device

  while :; do
    tui_prompt "disk" "$INSTALL_DEVICE"
    if valid_tui_disk "$TUI_ANSWER"; then
      INSTALL_DEVICE=$TUI_ANSWER
      break
    fi
    tui_puts "SYMBLE-TUI invalid disk '$TUI_ANSWER' (not a block device); try again"
    tui_newline
    if [ "$TUI_READ_EOF" -eq 1 ]; then
      tui_cancel "no usable install disk was given"
    fi
  done

  while :; do
    tui_prompt "hostname" "$HOSTNAME"
    if valid_hostname "$TUI_ANSWER"; then
      HOSTNAME=$TUI_ANSWER
      break
    fi
    tui_puts "SYMBLE-TUI invalid hostname '$TUI_ANSWER'; try again"
    tui_newline
    if [ "$TUI_READ_EOF" -eq 1 ]; then
      tui_cancel "no valid hostname was given"
    fi
  done

  while :; do
    tui_prompt "user" "$USER_NAME"
    if valid_user_name "$TUI_ANSWER"; then
      USER_NAME=$TUI_ANSWER
      break
    fi
    tui_puts "SYMBLE-TUI invalid user name '$TUI_ANSWER'; try again"
    tui_newline
    if [ "$TUI_READ_EOF" -eq 1 ]; then
      tui_cancel "no valid user name was given"
    fi
  done

  tui_prompt_password "$PASSWORD"
  PASSWORD=$TUI_ANSWER
  if [ -n "$PASSWORD" ]; then
    PASSWORD_STATE=set
  else
    PASSWORD_STATE=empty
  fi

  log "tui answers: disk=$INSTALL_DEVICE hostname=$HOSTNAME user=$USER_NAME password=$PASSWORD_STATE"

  if [ "$ASSUME_YES" -eq 1 ]; then
    log "tui: confirmation skipped (--yes)"
  else
    while :; do
      tui_puts "SYMBLE-TUI confirm install to $INSTALL_DEVICE (yes/no): "
      tui_read
      case "$TUI_ANSWER" in
        y | Y | yes | YES | Yes)
          break
          ;;
        '')
          # An empty line is not an answer (the frozen prompts are answered in
          # order; a blank line before "yes" must not confirm the install).
          if [ "$TUI_READ_EOF" -eq 1 ]; then
            tui_cancel "install was not confirmed (end of input)"
          fi
          ;;
        *)
          tui_cancel "install not confirmed (answer '$TUI_ANSWER')"
          ;;
      esac
    done
  fi
}

if [ "$TUI" -eq 1 ]; then
  run_tui
fi

if ! valid_hostname "$HOSTNAME"; then
  usage_fail "invalid hostname: '$HOSTNAME'"
fi
if ! valid_user_name "$USER_NAME"; then
  usage_fail "invalid user name: '$USER_NAME'"
fi
if [ -n "$PASSWORD" ]; then
  PASSWORD_STATE=set
else
  PASSWORD_STATE=empty
fi

log "configuration: disk=$INSTALL_DEVICE hostname=$HOSTNAME user=$USER_NAME password=$PASSWORD_STATE"

# ---------------------------------------------------------------------------
# 1. Resolve and validate the target device
# ---------------------------------------------------------------------------

case "$INSTALL_DEVICE" in
  /dev/*) : ;;
  *)
    fail "invalid install device '$INSTALL_DEVICE' (expected an absolute /dev path)"
    ;;
esac
case "$INSTALL_DEVICE" in
  /dev/sr* | /dev/loop* | /dev/fd* | /dev/dm-*)
    fail "refusing to install to optical/loop/ram device '$INSTALL_DEVICE'"
    ;;
esac

if [ "$DRY_RUN" -eq 0 ] && [ ! -b "$INSTALL_DEVICE" ]; then
  fail "not a block device: $INSTALL_DEVICE"
fi

# /dev/vda1 for virtio/sd/scsi, /dev/nvme0n1p1 for nvme/mmcblk.
ESP_DEV="${INSTALL_DEVICE}1"
ROOT_DEV="${INSTALL_DEVICE}2"
case "$INSTALL_DEVICE" in
  *[0-9])
    ESP_DEV="${INSTALL_DEVICE}p1"
    ROOT_DEV="${INSTALL_DEVICE}p2"
    ;;
esac

LIVE_MEDIA=${SYMBLE_LIVE_MEDIA:-}
if [ -r /proc/mounts ]; then
  while read -r mount_src mount_point mount_rest; do
    if [ "$mount_point" = "/run/live/medium" ]; then
      LIVE_MEDIA=$mount_src
      break
    fi
  done </proc/mounts
fi
if [ -n "$LIVE_MEDIA" ]; then
  TARGET_BASE=$(base_disk "$INSTALL_DEVICE")
  LIVE_BASE=$(base_disk "$LIVE_MEDIA")
  if [ "$TARGET_BASE" = "$LIVE_BASE" ]; then
    fail "refusing to install to the live medium: $INSTALL_DEVICE ($LIVE_MEDIA)"
  fi
fi

# Never install over a disk that is already in use. This also catches a live
# medium whose partition is not mounted at /run/live/medium.
if [ "$DRY_RUN" -eq 0 ] && [ -r /proc/mounts ]; then
  TARGET_BASE=$(base_disk "$INSTALL_DEVICE")
  while read -r mount_src mount_point mount_rest; do
    case "$mount_src" in
      /dev/*) : ;;
      *) continue ;;
    esac
    if [ "$(base_disk "$mount_src")" = "$TARGET_BASE" ]; then
      fail "refusing to install to $INSTALL_DEVICE: $mount_src is mounted at $mount_point"
    fi
  done </proc/mounts
fi

log "target device: $INSTALL_DEVICE (ESP $ESP_DEV, root $ROOT_DEV)"
log "root source: $ROOT_SRC, mountpoint: $MNT"
if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run: no command will be executed (only the exit marker is printed)"
fi

# ---------------------------------------------------------------------------
# 2. Partition and format (GPT: 512 MiB ESP + root)
# ---------------------------------------------------------------------------

log "step 1/8: partition $INSTALL_DEVICE"
run "sgdisk -Z failed" sgdisk -Z "$INSTALL_DEVICE"
run "sgdisk partition creation failed" \
  sgdisk -n 1:2048:+512M -t 1:ef00 -n 2:0:0 -t 2:8300 "$INSTALL_DEVICE"
# Let udev create /dev/vda1 and /dev/vda2 before mkfs/blkid race the kernel
# partition rescan. Best-effort: the live-boot environment normally has it.
if [ "$DRY_RUN" -eq 0 ] && command -v udevadm >/dev/null 2>&1; then
  run_soft udevadm settle
fi

log "step 2/8: format ESP and root"
run "mkfs.vfat failed" mkfs.vfat -F 32 -n ESP "$ESP_DEV"
run "mkfs.ext4 failed" mkfs.ext4 -F -L SYMBLE "$ROOT_DEV"

if [ "$DRY_RUN" -eq 1 ]; then
  ROOT_UUID=11111111-1111-1111-1111-111111111111
  ESP_UUID=22222222-2222-2222-2222-222222222222
  log "dry-run: blkid would read UUIDs from $ROOT_DEV and $ESP_DEV"
else
  ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)
  if [ -z "$ROOT_UUID" ]; then
    fail "cannot read the root filesystem UUID from $ROOT_DEV"
  fi
  ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV" 2>/dev/null || true)
  if [ -z "$ESP_UUID" ]; then
    fail "cannot read the ESP filesystem UUID from $ESP_DEV"
  fi
fi
log "root UUID: $ROOT_UUID"
log "ESP UUID:  $ESP_UUID"

# ---------------------------------------------------------------------------
# 3. Mount the target and bind the host pseudo-filesystems for grub-install
# ---------------------------------------------------------------------------

log "step 3/8: mount target and bind /proc /sys /dev /run"
run "cannot create the mountpoint $MNT" mkdir -p "$MNT"
run "mounting the root filesystem failed" mount "$ROOT_DEV" "$MNT"
ROOT_MOUNTED=1

run "cannot create $MNT/boot/efi" mkdir -p "$MNT/boot/efi"
run "mounting the ESP failed" mount "$ESP_DEV" "$MNT/boot/efi"
ESP_MOUNTED=1

run "cannot create the chroot pseudo-filesystem mountpoints" \
  mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev" "$MNT/run"
run "bind mount /proc failed" mount --bind /proc "$MNT/proc"
run "bind mount /sys failed" mount --bind /sys "$MNT/sys"
run "bind mount /dev failed" mount --bind /dev "$MNT/dev"
run "bind mount /run failed" mount --bind /run "$MNT/run"
BINDS_MOUNTED=1

# ---------------------------------------------------------------------------
# 4. Copy the live root
# ---------------------------------------------------------------------------

log "step 4/8: rsync $ROOT_SRC -> $MNT"
run "rsync copy failed" rsync -aHAX \
  --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
  --exclude=/tmp --exclude=/mnt --exclude=/media --exclude=/live \
  --exclude=/lost+found \
  "$ROOT_SRC" "$MNT/"

# ---------------------------------------------------------------------------
# 5. fstab and the installed GRUB configuration
# ---------------------------------------------------------------------------

log "step 5/8: write /etc/fstab"
if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run: /etc/fstab would contain:"
  printf 'UUID=%s / ext4 errors=remount-ro 0 1\n' "$ROOT_UUID"
  printf 'UUID=%s /boot/efi vfat umask=0077 0 1\n' "$ESP_UUID"
else
  run "cannot create $MNT/etc" mkdir -p "$MNT/etc"
  {
    printf '# /etc/fstab: static file system information.\n'
    printf '# installed by sysemble-install; UUIDs from mkfs/blkid.\n'
    printf 'UUID=%s / ext4 errors=remount-ro 0 1\n' "$ROOT_UUID"
    printf 'UUID=%s /boot/efi vfat umask=0077 0 1\n' "$ESP_UUID"
  } >"$MNT/etc/fstab" || fail "cannot write $MNT/etc/fstab"
fi

# ---------------------------------------------------------------------------
# 6. hostname, hosts, user, and password inside the installed system
# ---------------------------------------------------------------------------

log "step 6/8: configure hostname and user"
HOSTS_TEXT=$(
  printf '127.0.0.1 localhost\n'
  printf '127.0.1.1 %s\n' "$HOSTNAME"
  printf '::1 localhost ip6-localhost ip6-loopback\n'
  printf 'ff02::1 ip6-allnodes\n'
  printf 'ff02::2 ip6-allrouters\n'
)
if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run: $MNT/etc/hostname would contain: $HOSTNAME"
  log "dry-run: $MNT/etc/hosts would contain:"
  printf '%s\n' "$HOSTS_TEXT"
else
  printf '%s\n' "$HOSTNAME" >"$MNT/etc/hostname" ||
    fail "cannot write $MNT/etc/hostname"
  printf '%s\n' "$HOSTS_TEXT" >"$MNT/etc/hosts" ||
    fail "cannot write $MNT/etc/hosts"
  run "cannot set permissions on $MNT/etc/hostname" chmod 0644 "$MNT/etc/hostname"
  run "cannot set permissions on $MNT/etc/hosts" chmod 0644 "$MNT/etc/hosts"
fi

if probe chroot "$MNT" id -u "$USER_NAME"; then
  log "user already exists: $USER_NAME (skipping useradd)"
else
  run "useradd failed" chroot "$MNT" useradd -m -s /bin/bash -G sudo "$USER_NAME"
fi

if [ -n "$PASSWORD" ]; then
  run_feed "chpasswd failed" "$USER_NAME:$PASSWORD" chroot "$MNT" chpasswd
else
  run "passwd -l failed" chroot "$MNT" passwd -l "$USER_NAME"
fi

# Pick the highest kernel version by sort -V and require a matching initrd.
KERNEL_PATH=""
for candidate in "$MNT"/boot/vmlinuz-*; do
  if [ ! -f "$candidate" ]; then
    continue
  fi
  if [ -z "$KERNEL_PATH" ]; then
    KERNEL_PATH=$candidate
  else
    KERNEL_PATH=$(printf '%s\n%s\n' "$KERNEL_PATH" "$candidate" | sort -V | tail -n 1)
  fi
done
if [ -z "$KERNEL_PATH" ]; then
  fail "no kernel found under $MNT/boot (expected vmlinuz-*)"
fi
KERNEL_NAME=${KERNEL_PATH##*/}
KERNEL_VERSION=${KERNEL_NAME#vmlinuz-}
INITRD_NAME="initrd.img-$KERNEL_VERSION"
if [ ! -f "$MNT/boot/$INITRD_NAME" ]; then
  fail "no initrd found: $MNT/boot/$INITRD_NAME"
fi
log "kernel: $KERNEL_NAME, initrd: $INITRD_NAME"

log "step 7/8: install GRUB to the ESP and write /boot/grub/grub.cfg"
run "grub-install failed" chroot "$MNT" grub-install \
  --target=x86_64-efi --efi-directory=/boot/efi \
  --bootloader-id=sysemble --removable --no-nvram

write_grub_cfg() {
  printf 'set timeout=3\n'
  # grub-install's removable core may not embed serial.mod; load it from the
  # installed /boot/grub/x86_64-efi so GRUB's own messages reach ttyS0 (boot
  # check needs a GRUB marker before the kernel cmdline console=ttyS0 takes over).
  printf 'insmod serial\n'
  printf 'serial --unit=0 --speed=115200\n'
  printf 'terminal_input serial\n'
  printf 'terminal_output serial\n'
  printf 'menuentry "Sysemble" {\n'
  printf '  search --no-floppy --fs-uuid --set=root %s\n' "$ROOT_UUID"
  printf '  linux /boot/%s root=UUID=%s rw console=ttyS0 systemd.unit=multi-user.target\n' \
    "$KERNEL_NAME" "$ROOT_UUID"
  printf '  initrd /boot/%s\n' "$INITRD_NAME"
  printf '}\n'
}

if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run: /boot/grub/grub.cfg would contain:"
  write_grub_cfg
else
  run "cannot create $MNT/boot/grub" mkdir -p "$MNT/boot/grub"
  write_grub_cfg >"$MNT/boot/grub/grub.cfg" ||
    fail "cannot write $MNT/boot/grub/grub.cfg"
fi

# ---------------------------------------------------------------------------
# 7. Unmount and finish
# ---------------------------------------------------------------------------

log "step 8/8: unmount and finish"
cleanup_mounts

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'SYMBLE: install complete\n' | tee "$CONSOLE" || true
  run "systemctl poweroff -f failed" systemctl poweroff -f
  log "dry-run: would run: systemctl poweroff -f"
  exit 0
fi

printf 'SYMBLE: install complete\n' | tee "$CONSOLE" || true
run "systemctl poweroff -f failed" systemctl poweroff -f
