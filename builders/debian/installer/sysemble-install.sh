#!/bin/sh
# Sysemble unattended installer (P0-d3, frozen by docs/plan/P0-d3-workplan.md).
#
# Runs as a oneshot systemd unit on the live ISO:
#   - reads the target disk from sysemble.install= (default /dev/vda)
#   - refuses the live medium and any mounted disk
#   - creates GPT: p1 ESP (512 MiB, ef00), p2 root (rest, 8300)
#   - formats the ESP (vfat32/ESP) and root (ext4/SYMBLE)
#   - copies the live system with rsync, writes /etc/fstab and the installed
#     GRUB configuration, and installs GRUB to the ESP with --removable
#   - on success prints "SYMBLE: install complete" and powers off; on failure
#     prints "SYMBLE: install failed: <reason>" and exits 1 WITHOUT powering
#     off so the live journal/console can be inspected.
#
# Testability (all optional, production defaults):
#   SYMBLE_CMDLINE_FILE  kernel cmdline source      (default /proc/cmdline)
#   SYMBLE_ROOT          live root to copy           (default /)
#   SYMBLE_MNT           install target mountpoint   (default /mnt)
#   SYMBLE_CONSOLE       marker output                (default /dev/ttyS0)
#   SYMBLE_LIVE_MEDIA    live medium device override
#   --dry-run            log the plan, execute nothing destructive, and still
#                        print the completion marker (for offline tests).
#
# The script never writes a config to this live system except /mnt; the
# installed disk is the only persistent output.

set -eu

CMDLINE_FILE=${SYMBLE_CMDLINE_FILE:-/proc/cmdline}
ROOT_SRC=${SYMBLE_ROOT:-/}
MNT=${SYMBLE_MNT:-/mnt}
CONSOLE=${SYMBLE_CONSOLE:-/dev/ttyS0}
DRY_RUN=0

ROOT_MOUNTED=0
ESP_MOUNTED=0
BINDS_MOUNTED=0
FAILED=0

usage() {
  cat <<'USAGE'
Usage: sysemble-install [--dry-run]

Unattended install of the live Sysemble system to the disk named by
sysemble.install=<device> on the kernel cmdline (default /dev/vda).

Options:
  --dry-run      print the command sequence and exit without partitioning,
                 formatting, mounting, or powering off.
  -h, --help     show this help and exit 0.

Environment overrides (diagnostics/tests only):
  SYMBLE_CMDLINE_FILE, SYMBLE_ROOT, SYMBLE_MNT, SYMBLE_CONSOLE,
  SYMBLE_LIVE_MEDIA
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
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
  shift
done

log() {
  printf 'sysemble-install: %s\n' "$*"
}

fail() {
  FAILED=1
  printf 'SYMBLE: install failed: %s\n' "$*" | tee "$CONSOLE" >&2 || true
  exit 1
}

# Run a destructive command, logging its argv first. In --dry-run the command
# is only printed. A failing command reports a specific reason through fail().
run() {
  reason=$1
  shift
  printf '+ %s\n' "$*"
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  "$@" || fail "$reason"
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
      printf '+ umount %s/%s\n' "$MNT" "$suffix"
      if [ "$DRY_RUN" -eq 0 ]; then
        umount "$MNT/$suffix" 2>/dev/null || true
      fi
    done
    BINDS_MOUNTED=0
  fi
  if [ "$ESP_MOUNTED" -eq 1 ]; then
    printf '+ umount %s/boot/efi\n' "$MNT"
    if [ "$DRY_RUN" -eq 0 ]; then
      umount "$MNT/boot/efi" 2>/dev/null || true
    fi
    ESP_MOUNTED=0
  fi
  if [ "$ROOT_MOUNTED" -eq 1 ]; then
    printf '+ umount %s\n' "$MNT"
    if [ "$DRY_RUN" -eq 0 ]; then
      umount "$MNT" 2>/dev/null || true
    fi
    ROOT_MOUNTED=0
  fi
}

on_exit() {
  status=$?
  if [ "$status" -ne 0 ]; then
    cleanup_mounts
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
# 1. Resolve and validate the target device
# ---------------------------------------------------------------------------

INSTALL_DEVICE=""
if [ -r "$CMDLINE_FILE" ]; then
  CMDLINE=$(cat "$CMDLINE_FILE" 2>/dev/null || true)
  # Disable pathname expansion while splitting the cmdline on whitespace.
  set -f
  for word in $CMDLINE; do
    case "$word" in
      sysemble.install=*)
        INSTALL_DEVICE=${word#sysemble.install=}
        ;;
    esac
  done
  set +f
fi
if [ -z "$INSTALL_DEVICE" ]; then
  INSTALL_DEVICE=/dev/vda
fi

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

log "step 1/7: partition $INSTALL_DEVICE"
run "sgdisk -Z failed" sgdisk -Z "$INSTALL_DEVICE"
run "sgdisk partition creation failed" \
  sgdisk -n 1:2048:+512M -t 1:ef00 -n 2:0:0 -t 2:8300 "$INSTALL_DEVICE"
# Let udev create /dev/vda1 and /dev/vda2 before mkfs/blkid race the kernel
# partition rescan. Best-effort: the live-boot environment normally has it.
if [ "$DRY_RUN" -eq 0 ] && command -v udevadm >/dev/null 2>&1; then
  udevadm settle || true
fi

log "step 2/7: format ESP and root"
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

log "step 3/7: mount target and bind /proc /sys /dev /run"
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$MNT" || fail "cannot create the mountpoint $MNT"
fi
run "mounting the root filesystem failed" mount "$ROOT_DEV" "$MNT"
ROOT_MOUNTED=1

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$MNT/boot/efi" || fail "cannot create $MNT/boot/efi"
fi
run "mounting the ESP failed" mount "$ESP_DEV" "$MNT/boot/efi"
ESP_MOUNTED=1

if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$MNT/proc" "$MNT/sys" "$MNT/dev" "$MNT/run" ||
    fail "cannot create the chroot pseudo-filesystem mountpoints"
fi
run "bind mount /proc failed" mount --bind /proc "$MNT/proc"
run "bind mount /sys failed" mount --bind /sys "$MNT/sys"
run "bind mount /dev failed" mount --bind /dev "$MNT/dev"
run "bind mount /run failed" mount --bind /run "$MNT/run"
BINDS_MOUNTED=1

# ---------------------------------------------------------------------------
# 4. Copy the live root
# ---------------------------------------------------------------------------

log "step 4/7: rsync $ROOT_SRC -> $MNT"
run "rsync copy failed" rsync -aHAX \
  --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
  --exclude=/tmp --exclude=/mnt --exclude=/media --exclude=/live \
  --exclude=/lost+found \
  "$ROOT_SRC" "$MNT/"

# ---------------------------------------------------------------------------
# 5. fstab and the installed GRUB configuration
# ---------------------------------------------------------------------------

log "step 5/7: write /etc/fstab"
if [ "$DRY_RUN" -eq 1 ]; then
  log "dry-run: /etc/fstab would contain:"
  printf 'UUID=%s / ext4 errors=remount-ro 0 1\n' "$ROOT_UUID"
  printf 'UUID=%s /boot/efi vfat umask=0077 0 1\n' "$ESP_UUID"
else
  mkdir -p "$MNT/etc" || fail "cannot create $MNT/etc"
  {
    printf '# /etc/fstab: static file system information.\n'
    printf '# installed by sysemble-install; UUIDs from mkfs/blkid.\n'
    printf 'UUID=%s / ext4 errors=remount-ro 0 1\n' "$ROOT_UUID"
    printf 'UUID=%s /boot/efi vfat umask=0077 0 1\n' "$ESP_UUID"
  } >"$MNT/etc/fstab" || fail "cannot write $MNT/etc/fstab"
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

log "step 6/7: install GRUB to the ESP and write /boot/grub/grub.cfg"
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
  mkdir -p "$MNT/boot/grub" || fail "cannot create $MNT/boot/grub"
  write_grub_cfg >"$MNT/boot/grub/grub.cfg" ||
    fail "cannot write $MNT/boot/grub/grub.cfg"
fi

# ---------------------------------------------------------------------------
# 6. Unmount and finish
# ---------------------------------------------------------------------------

log "step 7/7: unmount and finish"
cleanup_mounts

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'SYMBLE: install complete\n' | tee "$CONSOLE"
  log "dry-run: would run: systemctl poweroff -f"
  exit 0
fi

printf 'SYMBLE: install complete\n' | tee "$CONSOLE"
systemctl poweroff -f || fail "systemctl poweroff -f failed"
