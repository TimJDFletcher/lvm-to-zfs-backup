#!/bin/sh
PATH=$PATH:/sbin:/usr/sbin:/usr/local/bin
uuid=65c49ed1-3f73-406a-9a7a-12bcf37a1d31
date=$(date +%s)
snapshot_mountpoint=/run/backups
pool=backups
backupdir=$pool/oxygen
vg=oxygen
rsyncargs="-axH --numeric-ids --no-whole-file --inplace --delete"
rsync_cmd=/usr/src/git/rsync/rsync
extramountpoints="/boot /media/tim/Toshiba.Ubuntu /media/tim/U3.FAT"
retention_cron=60
retention_manual=5

if [ $(id -u) -gt 0 ] ; then
	echo $0 needs to be run as root
	exit 1
fi

if ! /usr/local/bin/zfscontrol.sh start ; then
	echo Failed to start ZFS pool, bailing out
	logger Failed to start ZFS pool, backup aborted
	exit 1
fi

logger ZFS backup started

# Free as much ram as we can
# echo 3 > /proc/sys/vm/drop_caches

# Find and backup all volumes in the volume group
echo "Backing up volume group $vg"
for volume in $(lvm lvs --noheadings -o lv_name $vg) ; do
	mountpoint=$(grep "${vg}-${volume} " /proc/mounts  | awk '{print $2}')
	size=$(lvm lvs --noheadings --nosuffix --units m /dev/$vg/$volume -o lv_size)
	if [ x$mountpoint != x ] ; then
		echo "$volume" ; sync
		lvm lvcreate --quiet -L $(echo $size/10| bc)M --chunksize 512k -s -n ${volume}.${date} /dev/${vg}/${volume} 
		# fsck -p /dev/${vg}/${volume}.${date}
		blockdev --setro /dev/${vg}/${volume}.${date}
		mkdir -p $snapshot_mountpoint/$date/$volume

		# Acutally do the backups
		if mount -o ro /dev/${vg}/${volume}.${date} $snapshot_mountpoint/$date/$volume ; then
			$rsync_cmd $rsyncargs $snapshot_mountpoint/$date/$volume/ /$backupdir/$volume/
			sync ; sleep 10
			umount $snapshot_mountpoint/$date/$volume
		else
			echo "$volume failed to mount skipping backup"
		fi

		sync ; sleep 30
		if ! lvm lvremove --quiet --force ${vg}/${volume}.${date} ; then
			echo lvremove failed, sleeping 30 seconds and using dmsetup
			sync ; sleep 30
			dmsetup remove ${vg}-${volume}-real
			dmsetup remove ${vg}-${volume}.${date}
			lvm lvremove --quiet --force ${vg}/${volume}.${date}
		fi
		rmdir $snapshot_mountpoint/$date/$volume
	else
		echo "$volume not mounted skipping backup"
	fi
done
echo done

echo -n "Backing up other filesystems: "
# Backup any extra mountpoints, eg /boot
for mountpoint in $extramountpoints ; do
	echo -n "$(basename $mountpoint), "
	if grep -q $mountpoint /proc/mounts ; then
		safename=$(echo $mountpoint | sed -e s,^/,,g -e s,/,.,g )
		$rsync_cmd $rsyncargs $mountpoint/ /$backupdir/$safename/
	fi
done
echo done

rmdir $snapshot_mountpoint/$date

case x$1 in
xcron)
	zfs-auto-snapshot.sh --syslog -p snap --label=cron   --keep=$retention_cron $backupdir
;;
x)
	zfs-auto-snapshot.sh --syslog -p snap --label=manual --keep=$retention_manual $backupdir
;;
*)
	zfs-auto-snapshot.sh --syslog -p snap --label=$1     --keep=$retention_manual $backupdir
;;
esac

zpool list $pool

logger ZFS backup completed

zfscontrol.sh stop
