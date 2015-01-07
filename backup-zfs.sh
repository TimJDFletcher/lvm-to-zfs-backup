#!/bin/sh
. /etc/backup/zfs-backup.conf

if [ $(id -u) -gt 0 ] ; then
	echo $0 needs to be run as root
	exit 1
fi

if ! zfscontrol.sh start ; then
	echo Failed to start ZFS pool, bailing out
	logger Failed to start ZFS pool, backup aborted
	exit 1
fi

if [ -f $lockfile ] ; then
	echo $lockfile found, bailing out
	logger ZFS backup aborted, lock file found
	exit 1
else
	logger ZFS backup started
	touch $lockfile
fi

# Find and backup all volumes in the volume group
echo "Backing up volume group $vg"
for volume in $(lvm lvs --noheadings -o lv_name $vg) ; do
	mountpoint=$(grep "^/dev/mapper/${vg}-${volume} " /proc/mounts  | awk '{print $2}')
	if [ x$mountpoint != x ] ; then
		echo "$volume" ; sync
		lvm lvcreate --quiet --extents 10%ORIGIN --chunksize 512k --snapshot --name ${volume}.${date} /dev/${vg}/${volume}
		blockdev --setro /dev/${vg}/${volume}.${date}
		mkdir -p $snapshot_mountpoint/$date/$volume
		# Acutally backup
		if mount -o ro /dev/${vg}/${volume}.${date} $snapshot_mountpoint/$date/$volume ; then
			mkdir -p /$backupdir/$volume/
			$rsync_cmd $rsyncargs $snapshot_mountpoint/$date/$volume/ /$backupdir/$volume/
			sync ; sleep 10
			umount $snapshot_mountpoint/$date/$volume
		else
			echo "$volume snapshot failed to mount skipping backup"
		fi

		sync ; sleep 5
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
	if grep -q " $mountpoint " /proc/mounts ; then
		if [ "x/" = "x$mountpoint" ] ; then
			safename=root
		else
			safename=$(echo $mountpoint | sed -e s,^/,,g -e s,/,.,g )
		fi
		$rsync_cmd $rsyncargs $mountpoint/ /$backupdir/$safename/
	fi
done
echo done
rmdir $snapshot_mountpoint/$date

if [ x$libvirtbackup = xtrue ] ; then
	echo "Backing up libvirt disk images"
	runningDomains=$(virsh list --all --state-running | egrep '^ [0-9]|^ -' | awk '{print $2}')
	for domain in $runningDomains ; do
			echo Hot backing up $domain
			virsh domblklist --details $domain |  egrep '^file[[:space:]]*disk' | awk '{print $3,$4}' | while read disk file ; do
				virsh snapshot-create-as --domain $domain backup.$date --diskspec $disk,file=$file.$date --disk-only --atomic
				if [ -f $file ] ; then
					mkdir -p /$backupdir/libvirt/$domain
					$rsync_cmd $rsyncargs $file /$backupdir/$(echo $file | sed -e 's,\./var/lib/libvirt,,g')
				if virsh blockcommit $domain $disk --active --pivot --verbose ; then
					rm $file.$date
					virsh snapshot-delete $domain backup.$date --metadata
				else
					echo Snapshot removal of backup.$date from $domain failed
				fi
			else
				File $file not found, skipping
			fi
		done
	done
fi

case x$1 in
xcron)
	zfs-auto-snapshot.sh --syslog -p snap --label=cron   --keep=$retention_cron $backupfs
;;
x)
	zfs-auto-snapshot.sh --syslog -p snap --label=manual --keep=$retention_manual $backupfs
;;
*)
	zfs-auto-snapshot.sh --syslog -p snap --label=$1     --keep=$retention_manual $backupfs
;;
esac

zpool list $pool

logger ZFS backup completed
rm $lockfile
zfscontrol.sh stop
