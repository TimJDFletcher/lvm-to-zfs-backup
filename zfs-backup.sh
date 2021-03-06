#!/bin/bash
set -eu -o pipefail

. /etc/zfsbackups/zfs-backup.conf

if [ $UID -gt 0 ]; then
  echo "$0" needs to be run as root
  exit 1
fi

vglock() {
  if [ -f "$lockfile" ]; then
    echo "$lockfile" found, bailing out
    logger ZFS backup aborted, lock file found
    return 1
  else
    logger ZFS backup started
    touch "$lockfile"
  fi
}

vgunlock() {
  rm -f "$lockfile"
}

vgbackup() {
  backupTarget=$TARGET/lvm/$vg
  echo "Backing up volume group $vg"
  for volume in $(lvm lvs --noheadings -o lv_name "$vg"); do
    if grep -q "^/dev/mapper/${vg}-${volume} " /proc/mounts; then
      echo "$volume"
      # Take an LVM snapshot 10% of the size of the origin volume
      lvm lvcreate --quiet --extents 10%ORIGIN --chunksize 512k --snapshot --name ${volume}.${DATE} /dev/${vg}/${volume}
      blockdev --setro "/dev/${vg}/${volume}.${DATE}"
      mkdir -p "$SNAP_MOUNTPOINT/$DATE/$volume"
      if [ -f "$CONF_DIR/${vg}-${volume}.excludes" ]; then
        rsyncargs="${RSYNC_ARGS_BASE} --delete-excluded --exclude-from=${CONF_DIR}/${vg}-${volume}.excludes"
      else
        rsyncargs="${RSYNC_ARGS_BASE}"
      fi
      # Actually backup files
      if mount -o ro "/dev/${vg}/${volume}.${DATE}" "${SNAP_MOUNTPOINT}/$DATE/$volume"; then
        $RSYNC_CMD $rsyncargs "${SNAP_MOUNTPOINT}/${DATE}/$volume/" "$backupTarget/$volume/"
        umount "${SNAP_MOUNTPOINT}/${DATE}/$volume"
      else
        echo "$volume snapshot failed to mount skipping backup"
      fi
      sync ; sleep 10
      if ! lvm lvremove --quiet --force "${vg}/${volume}.${DATE}"; then
        echo lvremove failed, sleeping 30 seconds and using dmsetup
        sync
        sleep 30
        dmsetup remove "${vg}-${volume}-real"
        dmsetup remove "${vg}-${volume}.${DATE}"
        lvm lvremove --quiet --force "${vg}/${volume}.${DATE}"
      fi
      rmdir "${SNAP_MOUNTPOINT}/${DATE}/$volume"
    else
      echo "$volume not mounted skipping backup"
    fi
  done
  rmdir "${SNAP_MOUNTPOINT}/${DATE}"
  echo done
}

mountpointbackup() {
  backupTarget=$TARGET/extra
  echo -n "$(basename "$mountpoint"), "
  if [ "x/" = "x$mountpoint" ]; then
    safename=root
  else
    safename="$(echo "$mountpoint" | sed -e s,^/,,g -e s,/,.,g)"
  fi
  if [ -f "$CONF_DIR/${safename}.excludes" ]; then
    rsyncargs="${RSYNC_ARGS_BASE} --delete-excluded --exclude-from=${CONF_DIR}/${safename}.excludes"
  else
    rsyncargs="${RSYNC_ARGS_BASE}"
  fi
  if grep -q " $mountpoint " /proc/mounts; then
    $RSYNC_CMD $rsyncargs "$mountpoint/" "$backupTarget/$safename/"
  fi
}

echo "Backing up volume groups"
for vg in ${VGs}; do
  lockfile="${LOCKDIR}/${vg}.zfsbackup"
  vglock
  vgbackup
  vgunlock
done

echo -n "Backing up other filesystems: "
for mountpoint in $EXTRAMOUNTPOINTS; do
  mountpointbackup
done
echo done

logger ZFS backup completed
