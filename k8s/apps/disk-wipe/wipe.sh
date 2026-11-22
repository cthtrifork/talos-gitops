#!/bin/sh
# Wipes the disks and partitions listed in $TARGETS, one per line:
#   part|<filesystem UUID>|<size in bytes>|<description>     a partition: erase its signatures and first 32 MiB, delete its partition entry
#   disk|<model>|<size in bytes>|<description>               a whole USB disk: erase every partition and the partition tables
# Every target is matched by identity (UUID or model) AND exact size; a mismatch fails the Job instead of wiping something else.
# Anything the host has mounted is skipped (read from the host's mount namespace, /proc/1/mountinfo; the pod has hostPID), and a disk is
# only wiped when it is a USB disk. A target that is not found is reported as already gone. Idempotent: run it again after unmounting.
#
# DRY_RUN=true only logs what would be wiped. HOSTMOUNTS, SYSFS and DEVDIR exist so the logic can be tested without a real disk.
set -u

HOSTMOUNTS="${HOSTMOUNTS:-/proc/1/mountinfo}"
SYSFS="${SYSFS:-/sys}"
DEVDIR="${DEVDIR:-/dev}"
DRY_RUN="${DRY_RUN:-false}"

fail=0
skipped=0

log() { echo "$(date -u +%H:%M:%S) $*"; }

# is the device mounted by the host? the source is the field after the filesystem type, behind the " - " of a mountinfo line
mounted() {
  awk -v d="$1" '{ for (i = 1; i <= NF; i++) if ($i == "-" && $(i + 2) == d) found = 1 } END { exit !found }' "$HOSTMOUNTS"
}

run() {
  if [ "$DRY_RUN" = "true" ]; then
    log "  (dry run) $*"
  else
    "$@"
  fi
}

wipe_partition() {
  id="$1"; want="$2"; desc="$3"
  dev="$(blkid -U "$id" 2>/dev/null)" || dev=""
  if [ -z "$dev" ]; then
    log "GONE   $desc: no partition with the filesystem UUID $id (already wiped)"
    return
  fi
  size="$(blockdev --getsize64 "$dev")"
  if [ "$size" != "$want" ]; then
    log "REFUSE $desc: $dev is $size bytes, expected $want"
    fail=1
    return
  fi
  if mounted "$dev"; then
    log "SKIP   $desc: $dev is mounted on the host (remove it from the machine config and reboot the node, then run again)"
    skipped=1
    return
  fi
  name="$(basename "$dev")"
  num="$(cat "$SYSFS/class/block/$name/partition")"
  disk="$(basename "$(dirname "$(readlink -f "$SYSFS/class/block/$name")")")"
  log "WIPE   $desc: $dev (partition $num of $DEVDIR/$disk, $size bytes)"
  if ! run wipefs -a "$dev"; then log "FAILED $desc: wipefs"; fail=1; return; fi
  if ! run dd if=/dev/zero of="$dev" bs=1M count=32 conv=fsync 2>/dev/null; then log "FAILED $desc: dd"; fail=1; return; fi
  if ! run sfdisk --no-reread --delete "$DEVDIR/$disk" "$num"; then log "FAILED $desc: sfdisk"; fail=1; return; fi
  run partx -d --nr "$num" "$DEVDIR/$disk" 2>/dev/null
  log "DONE   $desc"
}

wipe_disk() {
  model="$1"; want="$2"; desc="$3"
  found=""
  for b in "$SYSFS"/block/*; do
    n="$(basename "$b")"
    m="$(sed 's/ *$//' "$b/device/model" 2>/dev/null)"
    [ "$m" = "$model" ] || continue
    found="$n"
    [ "$(blockdev --getsize64 "$DEVDIR/$n")" = "$want" ] || { log "REFUSE $desc: $n has the model '$model' but not $want bytes"; fail=1; continue; }
    case "$(readlink -f "$b")" in
      */usb*) ;;
      *) log "REFUSE $desc: $n is not a USB disk"; fail=1; continue ;;
    esac
    anymounted=0
    for p in "$b/$n"*; do
      [ -e "$p" ] || continue
      if mounted "$DEVDIR/$(basename "$p")"; then anymounted=1; fi
    done
    if [ "$anymounted" = 1 ] || mounted "$DEVDIR/$n"; then
      log "SKIP   $desc: a partition of $n is mounted on the host"
      skipped=1
      continue
    fi
    log "WIPE   $desc: whole disk $DEVDIR/$n ($want bytes, USB)"
    for p in "$b/$n"*; do
      [ -e "$p" ] || continue
      run wipefs -a "$DEVDIR/$(basename "$p")"
    done
    run wipefs -a "$DEVDIR/$n"
    mib=$((want / 1048576))
    if [ "$mib" -lt 1024 ]; then log "REFUSE $desc: $n is smaller than 1 GiB"; fail=1; continue; fi
    run dd if=/dev/zero of="$DEVDIR/$n" bs=1M count=32 conv=fsync 2>/dev/null
    run dd if=/dev/zero of="$DEVDIR/$n" bs=1M seek=$((mib - 32)) count=32 conv=fsync 2>/dev/null
    run blockdev --rereadpt "$DEVDIR/$n"
    log "DONE   $desc"
  done
  [ -n "$found" ] || log "GONE   $desc: no disk with the model '$model' and $want bytes"
}

log "node $(cat /proc/sys/kernel/hostname), dry run: $DRY_RUN"
while IFS='|' read -r kind id size desc; do
  [ -n "$kind" ] || continue
  case "$kind" in
    part) wipe_partition "$id" "$size" "$desc" ;;
    disk) wipe_disk "$id" "$size" "$desc" ;;
    *) log "REFUSE unknown target kind '$kind'"; fail=1 ;;
  esac
done <<TARGETS_END
$TARGETS
TARGETS_END

if [ "$fail" = 1 ]; then
  log "finished with REFUSED or FAILED targets"
  exit 1
fi
log "finished (skipped targets: $skipped)"
exit 0
