#!/usr/bin/env bash
# P0-d3 unattended installer tests.
#
# macOS has no Linux, root, block devices, sgdisk, mkfs.*, mount, chroot, or
# systemd, so this test does two things:
#   1. static assertions over builders/debian/installer/sysemble-install.sh and
#      sysemble-install.service (frozen commands, flags, excludes, markers);
#   2. a dynamic --dry-run of the real script with SYMBLE_* path overrides,
#      asserting the command order, fstab/GRUB text, and completion marker.
#      Fake commands touch sentinels if executed, proving --dry-run does not
#      partition, format, mount, chroot, or power off anything. A non-dry-run
#      run with a non-block device proves the failure marker path exits 1 and
#      still executes nothing.
#
# Usage: bash builders/debian/tests/installer_test.sh

set -euo pipefail

case "$0" in
  */*) TEST_DIR=${0%/*} ;;
  *) TEST_DIR=. ;;
esac
TEST_DIR=$(cd "$TEST_DIR" && pwd)
BUILDER_DIR=$(cd "$TEST_DIR/.." && pwd)
INSTALLER_DIR="$BUILDER_DIR/installer"
SCRIPT="$INSTALLER_DIR/sysemble-install.sh"
UNIT="$INSTALLER_DIR/sysemble-install.service"
SERVICE="sysemble-install.service"

if [ ! -f "$SCRIPT" ]; then
  printf 'FAIL: installer script not found: %s\n' "$SCRIPT" >&2
  exit 1
fi
if [ ! -f "$UNIT" ]; then
  printf 'FAIL: installer unit not found: %s\n' "$UNIT" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sysemble-installer-test.XXXXXX") || {
  printf 'FAIL: cannot create a temporary directory\n' >&2
  exit 1
}
cleanup() {
  rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

PASS=0
FAILURES=0

pass() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "$PASS" "$*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'not ok %d - %s\n' "$((PASS + FAILURES))" "$*" >&2
}

assert_contains() {
  local pattern=$1
  local file=$2
  local label=$3

  if grep -Fq -- "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label (pattern '$pattern' not found in $file)"
  fi
}

assert_not_contains() {
  local pattern=$1
  local file=$2
  local label=$3

  if grep -Fq -- "$pattern" "$file"; then
    fail "$label (unexpected pattern '$pattern' found in $file)"
  else
    pass "$label"
  fi
}

assert_eq() {
  local expected=$1
  local actual=$2
  local label=$3

  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '$actual')"
  fi
}

assert_file() {
  local file=$1
  local label=$2

  if [ -f "$file" ]; then
    pass "$label"
  else
    fail "$label (missing file: $file)"
  fi
}

line_of() {
  local pattern=$1
  local file=$2
  grep -n -F -- "$pattern" "$file" 2>/dev/null | head -n 1 | cut -d: -f1
}

# Assert $1 appears earlier than $2 in file $3.
assert_before() {
  local first=$1
  local second=$2
  local file=$3
  local label=$4
  local first_line=""
  local second_line=""

  first_line=$(line_of "$first" "$file")
  second_line=$(line_of "$second" "$file")
  if [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ]; then
    pass "$label ($first_line<$second_line)"
  else
    fail "$label (line('$first')=${first_line:-missing} line('$second')=${second_line:-missing})"
  fi
}

# ---------------------------------------------------------------------------
# Static checks: syntax and the frozen contract fragments
# ---------------------------------------------------------------------------

if sh -n "$SCRIPT"; then
  pass "sysemble-install.sh passes sh -n"
else
  fail "sysemble-install.sh has a POSIX sh syntax error"
fi
if bash -n "$SCRIPT"; then
  pass "sysemble-install.sh passes bash -n"
else
  fail "sysemble-install.sh has a bash syntax error"
fi
if [ -x "$SCRIPT" ]; then
  pass "sysemble-install.sh is executable"
else
  fail "sysemble-install.sh is not executable"
fi

assert_contains "#!/bin/sh" "$SCRIPT" "script uses the POSIX sh shebang"
assert_contains "set -eu" "$SCRIPT" "script enables set -eu"
assert_contains "SYMBLE_CMDLINE_FILE" "$SCRIPT" "script allows a cmdline file override"
assert_contains "SYMBLE_ROOT" "$SCRIPT" "script allows a live-root override"
assert_contains "SYMBLE_MNT" "$SCRIPT" "script allows a mountpoint override"
assert_contains "SYMBLE_CONSOLE" "$SCRIPT" "script allows a console override"
assert_contains "SYMBLE_LIVE_MEDIA" "$SCRIPT" "script allows a live-medium override"
assert_contains 'CMDLINE_FILE=${SYMBLE_CMDLINE_FILE:-/proc/cmdline}' "$SCRIPT" \
  "cmdline defaults to /proc/cmdline"
assert_contains 'CONSOLE=${SYMBLE_CONSOLE:-/dev/ttyS0}' "$SCRIPT" \
  "console defaults to /dev/ttyS0"
assert_contains "sysemble.install=*" "$SCRIPT" "script parses sysemble.install="
assert_contains "INSTALL_DEVICE=/dev/vda" "$SCRIPT" "install device defaults to /dev/vda"
assert_contains 'if [ "$DRY_RUN" -eq 0 ] && [ ! -b "$INSTALL_DEVICE" ]' "$SCRIPT" \
  "script validates that the target is a block device"
assert_contains '/run/live/medium' "$SCRIPT" "script detects the live medium mountpoint"
assert_contains 'refusing to install to the live medium' "$SCRIPT" \
  "script refuses the live medium"
assert_contains 'refusing to install to $INSTALL_DEVICE' "$SCRIPT" \
  "script refuses a device that is already mounted"

# GPT layout (frozen in the P0-d3 workplan §2.1).
assert_contains 'run "sgdisk -Z failed" sgdisk -Z "$INSTALL_DEVICE"' "$SCRIPT" \
  "script wipes the GPT with sgdisk -Z"
assert_contains 'sgdisk -n 1:2048:+512M -t 1:ef00 -n 2:0:0 -t 2:8300 "$INSTALL_DEVICE"' "$SCRIPT" \
  "script creates the frozen ESP+root GPT partitions"
assert_contains 'run "mkfs.vfat failed" mkfs.vfat -F 32 -n ESP "$ESP_DEV"' "$SCRIPT" \
  "script formats the ESP with mkfs.vfat -F 32 -n ESP"
assert_contains 'run "mkfs.ext4 failed" mkfs.ext4 -F -L SYMBLE "$ROOT_DEV"' "$SCRIPT" \
  "script formats the root with mkfs.ext4 -F -L SYMBLE"
assert_contains 'ESP_DEV="${INSTALL_DEVICE}1"' "$SCRIPT" \
  "script derives the ESP partition as <dev>1"
assert_contains 'ROOT_DEV="${INSTALL_DEVICE}2"' "$SCRIPT" \
  "script derives the root partition as <dev>2"

# Mounts and the rsync copy.
assert_contains 'run "mounting the root filesystem failed" mount "$ROOT_DEV" "$MNT"' "$SCRIPT" \
  "script mounts the root filesystem at SYMBLE_MNT"
assert_contains 'run "mounting the ESP failed" mount "$ESP_DEV" "$MNT/boot/efi"' "$SCRIPT" \
  "script mounts the ESP at /boot/efi"
for pseudo in proc sys dev run; do
  assert_contains "mount --bind /$pseudo \"\$MNT/$pseudo\"" "$SCRIPT" \
    "script bind-mounts /$pseudo into the install target"
done
assert_contains 'rsync -aHAX' "$SCRIPT" "script uses rsync -aHAX"
for exclude in proc sys dev run tmp mnt media live lost+found; do
  assert_contains "--exclude=/$exclude" "$SCRIPT" "rsync excludes /$exclude"
done
assert_contains '"$ROOT_SRC" "$MNT/"' "$SCRIPT" \
  "rsync copies the live root into the target mountpoint"

# fstab and GRUB.
assert_contains 'UUID=%s / ext4 errors=remount-ro 0 1' "$SCRIPT" \
  "script writes the root UUID to /etc/fstab"
assert_contains 'UUID=%s /boot/efi vfat umask=0077 0 1' "$SCRIPT" \
  "script writes the ESP UUID to /etc/fstab"
assert_contains 'chroot "$MNT" grub-install' "$SCRIPT" \
  "script runs grub-install inside the chroot"
assert_contains '--target=x86_64-efi --efi-directory=/boot/efi' "$SCRIPT" \
  "grub-install uses the x86_64-efi target and /boot/efi"
assert_contains '--bootloader-id=sysemble --removable --no-nvram' "$SCRIPT" \
  "grub-install uses the frozen bootloader id/removable/no-nvram flags"
assert_contains 'search --no-floppy --fs-uuid --set=root' "$SCRIPT" \
  "installed grub.cfg searches by filesystem UUID"
assert_contains 'insmod serial' "$SCRIPT" \
  "installed grub.cfg loads serial.mod for ttyS0 GRUB output"
assert_contains 'linux /boot/%s root=UUID=%s rw console=ttyS0 systemd.unit=multi-user.target' "$SCRIPT" \
  "installed grub.cfg uses root=UUID, console=ttyS0, and multi-user.target"
assert_contains 'initrd /boot/%s' "$SCRIPT" "installed grub.cfg loads the initrd"
assert_contains 'sort -V' "$SCRIPT" "script picks the highest kernel version with sort -V"
assert_contains 'no kernel found under $MNT/boot' "$SCRIPT" \
  "script fails when the copied root has no kernel"
assert_contains 'no initrd found:' "$SCRIPT" \
  "script fails when the copied root has no matching initrd"

# Completion/failure markers and poweroff.
assert_contains 'printf '"'"'SYMBLE: install complete\n'"'"' | tee "$CONSOLE"' "$SCRIPT" \
  "script prints the completion marker through tee to the console"
assert_contains 'SYMBLE: install failed:' "$SCRIPT" \
  "script prints a failure marker"
assert_contains 'systemctl poweroff -f' "$SCRIPT" \
  "script powers off only after a successful install"
assert_not_contains "systemctl reboot" "$SCRIPT" "script does not reboot the live system"

# ---------------------------------------------------------------------------
# Static checks: the systemd unit is the frozen P0-d3 §2.1 content
# ---------------------------------------------------------------------------

assert_contains "[Unit]" "$UNIT" "unit has a [Unit] section"
assert_contains "Description=Sysemble unattended installer" "$UNIT" \
  "unit has the frozen description"
assert_contains "ConditionKernelCommandLine=sysemble.install" "$UNIT" \
  "unit is gated on the sysemble.install cmdline"
assert_contains "After=multi-user.target" "$UNIT" "unit runs after multi-user.target"
assert_contains "[Service]" "$UNIT" "unit has a [Service] section"
assert_contains "Type=oneshot" "$UNIT" "unit is a oneshot service"
assert_contains "ExecStart=/usr/local/sbin/sysemble-install" "$UNIT" \
  "unit executes /usr/local/sbin/sysemble-install"
assert_contains "TimeoutStartSec=1800" "$UNIT" "unit has the frozen 1800 s timeout"
assert_contains "StandardOutput=journal+console" "$UNIT" \
  "unit forwards stdout to the journal and console"
assert_contains "[Install]" "$UNIT" "unit has an [Install] section"
assert_contains "WantedBy=multi-user.target" "$UNIT" \
  "unit is wanted by multi-user.target"

# ---------------------------------------------------------------------------
# Dynamic --dry-run: command order, fstab/GRUB text, markers, no execution
# ---------------------------------------------------------------------------

DRY_ROOT="$TMP_DIR/dry"
DRY_MNT="$DRY_ROOT/mnt"
DRY_LIVE="$DRY_ROOT/live"
DRY_CONSOLE="$DRY_ROOT/console"
DRY_CMDLINE="$DRY_ROOT/cmdline"
DRY_OUT="$DRY_ROOT/out.log"
SENTINEL="$DRY_ROOT/sentinel"
FAKEBIN="$DRY_ROOT/bin"
mkdir -p "$DRY_MNT/boot" "$DRY_MNT/etc" "$DRY_LIVE" "$SENTINEL" "$FAKEBIN"
printf 'kernel\n' >"$DRY_MNT/boot/vmlinuz-6.12.3"
printf 'initrd\n' >"$DRY_MNT/boot/initrd.img-6.12.3"
printf 'boot=live console=ttyS0 sysemble.install=/dev/vda\n' >"$DRY_CMDLINE"
: >"$DRY_CONSOLE"

for tool in sgdisk mkfs.vfat mkfs.ext4 mount umount chroot rsync blkid systemctl; do
  cat >"$FAKEBIN/$tool" <<SH
#!/bin/sh
: >"$SENTINEL/$tool"
echo "fake $tool: must not run in --dry-run: \$*" >&2
exit 0
SH
  chmod +x "$FAKEBIN/$tool"
done

DRY_RC=0
if PATH="$FAKEBIN:$PATH" \
  SYMBLE_CMDLINE_FILE="$DRY_CMDLINE" \
  SYMBLE_ROOT="$DRY_LIVE" \
  SYMBLE_MNT="$DRY_MNT" \
  SYMBLE_CONSOLE="$DRY_CONSOLE" \
  sh "$SCRIPT" --dry-run >"$DRY_OUT" 2>&1; then
  DRY_RC=0
else
  DRY_RC=$?
fi
assert_eq "0" "$DRY_RC" "--dry-run exits 0"
assert_file "$DRY_OUT" "--dry-run writes its log"
if grep -Fxq "SYMBLE: install complete" "$DRY_CONSOLE"; then
  pass "--dry-run prints the completion marker to SYMBLE_CONSOLE"
else
  fail "--dry-run did not print the completion marker to SYMBLE_CONSOLE"
fi
assert_not_contains "SYMBLE: install failed" "$DRY_CONSOLE" \
  "--dry-run has no failure marker"
if [ -z "$(ls -A "$SENTINEL" 2>/dev/null)" ]; then
  pass "--dry-run executes no destructive command (sgdisk/mkfs/mount/chroot/rsync/systemctl sentinels are empty)"
else
  fail "--dry-run executed a destructive command: $(ls -A "$SENTINEL")"
fi

assert_contains "+ sgdisk -Z /dev/vda" "$DRY_OUT" "dry-run logs sgdisk -Z /dev/vda"
assert_contains "+ sgdisk -n 1:2048:+512M -t 1:ef00 -n 2:0:0 -t 2:8300 /dev/vda" "$DRY_OUT" \
  "dry-run logs the frozen GPT layout"
assert_contains "+ mkfs.vfat -F 32 -n ESP /dev/vda1" "$DRY_OUT" \
  "dry-run logs the ESP format"
assert_contains "+ mkfs.ext4 -F -L SYMBLE /dev/vda2" "$DRY_OUT" \
  "dry-run logs the root format"
assert_contains "+ mount /dev/vda2 $DRY_MNT" "$DRY_OUT" \
  "dry-run logs the root mount"
assert_contains "+ mount /dev/vda1 $DRY_MNT/boot/efi" "$DRY_OUT" \
  "dry-run logs the ESP mount"
for pseudo in proc sys dev run; do
  assert_contains "+ mount --bind /$pseudo $DRY_MNT/$pseudo" "$DRY_OUT" \
    "dry-run logs bind mount /$pseudo"
done
assert_contains "+ rsync -aHAX" "$DRY_OUT" "dry-run logs the rsync copy"
for exclude in proc sys dev run tmp mnt media live lost+found; do
  assert_contains "--exclude=/$exclude" "$DRY_OUT" "dry-run rsync excludes /$exclude"
done
assert_contains "UUID=11111111-1111-1111-1111-111111111111 / ext4 errors=remount-ro 0 1" \
  "$DRY_OUT" "dry-run renders the root fstab line"
assert_contains "UUID=22222222-2222-2222-2222-222222222222 /boot/efi vfat umask=0077 0 1" \
  "$DRY_OUT" "dry-run renders the ESP fstab line"
assert_contains "+ chroot $DRY_MNT grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=sysemble --removable --no-nvram" \
  "$DRY_OUT" "dry-run logs the frozen grub-install command"
assert_contains "search --no-floppy --fs-uuid --set=root 11111111-1111-1111-1111-111111111111" \
  "$DRY_OUT" "dry-run renders the UUID GRUB search"
assert_contains "insmod serial" "$DRY_OUT" \
  "dry-run renders the serial-module load for GRUB console output"
assert_contains "linux /boot/vmlinuz-6.12.3 root=UUID=11111111-1111-1111-1111-111111111111 rw console=ttyS0 systemd.unit=multi-user.target" \
  "$DRY_OUT" "dry-run renders the installed kernel cmdline"
assert_contains "initrd /boot/initrd.img-6.12.3" "$DRY_OUT" \
  "dry-run renders the installed initrd"
assert_contains "+ umount $DRY_MNT" "$DRY_OUT" "dry-run logs the final unmount"
assert_contains "dry-run: would run: systemctl poweroff -f" "$DRY_OUT" \
  "dry-run logs but does not run poweroff"

assert_before "+ sgdisk -Z" "+ sgdisk -n 1:2048" "$DRY_OUT" \
  "order: wipe GPT before creating partitions"
assert_before "+ sgdisk -n 1:2048" "+ mkfs.vfat" "$DRY_OUT" \
  "order: partition before formatting the ESP"
assert_before "+ mkfs.vfat" "+ mkfs.ext4" "$DRY_OUT" \
  "order: ESP format before root format"
assert_before "+ mkfs.ext4" "+ mount /dev/vda2" "$DRY_OUT" \
  "order: root format before mounting it"
assert_before "+ mount /dev/vda2" "+ mount /dev/vda1" "$DRY_OUT" \
  "order: root mount before ESP mount"
assert_before "+ mount --bind /run" "+ rsync -aHAX" "$DRY_OUT" \
  "order: all bind mounts before rsync"
assert_before "+ rsync -aHAX" "UUID=11111111" "$DRY_OUT" \
  "order: rsync before fstab"
assert_before "UUID=11111111" "+ chroot" "$DRY_OUT" \
  "order: fstab before grub-install"
assert_before "+ chroot" "search --no-floppy --fs-uuid" "$DRY_OUT" \
  "order: grub-install before writing the installed grub.cfg"
assert_before "initrd /boot/initrd.img-6.12.3" "+ umount" "$DRY_OUT" \
  "order: grub.cfg before unmounting"
assert_before "+ umount" "SYMBLE: install complete" "$DRY_OUT" \
  "order: unmount before the completion marker"
assert_before "SYMBLE: install complete" "dry-run: would run: systemctl poweroff -f" "$DRY_OUT" \
  "order: completion marker before poweroff"

# ---------------------------------------------------------------------------
# Dynamic failure path: a non-block device fails before any destructive step
# ---------------------------------------------------------------------------

FAIL_ROOT="$TMP_DIR/fail"
FAIL_MNT="$FAIL_ROOT/mnt"
FAIL_CONSOLE="$FAIL_ROOT/console"
FAIL_CMDLINE="$FAIL_ROOT/cmdline"
FAIL_OUT="$FAIL_ROOT/out.log"
FAIL_SENTINEL="$FAIL_ROOT/sentinel"
FAILBIN="$FAIL_ROOT/bin"
mkdir -p "$FAIL_MNT/boot" "$FAIL_SENTINEL" "$FAILBIN"
printf 'boot=live sysemble.install=/dev/sysemble-not-a-block-device\n' >"$FAIL_CMDLINE"
: >"$FAIL_CONSOLE"
for tool in sgdisk mkfs.vfat mkfs.ext4 mount umount chroot rsync blkid systemctl; do
  cat >"$FAILBIN/$tool" <<SH
#!/bin/sh
: >"$FAIL_SENTINEL/$tool"
exit 0
SH
  chmod +x "$FAILBIN/$tool"
done
# The real install path checks Linux/root before touching the device; fake both
# so this test reaches the frozen non-block-device failure marker.
cat >"$FAILBIN/uname" <<'SH'
#!/bin/sh
printf 'Linux\n'
SH
cat >"$FAILBIN/id" <<'SH'
#!/bin/sh
printf '0\n'
SH
chmod +x "$FAILBIN/uname" "$FAILBIN/id"

FAIL_RC=0
if PATH="$FAILBIN:$PATH" \
  SYMBLE_CMDLINE_FILE="$FAIL_CMDLINE" \
  SYMBLE_MNT="$FAIL_MNT" \
  SYMBLE_CONSOLE="$FAIL_CONSOLE" \
  sh "$SCRIPT" >"$FAIL_OUT" 2>&1; then
  FAIL_RC=0
else
  FAIL_RC=$?
fi
assert_eq "1" "$FAIL_RC" "non-block device exits 1"
assert_contains "SYMBLE: install failed: not a block device: /dev/sysemble-not-a-block-device" \
  "$FAIL_CONSOLE" "non-block device prints the failure marker to the console"
assert_not_contains "SYMBLE: install complete" "$FAIL_CONSOLE" \
  "failure path prints no completion marker"
assert_not_contains "SYMBLE: install complete" "$FAIL_OUT" \
  "failure path does not pretend the install completed"
if [ -z "$(ls -A "$FAIL_SENTINEL" 2>/dev/null)" ]; then
  pass "failure path executes no destructive command"
else
  fail "failure path executed a destructive command: $(ls -A "$FAIL_SENTINEL")"
fi
assert_not_contains "+ systemctl poweroff" "$FAIL_OUT" \
  "failure path never runs poweroff (logs are kept for inspection)"

# A malformed install device is rejected with the same marker contract.
INVALID_CMDLINE="$TMP_DIR/invalid-cmdline"
INVALID_CONSOLE="$TMP_DIR/invalid-console"
printf 'boot=live sysemble.install=not-a-device\n' >"$INVALID_CMDLINE"
: >"$INVALID_CONSOLE"
INVALID_RC=0
if SYMBLE_CMDLINE_FILE="$INVALID_CMDLINE" SYMBLE_CONSOLE="$INVALID_CONSOLE" \
  SYMBLE_MNT="$TMP_DIR/never-mounted" PATH="$FAILBIN:$PATH" \
  sh "$SCRIPT" >"$TMP_DIR/invalid-out.log" 2>&1; then
  INVALID_RC=0
else
  INVALID_RC=$?
fi
assert_eq "1" "$INVALID_RC" "non-/dev install device exits 1"
assert_contains "SYMBLE: install failed: invalid install device 'not-a-device'" \
  "$INVALID_CONSOLE" "non-/dev install device prints the failure marker"

# ---------------------------------------------------------------------------
# P0-e1 CLI/TUI static contract
# ---------------------------------------------------------------------------

assert_contains "--disk" "$SCRIPT" "script documents/supports --disk"
assert_contains "--hostname" "$SCRIPT" "script documents/supports --hostname"
assert_contains "--user" "$SCRIPT" "script documents/supports --user"
assert_contains "--password-file" "$SCRIPT" "script documents/supports --password-file"
assert_contains "--yes" "$SCRIPT" "script documents/supports --yes"
assert_contains "--tui" "$SCRIPT" "script documents/supports --tui"
assert_contains "--auto" "$SCRIPT" "script documents/supports --auto"
assert_contains "sysemble.install.tui=*" "$SCRIPT" \
  "script auto-detects the sysemble.install.tui= cmdline marker"
assert_contains 'SYMBLE-TUI $label [$default]: ' "$SCRIPT" \
  "script renders the frozen disk/hostname/user prompts"
assert_contains 'SYMBLE-TUI password: ' "$SCRIPT" "script renders the frozen password prompt"
assert_contains 'SYMBLE-TUI confirm install to $INSTALL_DEVICE (yes/no): ' "$SCRIPT" \
  "script renders the frozen confirmation prompt"
assert_contains 'tui_prompt "disk"' "$SCRIPT" "TUI prompts for the disk"
assert_contains 'tui_prompt "hostname"' "$SCRIPT" "TUI prompts for the hostname"
assert_contains 'tui_prompt "user"' "$SCRIPT" "TUI prompts for the user"
assert_contains "stty -echo" "$SCRIPT" "TUI disables password echo with stty -echo"
assert_contains 'stty "$TUI_STTY_SAVED"' "$SCRIPT" "TUI restores the saved terminal settings"
assert_contains "systemctl stop serial-getty@ttyS0.service" "$SCRIPT" \
  "TUI stops the serial getty before using ttyS0"
assert_contains "useradd -m -s /bin/bash -G sudo" "$SCRIPT" \
  "post-install creates the user with useradd -m -s /bin/bash -G sudo"
assert_contains "chpasswd" "$SCRIPT" "post-install sets a non-empty password with chpasswd"
assert_contains "passwd -l" "$SCRIPT" "post-install locks an empty password with passwd -l"
assert_contains '/etc/hostname' "$SCRIPT" "post-install writes /etc/hostname"
assert_contains '/etc/hosts' "$SCRIPT" "post-install writes /etc/hosts"
assert_contains '127.0.1.1 %s' "$SCRIPT" "post-install maps the hostname to 127.0.1.1"
assert_contains "valid_tui_disk" "$SCRIPT" "TUI re-prompts until the disk is valid"
assert_contains "installation cancelled" "$SCRIPT" "TUI reports a refused confirmation"
assert_contains "exit 2" "$SCRIPT" "TUI cancellation exits 2"
assert_contains "exit 3" "$SCRIPT" "non-root/non-Linux preflight exits 3"

# ---------------------------------------------------------------------------
# P0-e1 dynamic dry-run: piped TUI, cancel, retry, --yes, post-install config
# ---------------------------------------------------------------------------

TUI_ROOT="$TMP_DIR/tui"
TUI_MNT="$TUI_ROOT/mnt"
TUI_LIVE="$TUI_ROOT/live"
TUI_CONSOLE="$TUI_ROOT/console"
TUI_CMDLINE="$TUI_ROOT/cmdline"
TUI_SENTINEL="$TUI_ROOT/sentinel"
TUIBIN="$TUI_ROOT/bin"
mkdir -p "$TUI_MNT/boot" "$TUI_LIVE" "$TUI_SENTINEL" "$TUIBIN"
printf 'kernel\n' >"$TUI_MNT/boot/vmlinuz-6.12.3"
printf 'initrd\n' >"$TUI_MNT/boot/initrd.img-6.12.3"
: >"$TUI_CMDLINE"
: >"$TUI_CONSOLE"
for tool in sgdisk mkfs.vfat mkfs.ext4 mount umount chroot rsync blkid systemctl \
  useradd chpasswd passwd stty tty; do
  cat >"$TUIBIN/$tool" <<SH
#!/bin/sh
: >"$TUI_SENTINEL/$tool"
exit 0
SH
  chmod +x "$TUIBIN/$tool"
done

# Run the installer with the TUI fed through stdin (SYMBLE_TUI_DEVICE points at
# a missing node, which is the documented local pipe path). Sets TUI_RC and
# TUI_OUT for the following assertions.
tui_run() {
  TUI_INPUT=$1
  TUI_LABEL=$2
  shift 2
  TUI_OUT="$TMP_DIR/tui-$TUI_LABEL.out"
  : >"$TUI_CONSOLE"
  TUI_RC=0
  if printf '%s' "$TUI_INPUT" |
    PATH="$TUIBIN:$PATH" \
      SYMBLE_CMDLINE_FILE="$TUI_CMDLINE" \
      SYMBLE_ROOT="$TUI_LIVE" \
      SYMBLE_MNT="$TUI_MNT" \
      SYMBLE_CONSOLE="$TUI_CONSOLE" \
      SYMBLE_TUI_DEVICE=/nonexistent \
      sh "$SCRIPT" "$@" >"$TUI_OUT" 2>&1; then
    TUI_RC=0
  else
    TUI_RC=$?
  fi
}

tui_run $'\n\n\n\n\nyes\n' default --tui --dry-run
assert_eq "0" "$TUI_RC" "piped TUI dry-run (five blank answers then yes) exits 0"
for prompt in \
  'SYMBLE-TUI disk [/dev/vda]:' \
  'SYMBLE-TUI hostname [sysemble]:' \
  'SYMBLE-TUI user [ops]:' \
  'SYMBLE-TUI password:' \
  'SYMBLE-TUI confirm install to /dev/vda (yes/no):'; do
  assert_contains "$prompt" "$TUI_OUT" "piped TUI prints '$prompt'"
done
assert_contains "tui answers: disk=/dev/vda hostname=sysemble user=ops password=empty" \
  "$TUI_OUT" "TUI logs the chosen answers"
assert_contains "SYMBLE: install complete" "$TUI_CONSOLE" \
  "piped TUI dry-run prints the completion marker"
if [ -z "$(ls -A "$TUI_SENTINEL" 2>/dev/null)" ]; then
  pass "piped TUI dry-run executes no destructive command"
else
  fail "piped TUI dry-run executed a destructive command: $(ls -A "$TUI_SENTINEL")"
fi
assert_before "SYMBLE-TUI confirm install" "+ sgdisk -Z" "$TUI_OUT" \
  "TUI asks for confirmation before any install command"
assert_contains "+ chroot $TUI_MNT useradd -m -s /bin/bash -G sudo ops" "$TUI_OUT" \
  "TUI dry-run plans the useradd command"
assert_contains "+ chroot $TUI_MNT passwd -l ops" "$TUI_OUT" \
  "TUI dry-run locks the empty default password"
assert_contains "127.0.1.1 sysemble" "$TUI_OUT" \
  "TUI dry-run renders the /etc/hosts hostname line"

tui_run $'\n\n\n\nno\n' cancel --tui --dry-run
assert_eq "2" "$TUI_RC" "TUI confirmation 'no' exits 2"
assert_contains "SYMBLE-TUI installation cancelled" "$TUI_OUT" \
  "TUI cancellation is reported"
assert_not_contains "SYMBLE: install complete" "$TUI_CONSOLE" \
  "cancelled TUI writes no completion marker"
assert_not_contains "+ sgdisk -Z" "$TUI_OUT" \
  "cancelled TUI runs no install command"
if [ -z "$(ls -A "$TUI_SENTINEL" 2>/dev/null)" ]; then
  pass "cancelled TUI executes no destructive command"
else
  fail "cancelled TUI executed a destructive command: $(ls -A "$TUI_SENTINEL")"
fi

tui_run $'/dev/nope\n\n\n\n\nyes\n' retry --tui --dry-run
assert_eq "0" "$TUI_RC" "TUI invalid disk retry eventually exits 0"
assert_contains "SYMBLE-TUI invalid disk '/dev/nope' (not a block device); try again" \
  "$TUI_OUT" "TUI rejects a non-block device"
TUI_DISK_PROMPTS=$(grep -c -F -- 'SYMBLE-TUI disk [/dev/vda]:' "$TUI_OUT" 2>/dev/null || true)
assert_eq "2" "$TUI_DISK_PROMPTS" "TUI re-prompts the disk after an invalid device"
assert_contains "tui answers: disk=/dev/vda" "$TUI_OUT" \
  "TUI accepts the default /dev/vda after the retry"

# --yes skips the confirmation prompt entirely (the four answers already cover
# disk/hostname/user/password, so a confirm read would hit EOF and exit 2).
tui_run $'\n\n\ns3cret\n' yes-skip --tui --yes --dry-run
assert_eq "0" "$TUI_RC" "TUI --yes with four answers exits 0"
assert_not_contains "SYMBLE-TUI confirm install" "$TUI_OUT" \
  "TUI --yes skips the confirmation prompt"
assert_contains "tui: confirmation skipped (--yes)" "$TUI_OUT" \
  "TUI logs that --yes skipped confirmation"
assert_contains "password=set" "$TUI_OUT" "TUI records that a password was supplied"
assert_contains "+ chroot $TUI_MNT chpasswd" "$TUI_OUT" \
  "TUI with a password plans chpasswd"
assert_not_contains "s3cret" "$TUI_OUT" "TUI dry-run never logs the password"

# Unattended --yes: no prompts at all, default empty password -> passwd -l.
TUI_OUT="$TMP_DIR/tui-unattended.out"
: >"$TUI_CONSOLE"
TUI_RC=0
if SYMBLE_CMDLINE_FILE="$TUI_CMDLINE" SYMBLE_ROOT="$TUI_LIVE" \
  SYMBLE_MNT="$TUI_MNT" SYMBLE_CONSOLE="$TUI_CONSOLE" \
  sh "$SCRIPT" --yes --disk /dev/vda --hostname h --user u --dry-run </dev/null \
  >"$TUI_OUT" 2>&1; then
  TUI_RC=0
else
  TUI_RC=$?
fi
assert_eq "0" "$TUI_RC" "--yes --disk/--hostname/--user --dry-run exits 0"
assert_not_contains "SYMBLE-TUI" "$TUI_OUT" \
  "unattended --yes prints no TUI prompts"
assert_contains "configuration: disk=/dev/vda hostname=h user=u password=empty" \
  "$TUI_OUT" "unattended dry-run records disk, hostname, and user"
assert_contains "+ chroot $TUI_MNT useradd -m -s /bin/bash -G sudo u" "$TUI_OUT" \
  "unattended dry-run plans useradd for the requested user"
assert_contains "+ chroot $TUI_MNT passwd -l u" "$TUI_OUT" \
  "unattended empty password plans passwd -l"

# A non-empty --password-file selects chpasswd and is never echoed.
PASSWORD_FIXTURE="$TMP_DIR/password.txt"
printf 's3cret\n' >"$PASSWORD_FIXTURE"
TUI_OUT="$TMP_DIR/tui-password-file.out"
TUI_RC=0
if SYMBLE_CMDLINE_FILE="$TUI_CMDLINE" SYMBLE_ROOT="$TUI_LIVE" \
  SYMBLE_MNT="$TUI_MNT" SYMBLE_CONSOLE="$TUI_CONSOLE" \
  sh "$SCRIPT" --yes --disk /dev/vda --hostname h2 --user u2 \
  --password-file "$PASSWORD_FIXTURE" --dry-run </dev/null >"$TUI_OUT" 2>&1; then
  TUI_RC=0
else
  TUI_RC=$?
fi
assert_eq "0" "$TUI_RC" "--password-file --dry-run exits 0"
assert_contains "+ chroot $TUI_MNT useradd -m -s /bin/bash -G sudo u2" "$TUI_OUT" \
  "password-file dry-run plans useradd for the requested user"
assert_contains "+ chroot $TUI_MNT chpasswd" "$TUI_OUT" \
  "password-file dry-run plans chpasswd"
assert_contains "127.0.1.1 h2" "$TUI_OUT" \
  "password-file dry-run renders the requested hostname in /etc/hosts"
assert_not_contains "s3cret" "$TUI_OUT" "dry-run never prints the password"

# Exit 3: the real-install preflight rejects a non-Linux host before any disk
# work. Fake uname/id so the test host does not matter.
ENVBIN="$TMP_DIR/envbin"
mkdir -p "$ENVBIN"
cat >"$ENVBIN/uname" <<'SH'
#!/bin/sh
printf 'Darwin\n'
SH
cat >"$ENVBIN/id" <<'SH'
#!/bin/sh
printf '0\n'
SH
chmod +x "$ENVBIN/uname" "$ENVBIN/id"
ENV_RC=0
if PATH="$ENVBIN:$PATH" SYMBLE_CONSOLE="$TMP_DIR/env-console" \
  sh "$SCRIPT" --disk /dev/vda >"$TMP_DIR/env-nonlinux.out" 2>&1; then
  ENV_RC=0
else
  ENV_RC=$?
fi
assert_eq "3" "$ENV_RC" "non-Linux real install exits 3"
assert_contains "requires Linux" "$TMP_DIR/env-nonlinux.out" \
  "non-Linux preflight explains the requirement"

cat >"$ENVBIN/uname" <<'SH'
#!/bin/sh
printf 'Linux\n'
SH
cat >"$ENVBIN/id" <<'SH'
#!/bin/sh
printf '1000\n'
SH
chmod +x "$ENVBIN/uname" "$ENVBIN/id"
ENV_RC=0
if PATH="$ENVBIN:$PATH" SYMBLE_CONSOLE="$TMP_DIR/env-console" \
  sh "$SCRIPT" --disk /dev/vda >"$TMP_DIR/env-nonroot.out" 2>&1; then
  ENV_RC=0
else
  ENV_RC=$?
fi
assert_eq "3" "$ENV_RC" "non-root real install exits 3"
assert_contains "requires root" "$TMP_DIR/env-nonroot.out" \
  "non-root preflight explains the requirement"



# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

if [ "$FAILURES" -ne 0 ]; then
  printf '\ninstaller_test.sh: %d failure(s), %d passed check(s)\n' "$FAILURES" "$PASS" >&2
  exit 1
fi
printf '\ninstaller_test.sh: all %d checks passed\n' "$PASS"
